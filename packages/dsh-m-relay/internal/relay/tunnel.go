package relay

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"dshm-relay/internal/authn"
	"dshm-relay/internal/wire"
)

// Protocol constants from design doc §4.4.
const (
	// streamBufferLimit is how many phone bytes the relay buffers while waiting
	// for the tunnel's `opened` frame.
	streamBufferLimit = 64 << 10
	// phoneReadChunk is the max bytes read from a phone socket per DATA frame.
	phoneReadChunk = 32 << 10
	// streamWriteTimeout bounds one blocking write to a phone socket.
	streamWriteTimeout = 30 * time.Second
	// controlWriteTimeout bounds one frame write to the tunnel.
	controlWriteTimeout = 10 * time.Second
	// helloReadTimeout bounds the wait for the hello frame.
	helloReadTimeout = 10 * time.Second
)

// --- JSON control messages (design doc §4.4) ---------------------------------

type readyMessage struct {
	T            string `json:"t"`
	V            int    `json:"v"`
	HostID       string `json:"hostId"`
	PublicHost   string `json:"publicHost"`
	Port         int    `json:"port"`
	Origin       string `json:"origin"`
	HeartbeatSec int    `json:"heartbeatSec"`
}

type errorMessage struct {
	T       string `json:"t"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type pingMessage struct {
	T  string `json:"t"`
	Ts int64  `json:"ts"`
}

type openMessage struct {
	T   string `json:"t"`
	Sid uint32 `json:"sid"`
}

type codeMessage struct {
	T                  string `json:"t"`
	Code               string `json:"code"`
	Exp                int64  `json:"exp"`
	LeafPin            string `json:"leafPin"`
	LeafFingerprint256 string `json:"leafFingerprint256"`
	HostName           string `json:"hostName"`
}

type openFailedMessage struct {
	T       string `json:"t"`
	Sid     uint32 `json:"sid"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type drainMessage struct {
	T      string `json:"t"`
	Reason string `json:"reason"`
}

// tunnelSession is one authenticated control connection from a Mac plugin.
type tunnelSession struct {
	srv      *Server
	conn     net.Conn
	br       *bufio.Reader
	ip       string
	hostID   string
	hostName string
	port     int
	bridgeLn net.Listener

	writeMu   sync.Mutex
	streamsMu sync.Mutex
	streams   map[uint32]*stream
	nextSid   uint32

	lastRecv     atomic.Int64 // unix nanos of the last frame received
	lastPingSent atomic.Int64 // unix nanos of the last ping sent
	bytesUp      atomic.Int64 // phone -> tunnel payload bytes
	bytesDown    atomic.Int64 // tunnel -> phone payload bytes

	closed    atomic.Bool
	supersede atomic.Bool
	closeOnce sync.Once
	closeCh   chan struct{}
	startedAt time.Time
}

// handleTunnel runs the whole lifecycle of one tunnel control connection.
func (s *Server) handleTunnel(conn net.Conn, ip string) {
	defer conn.Close()
	ses := &tunnelSession{
		srv:       s,
		conn:      conn,
		br:        bufio.NewReaderSize(conn, 64<<10),
		ip:        ip,
		streams:   make(map[uint32]*stream),
		nextSid:   1,
		closeCh:   make(chan struct{}),
		startedAt: s.now(),
	}
	_ = conn.SetReadDeadline(s.now().Add(helloReadTimeout))
	typ, payload, err := wire.ReadFrame(ses.br)
	if err != nil {
		s.log.Debug("tunnel: read hello failed", "ip", ip, "err", err)
		s.audit.Log("auth.fail", map[string]any{"ip": ip, "reason": "hello-read-failed"})
		return
	}
	if typ != wire.TypeJSON {
		s.audit.Log("auth.fail", map[string]any{"ip": ip, "reason": "first-frame-not-json"})
		ses.sendError(codeAuthInvalid, "first control frame must be a JSON hello")
		return
	}
	var hello authn.Hello
	if err := json.Unmarshal(payload, &hello); err != nil {
		s.audit.Log("auth.fail", map[string]any{"ip": ip, "reason": "hello-bad-json"})
		ses.sendError(codeAuthInvalid, "hello is not valid JSON")
		return
	}
	if verr := authn.VerifyHello(&hello, s.secret, s.now(), s.nonces); verr != nil {
		s.audit.Log("auth.fail", map[string]any{"ip": ip, "hostId": hello.HostID, "code": verr.Code})
		ses.sendError(verr.Code, verr.Message)
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	ses.hostID = hello.HostID
	ses.hostName = truncate(hello.HostName, 128)
	if ses.hostName == "" {
		ses.hostName = hello.HostID
	}
	wantPort := "-"
	if hello.WantPort != nil {
		wantPort = strconv.Itoa(*hello.WantPort)
	}
	s.audit.Log("host.connect", map[string]any{"hostId": ses.hostID, "ip": ip, "wantPort": wantPort})
	s.log.Info("tunnel authenticated", "hostId", ses.hostID, "ip", ip, "wantPort", wantPort)

	if s.draining.Load() {
		s.audit.Log("host.reject", map[string]any{"hostId": ses.hostID, "reason": codeServerBusy})
		ses.sendError(codeServerBusy, "relay is draining")
		return
	}

	// Registration is serialized: a reconnect for the same hostId replaces the
	// previous session (closing its bridge listener first so the port is bindable).
	s.helloMu.Lock()
	if old := s.session(ses.hostID); old != nil {
		old.supersede.Store(true)
		old.shutdown("superseded")
	}
	preferred := 0
	if p, ok := s.state.Port(ses.hostID); ok {
		preferred = p
	}
	port, bridgeLn, perr := s.portPool.acquire(ses.hostID, hello.WantPort, preferred)
	if perr != nil {
		s.helloMu.Unlock()
		s.audit.Log("host.reject", map[string]any{"hostId": ses.hostID, "reason": perr.Code})
		ses.sendError(perr.Code, perr.Message)
		return
	}
	ses.port = port
	ses.bridgeLn = bridgeLn
	s.codes.clearHost(ses.hostID)
	s.hostsMu.Lock()
	s.hosts[ses.hostID] = ses
	s.hostsMu.Unlock()
	s.helloMu.Unlock()

	if err := s.state.SetPort(ses.hostID, port); err != nil {
		s.log.Warn("state write failed", "hostId", ses.hostID, "err", err)
	}
	ready := readyMessage{
		T:            "ready",
		V:            1,
		HostID:       ses.hostID,
		PublicHost:   s.cfg.PublicHost,
		Port:         port,
		Origin:       s.originFor(port),
		HeartbeatSec: s.cfg.HeartbeatSec,
	}
	if err := ses.sendJSON(ready); err != nil {
		s.log.Warn("tunnel: send ready failed", "hostId", ses.hostID, "err", err)
		ses.cleanup()
		return
	}
	s.audit.Log("host.ready", map[string]any{
		"hostId": ses.hostID,
		"port":   port,
		"origin": s.originFor(port),
		"ip":     ip,
	})
	ses.start()
	if err := ses.readLoop(); err != nil &&
		!errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
		s.log.Debug("tunnel read loop ended", "hostId", ses.hostID, "err", err)
	}
	ses.cleanup()
}

func (s *Server) session(hostID string) *tunnelSession {
	s.hostsMu.Lock()
	defer s.hostsMu.Unlock()
	return s.hosts[hostID]
}

// unregisterSession removes ses if it is still the current session of its host
// and drops that host's rendezvous code.
func (s *Server) unregisterSession(ses *tunnelSession) {
	current := false
	s.hostsMu.Lock()
	if s.hosts[ses.hostID] == ses {
		delete(s.hosts, ses.hostID)
		current = true
	}
	s.hostsMu.Unlock()
	if current {
		s.codes.clearHost(ses.hostID)
	}
}

func (ses *tunnelSession) start() {
	now := ses.srv.now()
	ses.lastRecv.Store(now.UnixNano())
	ses.lastPingSent.Store(now.UnixNano())
	go ses.bridgeAcceptLoop()
	go ses.heartbeatLoop()
}

// cleanup tears the session down, unregisters it and writes the audit record.
func (ses *tunnelSession) cleanup() {
	ses.shutdown("closed")
	ses.srv.unregisterSession(ses)
	ses.srv.audit.Log("host.disconnect", map[string]any{
		"hostId":     ses.hostID,
		"port":       ses.port,
		"durMs":      ses.srv.now().Sub(ses.startedAt).Milliseconds(),
		"bytesUp":    ses.bytesUp.Load(),
		"bytesDown":  ses.bytesDown.Load(),
		"superseded": ses.supersede.Load(),
	})
}

// shutdown closes the control connection, bridge listener and all streams.
func (ses *tunnelSession) shutdown(reason string) {
	ses.closeOnce.Do(func() {
		ses.closed.Store(true)
		close(ses.closeCh)
		if ses.bridgeLn != nil {
			_ = ses.bridgeLn.Close()
		}
		_ = ses.conn.Close()
		ses.closeStreams(reason)
	})
}

func (ses *tunnelSession) closeStreams(reason string) {
	ses.streamsMu.Lock()
	streams := make([]*stream, 0, len(ses.streams))
	for _, st := range ses.streams {
		streams = append(streams, st)
	}
	ses.streamsMu.Unlock()
	for _, st := range streams {
		st.finish(reason)
	}
}

func (ses *tunnelSession) closeBridge() {
	if ses.bridgeLn != nil {
		_ = ses.bridgeLn.Close()
	}
}

func (ses *tunnelSession) sendDrain(reason string) {
	_ = ses.sendJSON(drainMessage{T: "drain", Reason: reason})
}

// --- frame writers -----------------------------------------------------------

func (ses *tunnelSession) sendJSON(v any) error {
	b, err := marshalJSON(v)
	if err != nil {
		return err
	}
	return ses.writeFrame(wire.TypeJSON, b)
}

func (ses *tunnelSession) writeFrame(typ byte, payload []byte) error {
	ses.writeMu.Lock()
	defer ses.writeMu.Unlock()
	if ses.closed.Load() {
		return net.ErrClosed
	}
	_ = ses.conn.SetWriteDeadline(ses.srv.now().Add(controlWriteTimeout))
	return wire.WriteFrame(ses.conn, typ, payload)
}

func (ses *tunnelSession) sendError(code, message string) {
	_ = ses.sendJSON(errorMessage{T: "error", Code: code, Message: message})
}

func (ses *tunnelSession) sendData(sid uint32, data []byte) error {
	return ses.writeFrame(wire.TypeData, wire.EncodeData(sid, data))
}

func (ses *tunnelSession) sendFIN(sid uint32) error {
	return ses.writeFrame(wire.TypeFin, wire.SidPayload(sid))
}

func (ses *tunnelSession) sendRST(sid uint32, code byte) error {
	return ses.writeFrame(wire.TypeRst, wire.EncodeRST(sid, code))
}

// --- heartbeat ---------------------------------------------------------------

func (ses *tunnelSession) heartbeatLoop() {
	interval := ses.srv.heartbeatInterval()
	tick := interval / 2
	if tick < 10*time.Millisecond {
		tick = 10 * time.Millisecond
	}
	ticker := time.NewTicker(tick)
	defer ticker.Stop()
	for {
		select {
		case <-ses.closeCh:
			return
		case now := <-ticker.C:
			lastRecv := time.Unix(0, ses.lastRecv.Load())
			if now.Sub(lastRecv) > 3*interval {
				ses.srv.log.Debug("tunnel heartbeat timeout", "hostId", ses.hostID)
				ses.srv.audit.Log("host.timeout", map[string]any{"hostId": ses.hostID, "reason": "heartbeat"})
				ses.shutdown("heartbeat-timeout")
				return
			}
			if now.Sub(time.Unix(0, ses.lastPingSent.Load())) >= interval {
				ses.lastPingSent.Store(now.UnixNano())
				if err := ses.sendJSON(pingMessage{T: "ping", Ts: now.UnixMilli()}); err != nil {
					ses.shutdown("ping-write-failed")
					return
				}
			}
		}
	}
}

// --- control frame reader ----------------------------------------------------

func (ses *tunnelSession) readLoop() error {
	for {
		typ, payload, err := wire.ReadFrame(ses.br)
		if err != nil {
			return err
		}
		ses.lastRecv.Store(ses.srv.now().UnixNano())
		switch typ {
		case wire.TypeJSON:
			if err := ses.onControlJSON(payload); err != nil {
				return err
			}
		case wire.TypeData:
			sid, data, err := wire.ParseData(payload)
			if err != nil {
				return fmt.Errorf("tunnel: bad DATA frame: %w", err)
			}
			if st := ses.stream(sid); st != nil {
				if err := st.tunnelData(data); err != nil {
					st.abort(wire.RstLocalIO)
				}
			} else {
				_ = ses.sendRST(sid, wire.RstProtocol)
			}
		case wire.TypeFin:
			sid, err := wire.ParseSID(payload)
			if err != nil {
				return fmt.Errorf("tunnel: bad FIN frame: %w", err)
			}
			if st := ses.stream(sid); st != nil {
				st.tunnelFIN()
			}
		case wire.TypeRst:
			sid, code, err := wire.ParseRST(payload)
			if err != nil {
				return fmt.Errorf("tunnel: bad RST frame: %w", err)
			}
			if st := ses.stream(sid); st != nil {
				st.tunnelRST(code)
			}
		default:
			return fmt.Errorf("tunnel: unsupported frame type 0x%02x", typ)
		}
	}
}

func (ses *tunnelSession) onControlJSON(payload []byte) error {
	var head struct {
		T string `json:"t"`
	}
	if err := json.Unmarshal(payload, &head); err != nil {
		return fmt.Errorf("tunnel: invalid JSON control frame: %w", err)
	}
	switch head.T {
	case "pong":
		return nil
	case "ping":
		var m pingMessage
		if err := json.Unmarshal(payload, &m); err != nil {
			return fmt.Errorf("tunnel: invalid ping: %w", err)
		}
		return ses.sendJSON(pingMessage{T: "pong", Ts: m.Ts})
	case "opened":
		var m struct {
			Sid uint32 `json:"sid"`
		}
		if err := json.Unmarshal(payload, &m); err != nil {
			return fmt.Errorf("tunnel: invalid opened: %w", err)
		}
		if st := ses.stream(m.Sid); st != nil {
			st.openOK()
		}
		return nil
	case "open_failed":
		var m openFailedMessage
		if err := json.Unmarshal(payload, &m); err != nil {
			return fmt.Errorf("tunnel: invalid open_failed: %w", err)
		}
		ses.srv.log.Debug("tunnel: stream dial failed", "hostId", ses.hostID, "sid", m.Sid, "code", m.Code)
		if st := ses.stream(m.Sid); st != nil {
			st.openFailed(m.Code, m.Message)
		}
		return nil
	case "code":
		var m codeMessage
		if err := json.Unmarshal(payload, &m); err != nil {
			return fmt.Errorf("tunnel: invalid code message: %w", err)
		}
		ses.srv.publishCode(ses, m)
		return nil
	case "code_clear":
		ses.srv.codes.clearHost(ses.hostID)
		ses.srv.audit.Log("code.clear", map[string]any{"hostId": ses.hostID})
		return nil
	case "ready", "hello", "open", "data", "fin", "rst", "drain":
 // Relay -> tunnel directions or handshake frames: ignore defensively.
		ses.srv.log.Debug("tunnel: ignoring unexpected control message", "hostId", ses.hostID, "t", head.T)
		return nil
	default:
		ses.srv.log.Debug("tunnel: ignoring unknown control message", "hostId", ses.hostID, "t", head.T)
		return nil
	}
}

// publishCode validates and installs the current pairing code reported by a Mac.
// The relay only stores rendezvous metadata; the code itself is never logged.
func (s *Server) publishCode(ses *tunnelSession, m codeMessage) {
	now := s.now()
	code := m.Code
	if !codeRe.MatchString(code) {
		s.audit.Log("code.publish", map[string]any{"hostId": ses.hostID, "ok": false, "reason": "bad-code"})
		return
	}
	if m.Exp <= now.Unix() {
		s.audit.Log("code.publish", map[string]any{"hostId": ses.hostID, "ok": false, "reason": "expired"})
		return
	}
	pin := m.LeafPin
	if !leafPinRe.MatchString(pin) {
		s.audit.Log("code.publish", map[string]any{"hostId": ses.hostID, "ok": false, "reason": "bad-leaf-pin"})
		return
	}
	if m.LeafFingerprint256 == "" || len(m.LeafFingerprint256) > 200 {
		s.audit.Log("code.publish", map[string]any{"hostId": ses.hostID, "ok": false, "reason": "bad-leaf-fingerprint"})
		return
	}
	hostName := truncate(m.HostName, 128)
	if hostName == "" {
		hostName = ses.hostName
	}
	s.codes.set(codeEntry{
		Code:               code,
		HostID:             ses.hostID,
		HostName:           hostName,
		Port:               ses.port,
		LeafPin:            pin,
		LeafFingerprint256: m.LeafFingerprint256,
		Exp:                m.Exp,
	})
	s.audit.Log("code.publish", map[string]any{"hostId": ses.hostID, "ok": true, "exp": m.Exp})
}

// --- bridge accept + stream lifecycle ---------------------------------------

func (ses *tunnelSession) bridgeAcceptLoop() {
	for {
		conn, err := ses.bridgeLn.Accept()
		if err != nil {
			if ses.closed.Load() || errors.Is(err, net.ErrClosed) {
				return
			}
			ses.srv.log.Debug("bridge accept failed", "hostId", ses.hostID, "port", ses.port, "err", err)
			return
		}
		go ses.handlePhone(conn)
	}
}

func (ses *tunnelSession) handlePhone(conn net.Conn) {
	srv := ses.srv
	if srv.draining.Load() || ses.closed.Load() {
		_ = conn.Close()
		return
	}
	if !srv.bridgeLimiter.allow(strconv.Itoa(ses.port)) {
		_ = conn.Close()
		srv.audit.Log("stream.reject", map[string]any{"hostId": ses.hostID, "reason": "bridge-rate-limited"})
		return
	}
	ses.streamsMu.Lock()
	if len(ses.streams) >= srv.cfg.MaxStreamsPerHost {
		ses.streamsMu.Unlock()
		_ = conn.Close()
		srv.audit.Log("stream.reject", map[string]any{"hostId": ses.hostID, "reason": "max-streams"})
		return
	}
	sid := ses.allocSidLocked()
	st := &stream{
		ses:       ses,
		sid:       sid,
		phone:     conn,
		openedCh:  make(chan struct{}),
		closeCh:   make(chan struct{}),
		startedAt: srv.now(),
	}
	ses.streams[sid] = st
	ses.streamsMu.Unlock()
	srv.audit.Log("stream.open", map[string]any{"hostId": ses.hostID, "sid": sid})
	if err := ses.sendJSON(openMessage{T: "open", Sid: sid}); err != nil {
		st.finish("tunnel-write-failed")
		return
	}
	st.start()
}

// allocSidLocked returns the next free odd sid; streamsMu must be held.
func (ses *tunnelSession) allocSidLocked() uint32 {
	for {
		sid := ses.nextSid
		ses.nextSid += 2
		if sid == 0 || sid == 1<<31 {
			ses.nextSid = 1
			continue
		}
		if _, exists := ses.streams[sid]; !exists {
			return sid
		}
	}
}

func (ses *tunnelSession) stream(sid uint32) *stream {
	ses.streamsMu.Lock()
	defer ses.streamsMu.Unlock()
	return ses.streams[sid]
}

func (ses *tunnelSession) removeStream(sid uint32) {
	ses.streamsMu.Lock()
	delete(ses.streams, sid)
	ses.streamsMu.Unlock()
}

// stream is one bridged phone TCP connection. phone -> tunnel bytes become DATA
// frames (after `opened`); tunnel DATA frames are written to the phone socket.
type stream struct {
	ses       *tunnelSession
	sid       uint32
	phone     net.Conn
	openedCh  chan struct{}
	closeCh   chan struct{}
	closeOnce sync.Once

	mu        sync.Mutex
	opened    bool
	finished  bool
	phoneFIN  bool // phone half-close observed (FIN sent once)
	phoneEOF  bool // FIN sent to the tunnel
	tunnelEOF bool
	pending   []byte

	startedAt time.Time
	bytesUp   atomic.Int64
	bytesDown atomic.Int64
}

func (st *stream) start() {
	go st.watchOpen()
	go st.phoneReadLoop()
}

func (st *stream) watchOpen() {
	timer := time.NewTimer(st.ses.srv.openTimeout())
	defer timer.Stop()
	select {
	case <-st.openedCh:
	case <-st.closeCh:
	case <-timer.C:
		st.ses.srv.log.Debug("stream: open timeout", "hostId", st.ses.hostID, "sid", st.sid)
		_ = st.ses.sendRST(st.sid, wire.RstTimeout)
		st.finish("open-timeout")
	case <-st.ses.closeCh:
		st.finish("tunnel-closed")
	}
}

// openOK handles the tunnel's `opened` frame (local dial succeeded). Buffered
// phone bytes must be sent immediately: a real phone sends its TLS ClientHello as
// one packet and then waits for the ServerHello, so there may be no further phone
// data (and no half-close) to trigger a later flush.
//
// The pending bytes are sent while st.mu is held so forwardFromPhone (which must
// acquire st.mu to observe opened=true) cannot interleave new DATA before them.
func (st *stream) openOK() {
	st.mu.Lock()
	if st.opened || st.finished {
		st.mu.Unlock()
		return
	}
	st.opened = true
	pending := st.pending
	st.pending = nil
	var sendErr error
	if len(pending) > 0 {
		sendErr = st.ses.sendData(st.sid, pending)
		if sendErr == nil {
			st.bytesUp.Add(int64(len(pending)))
			st.ses.bytesUp.Add(int64(len(pending)))
		}
	}
	st.mu.Unlock()
	close(st.openedCh)
	if sendErr != nil {
		st.finish("tunnel-write-failed")
	}
}

// openFailed handles `open_failed`: the relay closes the phone connection.
func (st *stream) openFailed(code, message string) {
	st.ses.srv.log.Debug("stream: open_failed", "hostId", st.ses.hostID, "sid", st.sid, "code", code, "message", truncate(message, 160))
	st.finish("open-failed")
}

// tunnelData writes one DATA frame payload to the phone socket.
func (st *stream) tunnelData(data []byte) error {
	_ = st.phone.SetWriteDeadline(st.ses.srv.now().Add(streamWriteTimeout))
	n, err := st.phone.Write(data)
	if n > 0 {
		st.bytesDown.Add(int64(n))
		st.ses.bytesDown.Add(int64(n))
	}
	if err != nil {
		return err
	}
	return nil
}

// tunnelFIN handles the tunnel's FIN: half-close the phone write side.
func (st *stream) tunnelFIN() {
	st.mu.Lock()
	if st.tunnelEOF || st.finished {
		st.mu.Unlock()
		return
	}
	st.tunnelEOF = true
	phoneGone := st.phoneEOF
	st.mu.Unlock()
	if cw, ok := st.phone.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	} else {
		_ = st.phone.Close()
	}
	if phoneGone {
		st.finish("eof")
	}
}

// tunnelRST handles the tunnel's RST: drop both sockets immediately.
func (st *stream) tunnelRST(code byte) {
	st.finish("tunnel-reset:" + wire.RstName(code))
}

// abort closes the stream and tells the tunnel to drop its local socket.
func (st *stream) abort(code byte) {
	_ = st.ses.sendRST(st.sid, code)
	st.finish("relay-reset:" + wire.RstName(code))
}

func (st *stream) isFinished() bool {
	select {
	case <-st.closeCh:
		return true
	default:
		return false
	}
}

func (st *stream) phoneReadLoop() {
	buf := make([]byte, phoneReadChunk)
	for {
		n, err := st.phone.Read(buf)
		if n > 0 {
			if !st.forwardFromPhone(buf[:n]) {
				return
			}
		}
		if err != nil {
			if st.isFinished() {
				return
			}
			if errors.Is(err, io.EOF) {
				st.phoneEOFReached()
				return
			}
			_ = st.ses.sendRST(st.sid, wire.RstLocalIO)
			st.finish("phone-read-failed")
			return
		}
	}
}

// forwardFromPhone forwards bytes read from the phone to the tunnel. Before
// `opened` it buffers up to streamBufferLimit bytes (design doc §4.4 step 1).
func (st *stream) forwardFromPhone(p []byte) bool {
	for {
		st.mu.Lock()
		if st.finished {
			st.mu.Unlock()
			return false
		}
		if st.opened {
			st.mu.Unlock()
 // openOK flushes pending bytes before opened becomes observable, so
 // nothing can be buffered here; send this read straight through.
			return st.sendDataCounted(p) == nil
		}
		if len(st.pending)+len(p) <= streamBufferLimit {
			st.pending = append(st.pending, p...)
			st.mu.Unlock()
			return true
		}
		st.mu.Unlock()
		select {
		case <-st.openedCh:
		case <-st.closeCh:
			return false
		case <-st.ses.closeCh:
			return false
		}
	}
}

// flushPending sends bytes buffered before `opened` to the tunnel. Normally
// openOK already flushed them; this is a safety net for the half-close path and
// must only be called from the phone-read goroutine so DATA ordering holds.
func (st *stream) flushPending() bool {
	st.mu.Lock()
	if st.finished {
		st.mu.Unlock()
		return false
	}
	pending := st.pending
	st.pending = nil
	st.mu.Unlock()
	if len(pending) == 0 {
		return true
	}
	return st.sendDataCounted(pending) == nil
}

func (st *stream) sendDataCounted(p []byte) error {
	if err := st.ses.sendData(st.sid, p); err != nil {
		st.finish("tunnel-write-failed")
		return err
	}
	st.bytesUp.Add(int64(len(p)))
	st.ses.bytesUp.Add(int64(len(p)))
	return nil
}

// phoneEOFReached flushes any pre-`opened` buffered bytes, sends FIN to the
// tunnel after the phone half-closed, and finishes when both directions are done.
func (st *stream) phoneEOFReached() {
	st.mu.Lock()
	if st.finished || st.phoneEOF || st.phoneFIN {
		st.mu.Unlock()
		return
	}
	st.phoneFIN = true
	opened := st.opened
	st.mu.Unlock()

	if !opened {
 // The phone may half-close before the tunnel confirms `opened` (it usually
 // sends its TLS ClientHello and FIN immediately). Wait for the handshake
 // so buffered bytes are still delivered in order before FIN.
		select {
		case <-st.openedCh:
		case <-st.closeCh:
			return
		case <-st.ses.closeCh:
			return
		case <-time.After(st.ses.srv.openTimeout()):
			return // watchOpen will abort the stream with RST(timeout)
		}
	}
	if !st.flushPending() {
		return
	}
	if err := st.ses.sendFIN(st.sid); err != nil {
		st.finish("tunnel-write-failed")
		return
	}
	st.mu.Lock()
	st.phoneEOF = true
	tunnelGone := st.tunnelEOF
	st.mu.Unlock()
	if tunnelGone {
		st.finish("eof")
	}
}

// finish closes the phone socket, unregisters the stream and writes the audit
// record exactly once.
func (st *stream) finish(reason string) {
	st.closeOnce.Do(func() {
		st.mu.Lock()
		st.finished = true
		st.mu.Unlock()
		_ = st.phone.Close()
		close(st.closeCh)
		st.ses.removeStream(st.sid)
		st.ses.srv.audit.Log("stream.close", map[string]any{
			"hostId":    st.ses.hostID,
			"sid":       st.sid,
			"reason":    reason,
			"durMs":     st.ses.srv.now().Sub(st.startedAt).Milliseconds(),
			"bytesUp":   st.bytesUp.Load(),
			"bytesDown": st.bytesDown.Load(),
		})
	})
}
