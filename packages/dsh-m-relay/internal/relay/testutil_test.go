package relay

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"dshm-relay/internal/authn"
	"dshm-relay/internal/certs"
	"dshm-relay/internal/config"
	"dshm-relay/internal/wire"
)

// testEnv is one started relay plus its temp config/material.
type testEnv struct {
	t      *testing.T
	srv    *Server
	cfg    config.Config
	dir    string
	secret []byte // base64url secret string as bytes (what the tunnel HMACs with)
	pin    string
}

func newTestEnv(t *testing.T, mutate func(*config.Config)) *testEnv {
	t.Helper()
	return newTestEnvInDir(t, t.TempDir(), mutate)
}

func newTestEnvInDir(t *testing.T, dir string, mutate func(*config.Config)) *testEnv {
	t.Helper()
	poolStart := freePortRange(t, 8)
	cfg := config.Default()
	cfg.Listen = "127.0.0.1:0"
	cfg.PublicHost = "127.0.0.1"
	cfg.BridgePorts = config.PortRange{Start: poolStart, End: poolStart + 7}
	cfg.BridgeBind = "127.0.0.1"
	cfg.StateFile = filepath.Join(dir, "state.json")
	cfg.SecretFile = filepath.Join(dir, "relay.secret")
	cfg.CertFile = filepath.Join(dir, "tls", "cert.pem")
	cfg.KeyFile = filepath.Join(dir, "tls", "key.pem")
	cfg.AuditFile = filepath.Join(dir, "audit.jsonl")
	cfg.MaxStreamsPerHost = 4
	cfg.LookupRateLimitPerMin = 10
	cfg.BridgeAcceptRatePerSec = 100
	cfg.HeartbeatSec = 15
	cfg.OpenTimeoutSec = 5
	if mutate != nil {
		mutate(&cfg)
	}
	mat, err := certs.Generate(cfg.PublicHost, 48*time.Hour)
	if err != nil {
		t.Fatalf("generate test certificate: %v", err)
	}
	secretStr := base64.RawURLEncoding.EncodeToString(randomBytes(t, 32))
	if err := os.MkdirAll(filepath.Join(dir, "tls"), 0o700); err != nil {
		t.Fatalf("mkdir tls: %v", err)
	}
	for _, w := range []struct {
		path string
		data []byte
		mode os.FileMode
	}{
		{cfg.SecretFile, []byte(secretStr + "\n"), 0o600},
		{cfg.CertFile, mat.CertPEM, 0o644},
		{cfg.KeyFile, mat.KeyPEM, 0o600},
	} {
		if err := os.WriteFile(w.path, w.data, w.mode); err != nil {
			t.Fatalf("write %s: %v", w.path, err)
		}
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if os.Getenv("DSHM_RELAY_TEST_DEBUG") != "" {
		logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	srv, err := New(cfg, Options{Logger: logger})
	if err != nil {
		t.Fatalf("relay.New: %v", err)
	}
	srv.drainGrace = 50 * time.Millisecond // keep test cleanup fast
	if err := srv.Start(); err != nil {
		t.Fatalf("relay.Start: %v", err)
	}
	env := &testEnv{t: t, srv: srv, cfg: cfg, dir: dir, secret: []byte(secretStr), pin: mat.Pin}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	})
	return env
}

func (e *testEnv) controlAddr() string { return e.srv.Addr().String() }

func randomBytes(t *testing.T, n int) []byte {
	t.Helper()
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("crypto/rand: %v", err)
	}
	return buf
}

func testNonce(t *testing.T) string {
	return base64.RawURLEncoding.EncodeToString(randomBytes(t, 16))
}

// freePortRange finds n consecutive free TCP ports on 127.0.0.1.
func freePortRange(t *testing.T, n int) int {
	t.Helper()
	for attempt := 0; attempt < 200; attempt++ {
		start := 20000 + mrand.IntN(30000)
		if start+n > 65000 {
			continue
		}
		var listeners []net.Listener
		ok := true
		for i := 0; i < n; i++ {
			ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(start+i)))
			if err != nil {
				ok = false
				break
			}
			listeners = append(listeners, ln)
		}
		for _, ln := range listeners {
			_ = ln.Close()
		}
		if ok {
			return start
		}
	}
	t.Fatalf("could not find %d consecutive free ports", n)
	return 0
}

// --- control-connection helpers ---------------------------------------------

type fakeTunnel struct {
	t       *testing.T
	env     *testEnv
	conn    *tls.Conn
	br      *bufio.Reader
	hostID  string
	writeMu sync.Mutex
}

func (e *testEnv) dialRawTLS(t *testing.T, nextProtos []string) *tls.Conn {
	t.Helper()
	raw, err := net.DialTimeout("tcp", e.controlAddr(), 3*time.Second)
	if err != nil {
		t.Fatalf("dial relay: %v", err)
	}
	conn := tls.Client(raw, &tls.Config{
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: certs.VerifyPin(e.pin),
		NextProtos:            nextProtos,
		MinVersion:            tls.VersionTLS12,
	})
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if err := conn.Handshake(); err != nil {
		_ = conn.Close()
		t.Fatalf("TLS handshake: %v", err)
	}
	_ = conn.SetDeadline(time.Time{})
	return conn
}

func (e *testEnv) dialTunnel(t *testing.T, hostID string) *fakeTunnel {
	t.Helper()
	conn := e.dialRawTLS(t, []string{ALPNRelay})
	ft := &fakeTunnel{t: t, env: e, conn: conn, br: bufio.NewReaderSize(conn, 64<<10), hostID: hostID}
	t.Cleanup(func() { _ = conn.Close() })
	return ft
}

func (ft *fakeTunnel) sendFrame(typ byte, payload []byte) error {
	ft.writeMu.Lock()
	defer ft.writeMu.Unlock()
	_ = ft.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	return wire.WriteFrame(ft.conn, typ, payload)
}

func (ft *fakeTunnel) sendJSON(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return ft.sendFrame(wire.TypeJSON, data)
}

func (ft *fakeTunnel) readFrame(timeout time.Duration) (byte, []byte, error) {
	_ = ft.conn.SetReadDeadline(time.Now().Add(timeout))
	defer ft.conn.SetReadDeadline(time.Time{})
	return wire.ReadFrame(ft.br)
}

func (ft *fakeTunnel) readJSON(timeout time.Duration) (map[string]any, error) {
	typ, payload, err := ft.readFrame(timeout)
	if err != nil {
		return nil, err
	}
	if typ != wire.TypeJSON {
		return nil, fmt.Errorf("frame type = 0x%02x, want JSON", typ)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, err
	}
	return decoded, nil
}

func helloMessage(secret []byte, hostID string, ts int64, nonce string, wantPort *int) map[string]any {
	msg := map[string]any{
		"t":        "hello",
		"v":        1,
		"hostId":   hostID,
		"hostName": "Test Mac",
		"ts":       ts,
		"nonce":    nonce,
		"auth":     authn.ComputeAuth(secret, hostID, ts, nonce, wantPort),
		"meta":     map[string]any{"plugin": "dshm-relay-test", "proto": "dshm/1"},
	}
	if wantPort != nil {
		msg["wantPort"] = *wantPort
	}
	return msg
}

// hello performs a standard hello and returns the decoded response.
func (ft *fakeTunnel) hello(wantPort *int, mutate func(map[string]any)) (map[string]any, error) {
	ts := time.Now().UnixMilli()
	msg := helloMessage(ft.env.secret, ft.hostID, ts, testNonce(ft.t), wantPort)
	if mutate != nil {
		mutate(msg)
	}
	if err := ft.sendJSON(msg); err != nil {
		return nil, err
	}
	return ft.readJSON(3 * time.Second)
}

// tunnelReady dials + hello and asserts `ready`, returning the ready message.
func (e *testEnv) tunnelReady(t *testing.T, hostID string, wantPort *int) (*fakeTunnel, readyMessage) {
	t.Helper()
	ft := e.dialTunnel(t, hostID)
	resp, err := ft.hello(wantPort, nil)
	if err != nil {
		t.Fatalf("hello: %v", err)
	}
	if resp["t"] != "ready" {
		t.Fatalf("hello response = %v, want ready", resp)
	}
	return ft, readyFromMap(t, resp)
}

func readyFromMap(t *testing.T, m map[string]any) readyMessage {
	t.Helper()
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal ready: %v", err)
	}
	var ready readyMessage
	if err := json.Unmarshal(data, &ready); err != nil {
		t.Fatalf("unmarshal ready: %v", err)
	}
	return ready
}

// expectHelloError sends msg and returns the design-doc error code the relay
// answered with, after checking that it sent `{"t":"error"}` and then closed.
func (e *testEnv) expectHelloError(t *testing.T, hostID string, msg map[string]any) string {
	t.Helper()
	ft := e.dialTunnel(t, hostID)
	if err := ft.sendJSON(msg); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	resp, err := ft.readJSON(3 * time.Second)
	if err != nil {
		t.Fatalf("read hello error response: %v", err)
	}
	if resp["t"] != "error" {
		t.Fatalf("response = %v, want t=error", resp)
	}
	code, _ := resp["code"].(string)
	if code == "" {
		t.Fatalf("error response has no code: %v", resp)
	}
	return code
}

// --- bridge target: a fake tunnel that dials a local echo server -------------

type tunnelBehavior struct {
	targetAddr string
	failOpen   bool
	ignoreOpen bool
	rstOnOpen  bool
}

type fakeTunnelRunner struct {
	ft       *fakeTunnel
	behavior tunnelBehavior

	mu     sync.Mutex
	sids   []uint32
	opened int
	rsts   []byte
	conns  map[uint32]net.Conn
	done   chan struct{}
}

func runFakeTunnel(t *testing.T, ft *fakeTunnel, behavior tunnelBehavior) *fakeTunnelRunner {
	t.Helper()
	r := &fakeTunnelRunner{ft: ft, behavior: behavior, conns: make(map[uint32]net.Conn), done: make(chan struct{})}
	go r.loop()
	t.Cleanup(func() {
		_ = ft.conn.Close()
		r.closeAll()
		select {
		case <-r.done:
		case <-time.After(2 * time.Second):
		}
	})
	return r
}

func (r *fakeTunnelRunner) loop() {
	defer close(r.done)
	for {
		typ, payload, err := wire.ReadFrame(r.ft.br)
		if err != nil {
			return
		}
		switch typ {
		case wire.TypeJSON:
			var head struct {
				T   string `json:"t"`
				Sid uint32 `json:"sid"`
				Ts  int64  `json:"ts"`
			}
			if err := json.Unmarshal(payload, &head); err != nil {
				return
			}
			switch head.T {
			case "ping":
				_ = r.ft.sendJSON(map[string]any{"t": "pong", "ts": head.Ts})
			case "open":
				r.mu.Lock()
				r.sids = append(r.sids, head.Sid)
				r.mu.Unlock()
				r.handleOpen(head.Sid)
			}
		case wire.TypeData:
			sid, data, err := wire.ParseData(payload)
			if err != nil {
				return
			}
			if c := r.conn(sid); c != nil {
				if _, err := c.Write(data); err != nil {
					_ = c.Close()
				}
			}
		case wire.TypeFin:
			sid, err := wire.ParseSID(payload)
			if err != nil {
				return
			}
			if c := r.conn(sid); c != nil {
				if cw, ok := c.(*net.TCPConn); ok {
					_ = cw.CloseWrite()
				}
			}
		case wire.TypeRst:
			sid, code, err := wire.ParseRST(payload)
			if err != nil {
				return
			}
			r.mu.Lock()
			r.rsts = append(r.rsts, code)
			r.mu.Unlock()
			if c := r.take(sid); c != nil {
				_ = c.Close()
			}
		}
	}
}

func (r *fakeTunnelRunner) handleOpen(sid uint32) {
	switch {
	case r.behavior.ignoreOpen:
		return
	case r.behavior.failOpen:
		_ = r.ft.sendJSON(map[string]any{"t": "open_failed", "sid": sid, "code": "local/dial-failed", "message": "boom"})
		return
	case r.behavior.rstOnOpen:
		_ = r.ft.sendFrame(wire.TypeRst, wire.EncodeRST(sid, wire.RstProtocol))
		return
	}
	conn, err := net.DialTimeout("tcp", r.behavior.targetAddr, 2*time.Second)
	if err != nil {
		_ = r.ft.sendJSON(map[string]any{"t": "open_failed", "sid": sid, "code": "local/dial-failed", "message": err.Error()})
		return
	}
	r.mu.Lock()
	r.conns[sid] = conn
	r.opened++
	r.mu.Unlock()
	if err := r.ft.sendJSON(map[string]any{"t": "opened", "sid": sid}); err != nil {
		_ = conn.Close()
		return
	}
	go r.pump(sid, conn)
}

func (r *fakeTunnelRunner) pump(sid uint32, conn net.Conn) {
	buf := make([]byte, 32<<10)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			if sendErr := r.ft.sendFrame(wire.TypeData, wire.EncodeData(sid, buf[:n])); sendErr != nil {
				return
			}
		}
		if err != nil {
			_ = r.ft.sendFrame(wire.TypeFin, wire.SidPayload(sid))
			return
		}
	}
}

func (r *fakeTunnelRunner) conn(sid uint32) net.Conn {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.conns[sid]
}

func (r *fakeTunnelRunner) take(sid uint32) net.Conn {
	r.mu.Lock()
	defer r.mu.Unlock()
	conn := r.conns[sid]
	delete(r.conns, sid)
	return conn
}

func (r *fakeTunnelRunner) closeAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for sid, conn := range r.conns {
		_ = conn.Close()
		delete(r.conns, sid)
	}
}

func (r *fakeTunnelRunner) sidSnapshot() []uint32 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]uint32(nil), r.sids...)
}

func (r *fakeTunnelRunner) openedCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.opened
}

func (r *fakeTunnelRunner) rstSnapshot() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]byte(nil), r.rsts...)
}

func (r *fakeTunnelRunner) waitSids(t *testing.T, n int, timeout time.Duration) []uint32 {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if got := r.sidSnapshot(); len(got) >= n {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d open frames, got %v", n, r.sidSnapshot())
	return nil
}

// httpClient returns an HTTPS client pinned to the relay certificate (like the
// iOS App's server config). ALPN is HTTP/1.1; keep-alives are disabled so each
// request exercises a fresh TLS handshake.
func (e *testEnv) httpClient(t *testing.T) *http.Client {
	t.Helper()
	return &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{
			DisableKeepAlives: true,
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify:    true,
				VerifyPeerCertificate: certs.VerifyPin(e.pin),
				NextProtos:            []string{ALPNHTTP},
				MinVersion:            tls.VersionTLS12,
			},
		},
	}
}

// --- echo server + phone-side helpers ---------------------------------------

func startEchoServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("echo listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_, _ = io.Copy(c, c)
			}(conn)
		}
	}()
	return ln.Addr().String()
}

// phoneEcho connects to a bridge port, writes payload, half-closes and compares
// the echoed bytes. Any error (timeout, reset, mismatch) is returned.
func phoneEcho(bridgeAddr string, payload []byte, timeout time.Duration) error {
	conn, err := net.DialTimeout("tcp", bridgeAddr, timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	var echoed []byte
	var echoedMu sync.Mutex
	readDone := make(chan error, 1)
	go func() {
		buf := make([]byte, 32<<10)
		var out []byte
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				out = append(out, buf[:n]...)
			}
			if err != nil {
				echoedMu.Lock()
				echoed = out
				echoedMu.Unlock()
				if err == io.EOF {
					readDone <- nil
				} else {
					readDone <- err
				}
				return
			}
		}
	}()
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))
	if _, err := conn.Write(payload); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	if cw, ok := conn.(*net.TCPConn); ok {
		if err := cw.CloseWrite(); err != nil {
			return fmt.Errorf("close write: %w", err)
		}
	}
	select {
	case err := <-readDone:
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
	case <-time.After(timeout):
		return fmt.Errorf("timed out waiting for echoed bytes")
	}
	echoedMu.Lock()
	got := echoed
	echoedMu.Unlock()
	if string(got) != string(payload) {
		return fmt.Errorf("echo mismatch: got %d bytes, want %d", len(got), len(payload))
	}
	return nil
}

// expectPhoneClosed asserts the relay drops a bridge connection quickly.
func expectPhoneClosed(t *testing.T, bridgeAddr string, timeout time.Duration) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", bridgeAddr, timeout)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 1)
	n, err := conn.Read(buf)
	if err == nil {
		t.Fatalf("bridge connection still open (read %d bytes)", n)
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("bridge connection was neither closed nor answered within %s", timeout)
	}
}
