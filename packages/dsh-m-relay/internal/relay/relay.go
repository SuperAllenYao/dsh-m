// Package relay implements the DSH-m transparent relay (M2a): a stdlib-only Go
// server that terminates TLS only for the control connection, routes one bridge
// TCP port per Mac, and proxies opaque bytes. TLS for phone traffic terminates
// on the Mac (the relay never sees plaintext).
//
// Wire contract: <internal-doc> §4.
package relay

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"dshm-relay/internal/audit"
	"dshm-relay/internal/authn"
	"dshm-relay/internal/certs"
	"dshm-relay/internal/config"
	"dshm-relay/internal/state"
)

// Version is the relay protocol/implementation version reported by /healthz.
const Version = "0.1.0"

// ALPN protocol ids. The tunnel uses dshm-relay/1 (framed control protocol);
// App lookups and health checks use HTTP/1.1 (or no ALPN at all).
const (
	ALPNRelay = "dshm-relay/1"
	ALPNHTTP  = "http/1.1"
)

// Protocol error codes (design doc §4.4).
const (
	codePortUnavailable = "port/unavailable"
	codeServerBusy      = "server/busy"
	codeAuthInvalid     = authn.CodeAuthInvalid
	codeAuthReplay      = authn.CodeAuthReplay
	codeVersionUnsup    = authn.CodeVersionUnsupport
)

// protoError is a control-protocol error carrying a design-doc error code.
type protoError struct {
	Code    string
	Message string
}

func (e *protoError) Error() string { return e.Code + ": " + e.Message }

// Options tunes a Server. Zero values are production defaults.
type Options struct {
	// Logger receives operational logs. It must never be handed secrets.
	Logger *slog.Logger
	// Now overrides the clock (tests only).
	Now func() time.Time
}

// Server is one relay instance.
type Server struct {
	cfg  config.Config
	log  *slog.Logger
	now  func() time.Time
	pair tls.Certificate
	leaf *x509.Certificate
	// secret is the HMAC key shared with the Mac plugin. It is never logged and
	// never written to audit records.
	secret   []byte
	tlsConf  *tls.Config
	portPool *portPool

	state  *state.Store
	audit  *audit.Logger
	nonces *authn.NonceCache
	codes  *codeRegistry

	lookupLimiter *keyedLimiter
	bridgeLimiter *keyedLimiter

	listener net.Listener
	httpLn   *chanListener
	httpSrv  *http.Server

	helloMu sync.Mutex // serializes tunnel (re)registration on one hostId
	hostsMu sync.Mutex
	hosts   map[string]*tunnelSession

	wg        sync.WaitGroup
	done      chan struct{}
	drainOnce sync.Once
	draining  atomic.Bool
	closing   atomic.Bool

	startedAt time.Time

	// Test hooks; zero means "use the configured value".
	heartbeatOverride   time.Duration
	openTimeoutOverride time.Duration
	drainGrace          time.Duration
}

// New validates cfg and loads the TLS material, HMAC secret, state and audit log.
func New(cfg config.Config, opts Options) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("relay: invalid config: %w", err)
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	}
	nowFn := opts.Now
	if nowFn == nil {
		nowFn = time.Now
	}
	if cfg.AuditFile == "" {
		cfg.AuditFile = filepath.Join(filepath.Dir(cfg.StateFile), "audit.jsonl")
	}
	secretRaw, err := os.ReadFile(cfg.SecretFile)
	if err != nil {
		return nil, fmt.Errorf("relay: read secret %s: %w", cfg.SecretFile, err)
	}
	secret := strings.TrimSpace(string(secretRaw))
	if len(secret) < 16 {
		return nil, fmt.Errorf("relay: secret %s is too short (min 16 chars)", cfg.SecretFile)
	}
	pair, leaf, err := certs.Load(cfg.CertFile, cfg.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("relay: load TLS material: %w", err)
	}
	if !certs.CoversHost(leaf, cfg.PublicHost) && !certs.CoversHost(leaf, strings.TrimSpace(cfg.PublicHost)) {
		return nil, fmt.Errorf("relay: certificate SAN %v does not cover publicHost %q", certs.Sites(leaf), cfg.PublicHost)
	}
	if time.Now().After(leaf.NotAfter) {
		return nil, fmt.Errorf("relay: certificate expired at %s", leaf.NotAfter.Format(time.RFC3339))
	}
	st, err := state.Open(cfg.StateFile)
	if err != nil {
		return nil, fmt.Errorf("relay: open state: %w", err)
	}
	aud, err := audit.Open(cfg.AuditFile)
	if err != nil {
		return nil, fmt.Errorf("relay: open audit log %s: %w", cfg.AuditFile, err)
	}
	s := &Server{
		cfg:           cfg,
		log:           logger.With("component", "relay"),
		now:           nowFn,
		pair:          pair,
		leaf:          leaf,
		secret:        []byte(secret),
		portPool:      newPortPool(cfg.BridgePorts, cfg.BridgeBind, st.Snapshot()),
		state:         st,
		audit:         aud,
		nonces:        authn.NewNonceCache(authn.NonceTTL, authn.DefaultNonceMaxEntries),
		codes:         newCodeRegistry(),
		lookupLimiter: newKeyedLimiter(cfg.LookupRateLimitPerMin, time.Minute, nowFn),
		bridgeLimiter: newKeyedLimiter(cfg.BridgeAcceptRatePerSec, time.Second, nowFn),
		hosts:         make(map[string]*tunnelSession),
		httpLn:        newChanListener(),
	}
	s.tlsConf = &tls.Config{
		Certificates: []tls.Certificate{pair},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{ALPNRelay, ALPNHTTP},
	}
	return s, nil
}

// Config returns the effective configuration (tests / doctor output).
func (s *Server) Config() config.Config { return s.cfg }

// LeafPin returns the relay certificate pin (base64url SHA-256 of the DER).
func (s *Server) LeafPin() string { return certs.Pin(s.leaf.Raw) }

// LeafFingerprint256 returns the colon-hex certificate fingerprint.
func (s *Server) LeafFingerprint256() string { return certs.Fingerprint256(s.leaf.Raw) }

// Addr returns the bound control listener address (nil before Start).
func (s *Server) Addr() net.Addr {
	if s.listener == nil {
		return nil
	}
	return s.listener.Addr()
}

// ControlOrigin returns the public control origin, e.g. https://203.0.113.10:443.
func (s *Server) ControlOrigin() string {
	return "https://" + net.JoinHostPort(s.cfg.PublicHost, strconv.Itoa(s.controlPort()))
}

func (s *Server) controlPort() int {
	_, portStr, err := net.SplitHostPort(s.cfg.Listen)
	if err == nil {
		if p, convErr := strconv.Atoi(portStr); convErr == nil && p != 0 {
			return p
		}
	}
	if s.listener != nil {
		if addr, ok := s.listener.Addr().(*net.TCPAddr); ok {
			return addr.Port
		}
	}
	return 0
}

// originFor returns the Mac's public TLS origin (https://<publicHost>:<bridgePort>).
func (s *Server) originFor(port int) string {
	return "https://" + net.JoinHostPort(s.cfg.PublicHost, strconv.Itoa(port))
}

// Start binds the control listener and starts the accept/HTTP/sweeper loops.
func (s *Server) Start() error {
	if s.listener != nil {
		return fmt.Errorf("relay: already started")
	}
	ln, err := net.Listen("tcp", s.cfg.Listen)
	if err != nil {
		return fmt.Errorf("relay: listen %s: %w", s.cfg.Listen, err)
	}
	s.listener = ln
	s.startedAt = s.now()
	s.done = make(chan struct{})
	s.httpSrv = &http.Server{
		Handler:           s.httpHandler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	s.wg.Add(3)
	go func() {
		defer s.wg.Done()
		if err := s.httpSrv.Serve(s.httpLn); err != nil &&
			!errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
			s.log.Warn("http lookup server stopped", "err", err)
		}
	}()
	go func() {
		defer s.wg.Done()
		s.acceptLoop()
	}()
	go func() {
		defer s.wg.Done()
		s.sweepLoop()
	}()
	s.log.Info("relay started",
		"control", ln.Addr().String(),
		"publicHost", s.cfg.PublicHost,
		"bridgePorts", s.cfg.BridgePorts.String(),
		"bridgeBind", s.cfg.BridgeBind,
	)
	return nil
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			if s.closing.Load() || errors.Is(err, net.ErrClosed) {
				return
			}
			s.log.Warn("control accept failed", "err", err)
			time.Sleep(20 * time.Millisecond)
			continue
		}
		s.wg.Add(1)
		go func(c net.Conn) {
			defer s.wg.Done()
			s.handleControlConn(c)
		}(conn)
	}
}

func (s *Server) sweepLoop() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.done:
			return
		case now := <-ticker.C:
			s.codes.sweep(s.now(), time.Minute)
			s.lookupLimiter.prune(now)
			s.bridgeLimiter.prune(now)
		}
	}
}

// handleControlConn peeks the TLS handshake ALPN result and dispatches:
// - dshm-relay/1 -> framed tunnel control protocol
// - http/1.1, or no ALPN -> /v1/lookup + /healthz over HTTPS
func (s *Server) handleControlConn(raw net.Conn) {
	ip := remoteIP(raw.RemoteAddr().String())
	tlsConn := tls.Server(raw, s.tlsConf)
	_ = tlsConn.SetDeadline(s.now().Add(10 * time.Second))
	if err := tlsConn.Handshake(); err != nil {
		s.log.Debug("tls handshake failed", "ip", ip, "err", err)
		_ = tlsConn.Close()
		return
	}
	_ = tlsConn.SetDeadline(time.Time{})
	switch proto := tlsConn.ConnectionState().NegotiatedProtocol; proto {
	case ALPNRelay:
		s.handleTunnel(tlsConn, ip)
	case ALPNHTTP, "":
		if !s.httpLn.push(tlsConn) {
			_ = tlsConn.Close()
		}
	default:
		s.log.Debug("unsupported alpn", "ip", ip, "alpn", proto)
		_ = tlsConn.Close()
	}
}

// Shutdown drains gracefully: notify tunnels with a `drain` frame, close bridge
// listeners, keep state.json, then close control connections and the HTTP server.
func (s *Server) Shutdown(ctx context.Context) error {
	var httpErr error
	s.drainOnce.Do(func() {
		s.closing.Store(true)
		s.draining.Store(true)
		if s.done != nil {
			close(s.done)
		}
		if s.listener != nil {
			_ = s.listener.Close()
		}
		s.hostsMu.Lock()
		sessions := make([]*tunnelSession, 0, len(s.hosts))
		for _, ses := range s.hosts {
			sessions = append(sessions, ses)
		}
		s.hostsMu.Unlock()
		if len(sessions) > 0 {
			s.log.Info("drain: notifying tunnels", "tunnels", len(sessions))
			for _, ses := range sessions {
				ses.sendDrain("shutdown")
			}
			for _, ses := range sessions {
				ses.closeBridge()
			}
			grace := s.drainGrace
			if grace <= 0 {
				grace = 750 * time.Millisecond
			}
			select {
			case <-time.After(grace):
			case <-ctx.Done():
			}
			for _, ses := range sessions {
				ses.shutdown("shutdown")
			}
		}
		s.httpLn.Close()
		if s.httpSrv != nil {
			httpErr = s.httpSrv.Shutdown(ctx)
		}
		s.wg.Wait()
		if err := s.audit.Close(); err != nil {
			s.log.Warn("close audit log", "err", err)
		}
		s.log.Info("relay stopped (state retained)", "stateFile", s.cfg.StateFile)
	})
	return httpErr
}

// hostCount returns the number of connected tunnels.
func (s *Server) hostCount() int {
	s.hostsMu.Lock()
	defer s.hostsMu.Unlock()
	return len(s.hosts)
}

// BridgePort returns the current bridge port of a connected host (tests / diagnostics).
func (s *Server) BridgePort(hostID string) (int, bool) {
	s.hostsMu.Lock()
	defer s.hostsMu.Unlock()
	ses, ok := s.hosts[hostID]
	if !ok {
		return 0, false
	}
	return ses.port, true
}

// CodeCount returns the number of live rendezvous codes (tests / diagnostics).
func (s *Server) CodeCount() int { return s.codes.len() }

// ReservedPorts returns the current hostId -> bridge port reservations.
func (s *Server) ReservedPorts() map[int]string { return s.portPool.reservedPorts() }

// AuditPath returns the audit log file path.
func (s *Server) AuditPath() string { return s.audit.Path() }

// Log returns the server logger (tests).
func (s *Server) Log() *slog.Logger { return s.log }

// --- small helpers -----------------------------------------------------------

func (s *Server) heartbeatInterval() time.Duration {
	if s.heartbeatOverride > 0 {
		return s.heartbeatOverride
	}
	return time.Duration(s.cfg.HeartbeatSec) * time.Second
}

func (s *Server) openTimeout() time.Duration {
	if s.openTimeoutOverride > 0 {
		return s.openTimeoutOverride
	}
	return time.Duration(s.cfg.OpenTimeoutSec) * time.Second
}

func remoteIP(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return host
}

// truncate cuts s to at most max bytes without splitting a UTF-8 rune.
func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	for max > 0 && s[max]&0xC0 == 0x80 {
		max--
	}
	return s[:max]
}

func marshalJSON(v any) ([]byte, error) { return json.Marshal(v) }

// chanListener adapts accepted TLS connections into an http.Server listener so
// ALPN-negotiated HTTP/1.1 connections share one http.Server (keep-alive works).
type chanListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func newChanListener() *chanListener {
	return &chanListener{conns: make(chan net.Conn, 64), done: make(chan struct{})}
}

func (l *chanListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *chanListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *chanListener) Addr() net.Addr { return nil }

// push hands an already-handshaken TLS connection to the HTTP server. It
// reports false when the server is shutting down (caller closes the conn).
func (l *chanListener) push(c net.Conn) bool {
	select {
	case <-l.done:
		return false
	default:
	}
	select {
	case l.conns <- c:
		return true
	case <-l.done:
		return false
	}
}
