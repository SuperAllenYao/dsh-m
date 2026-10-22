// Command tunnelprobe is a local end-to-end exerciser for the DSH-m relay.
//
// It plays both roles needed for a two-process demo:
// - the Mac tunnel: TLS + ALPN dshm-relay/1, HMAC hello, `ready`, then answers
// `open` frames by dialing a local echo server and relaying DATA/FIN/RST;
// - the phone/App: dials the relay's bridge port (opaque TCP) and verifies the
// byte round trip, and uses /v1/lookup + /healthz with the relay pin.
//
// It exercises: handshake, ready fields, optional persisted-port reuse, code
// publish -> lookup hit/miss/expired, TLS pin rejection, no-ALPN HTTP fallback,
// bridge echo (small + 128 KiB with half-close) and graceful tunnel shutdown.
//
// This is a dev/demo tool, not a production tunnel client (the real one is the
// Mac plugin's tunnel.js).
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"dshm-relay/internal/authn"
	"dshm-relay/internal/certs"
	"dshm-relay/internal/relay"
	"dshm-relay/internal/wire"
)

func main() {
	var (
		addrFile   = flag.String("addr-file", "", "JSON file written by `dshm-relay serve --addr-file`")
		control    = flag.String("control", "", "relay control address host:port (overrides --addr-file)")
		pin        = flag.String("pin", "", "expected relay certificate pin (base64url SHA-256 DER)")
		secretFile = flag.String("secret-file", "", "file containing the relay HMAC secret")
		secretFlag = flag.String("secret", "", "relay HMAC secret inline (alternative to --secret-file)")
		hostID     = flag.String("host-id", "tunnelprobe-host-1", "tunnel hostId")
		hostName   = flag.String("host-name", "tunnelprobe", "tunnel hostName")
		code       = flag.String("code", "12345678", "pairing code to publish for the lookup checks")
		wantPort   = flag.Int("want-port", 0, "request this bridge port in hello (0 = let the relay choose)")
		expectPort = flag.Int("expect-port", 0, "assert the relay assigns exactly this bridge port (state reuse check)")
		bridgeHost = flag.String("bridge-host", "", "host to dial for the bridge echo check (default: control host)")
		timeout    = flag.Duration("timeout", 20*time.Second, "per-step timeout")
		skipLookup = flag.Bool("skip-lookup", false, "skip /v1/lookup checks")
		skipBridge = flag.Bool("skip-bridge", false, "skip bridge echo checks")
		waitDrain  = flag.Bool("wait-drain", false, "after checks, keep the control connection open and wait for the relay's drain frame (requires --skip-bridge; used by dev-demo.sh)")

 // Latency/throughput baseline (M2a acceptance record); scripts/bench.sh
 // orchestrates relay + this binary and wraps the JSON output.
		benchRun         = flag.Bool("bench", false, "run the latency/throughput baseline instead of the correctness checks")
		benchSizes       = flag.String("bench-sizes", "1024,65536", "comma-separated payload sizes in bytes")
		benchConcurrency = flag.String("bench-concurrency", "1,4,16", "comma-separated stream concurrency levels")
		benchIterations  = flag.Int("bench-iterations", 30, "measured round trips per stream")
		benchWarmup      = flag.Int("bench-warmup", 5, "warmup round trips per stream")
		benchOutput      = flag.String("bench-output", "", "also write the bench JSON report to this file")
	)
	flag.Parse()

	if *pin == "" {
		fatalf("--pin is required")
	}
	controlAddr := *control
	if controlAddr == "" {
		if *addrFile == "" {
			fatalf("either --control or --addr-file is required")
		}
		data, err := os.ReadFile(*addrFile)
		if err != nil {
			fatalf("read --addr-file: %v", err)
		}
		var info struct {
			Control string `json:"control"`
		}
		if err := json.Unmarshal(data, &info); err != nil {
			fatalf("parse --addr-file: %v", err)
		}
		controlAddr = info.Control
	}
	secret := []byte(*secretFlag)
	if len(secret) == 0 && *secretFile != "" {
		data, err := os.ReadFile(*secretFile)
		if err != nil {
			fatalf("read --secret-file: %v", err)
		}
		secret = []byte(strings.TrimSpace(string(data)))
	}
	if len(secret) == 0 {
		fatalf("either --secret or --secret-file is required")
	}
	host := *bridgeHost
	if host == "" {
		h, _, err := net.SplitHostPort(controlAddr)
		if err != nil {
			fatalf("parse --control address: %v", err)
		}
		host = h
	}
	p := &probe{
		controlAddr: controlAddr,
		bridgeHost:  host,
		pin:         *pin,
		secret:      secret,
		hostID:      *hostID,
		hostName:    *hostName,
		code:        *code,
		expectPort:  *expectPort,
		timeout:     *timeout,
		skipLookup:  *skipLookup,
		skipBridge:  *skipBridge,
		waitDrain:   *waitDrain,
		streams:     make(map[uint32]net.Conn),
	}
	if *wantPort > 0 {
		p.wantPort = wantPort
	}
	if p.waitDrain && !p.skipBridge {
		fatalf("--wait-drain requires --skip-bridge (the control reader is used synchronously)")
	}
	if *benchRun {
		sizes, err := parseIntListFlag(*benchSizes)
		if err != nil {
			fatalf("--bench-sizes: %v", err)
		}
		concurrency, err := parseIntListFlag(*benchConcurrency)
		if err != nil {
			fatalf("--bench-concurrency: %v", err)
		}
		if *benchIterations < 1 || *benchWarmup < 0 {
			fatalf("--bench-iterations must be >= 1 and --bench-warmup >= 0")
		}
		p.quiet = true
		p.bench = &benchOptions{sizes: sizes, concurrency: concurrency, iterations: *benchIterations, warmup: *benchWarmup}
		if err := p.runBenchMode(*benchOutput); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL tunnelprobe bench: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if err := p.run(); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL tunnelprobe: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("PASS tunnelprobe: %d checks passed\n", p.passed)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL tunnelprobe: "+format+"\n", args...)
	os.Exit(2)
}

type probe struct {
	controlAddr string
	bridgeHost  string
	pin         string
	secret      []byte
	hostID      string
	hostName    string
	code        string
	wantPort    *int
	expectPort  int
	timeout     time.Duration
	skipLookup  bool
	skipBridge  bool
	waitDrain   bool

	echoLn   net.Listener
	echoPort int

	conn    net.Conn
	br      *bufio.Reader
	writeMu sync.Mutex

	streamsMu sync.Mutex
	streams   map[uint32]net.Conn

	passed int

	// Bench mode (scripts/bench.sh): suppresses correctness output and counts
	// accepted `open` frames so the report can include streams opened.
	quiet bool
	bench *benchOptions
	opens atomic.Int64
}

// readyInfo is the relay's `ready` control message (design §4.4).
type readyInfo struct {
	T            string `json:"t"`
	V            int    `json:"v"`
	HostID       string `json:"hostId"`
	PublicHost   string `json:"publicHost"`
	Port         int    `json:"port"`
	Origin       string `json:"origin"`
	HeartbeatSec int    `json:"heartbeatSec"`
}

func (p *probe) pass(name, detail string) {
	p.passed++
	if p.quiet {
		return
	}
	fmt.Printf("PASS %-14s %s\n", name+":", detail)
}

func (p *probe) run() error {
	if err := p.startEcho(); err != nil {
		return fmt.Errorf("start echo server: %w", err)
	}
	p.pass("echo", fmt.Sprintf("127.0.0.1:%d echoes bytes (tunnel's local target)", p.echoPort))

	ready, err := p.connect()
	if err != nil {
		return err
	}
	if p.expectPort > 0 {
		if ready.Port != p.expectPort {
			return fmt.Errorf("state reuse: expected bridge port %d, got %d", p.expectPort, ready.Port)
		}
		p.pass("state", fmt.Sprintf("bridge port %d reused from state.json", ready.Port))
	}
	if p.waitDrain {
		fmt.Println("READY_FOR_DRAIN")
		return p.waitDrainFrame(30 * time.Second)
	}
	go p.controlLoop()

	if !p.skipBridge {
		if err := p.bridgeChecks(ready.Port); err != nil {
			return err
		}
	}
	if !p.skipLookup {
		if err := p.lookupChecks(ready); err != nil {
			return err
		}
	}
	_ = p.conn.Close()
	return nil
}

// --- tunnel side -------------------------------------------------------------

func (p *probe) connect() (ready readyInfo, err error) {
	raw, err := net.DialTimeout("tcp", p.controlAddr, p.timeout)
	if err != nil {
		return ready, fmt.Errorf("dial relay control %s: %w", p.controlAddr, err)
	}
	tlsConn := tls.Client(raw, &tls.Config{
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: certs.VerifyPin(p.pin),
		NextProtos:            []string{relay.ALPNRelay},
		MinVersion:            tls.VersionTLS12,
	})
	_ = tlsConn.SetDeadline(time.Now().Add(p.timeout))
	if err := tlsConn.Handshake(); err != nil {
		_ = tlsConn.Close()
		return ready, fmt.Errorf("relay TLS/pin handshake: %w", err)
	}
	if got := tlsConn.ConnectionState().NegotiatedProtocol; got != relay.ALPNRelay {
		_ = tlsConn.Close()
		return ready, fmt.Errorf("ALPN = %q, want %q", got, relay.ALPNRelay)
	}
	p.conn = tlsConn
	p.br = bufio.NewReaderSize(tlsConn, 64<<10)

	now := time.Now()
	nonce := randomNonce()
	ts := now.UnixMilli()
	hello := map[string]any{
		"t":        "hello",
		"v":        1,
		"hostId":   p.hostID,
		"hostName": p.hostName,
		"ts":       ts,
		"nonce":    nonce,
		"auth":     authn.ComputeAuth(p.secret, p.hostID, ts, nonce, p.wantPort),
		"meta":     map[string]any{"plugin": "dshm-tunnelprobe", "proto": "dshm/1"},
	}
	if err := p.sendJSON(hello); err != nil {
		return ready, fmt.Errorf("send hello: %w", err)
	}
	typ, payload, err := wire.ReadFrame(p.br)
	if err != nil {
		return ready, fmt.Errorf("read hello response: %w", err)
	}
	if typ != wire.TypeJSON {
		return ready, fmt.Errorf("hello response frame type = 0x%02x, want JSON", typ)
	}
	var maybeErr struct {
		T    string `json:"t"`
		Code string `json:"code"`
	}
	_ = json.Unmarshal(payload, &maybeErr)
	if maybeErr.T == "error" {
		return ready, fmt.Errorf("relay rejected hello: %s", string(payload))
	}
	if err := json.Unmarshal(payload, &ready); err != nil {
		return ready, fmt.Errorf("parse ready: %w", err)
	}
	if ready.T != "ready" || ready.V != 1 {
		return ready, fmt.Errorf("unexpected hello response: %s", string(payload))
	}
	if ready.HostID != p.hostID {
		return ready, fmt.Errorf("ready hostId = %q, want %q", ready.HostID, p.hostID)
	}
	if ready.Port <= 0 || ready.HeartbeatSec <= 0 || ready.Origin == "" {
		return ready, fmt.Errorf("ready fields incomplete: %s", string(payload))
	}
	if p.wantPort != nil && ready.Port != *p.wantPort {
		return ready, fmt.Errorf("ready port = %d, wantPort = %d", ready.Port, *p.wantPort)
	}
	_ = tlsConn.SetDeadline(time.Time{})
	if !p.quiet {
		fmt.Printf("BRIDGE_PORT=%d\n", ready.Port)
		fmt.Printf("PUBLIC_ORIGIN=%s\n", ready.Origin)
	}
	p.pass("handshake", fmt.Sprintf("ready hostId=%s port=%d origin=%s heartbeatSec=%d",
		ready.HostID, ready.Port, ready.Origin, ready.HeartbeatSec))
	return ready, nil
}

// waitDrainFrame reads control frames synchronously (no bridge checks running)
// until the relay's drain frame arrives or the connection closes.
func (p *probe) waitDrainFrame(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		_ = p.conn.SetReadDeadline(deadline)
		typ, payload, err := wire.ReadFrame(p.br)
		if err != nil {
			return fmt.Errorf("tunnel closed before receiving drain: %w", err)
		}
		if typ != wire.TypeJSON {
			continue
		}
		var m struct {
			T      string `json:"t"`
			Reason string `json:"reason"`
			Ts     int64  `json:"ts"`
		}
		if err := json.Unmarshal(payload, &m); err != nil {
			continue
		}
		switch m.T {
		case "ping":
			_ = p.sendJSON(map[string]any{"t": "pong", "ts": m.Ts})
		case "drain":
			p.pass("drain", fmt.Sprintf("received drain reason=%s before close", m.Reason))
			return nil
		}
	}
	return fmt.Errorf("timed out waiting for drain frame")
}

func (p *probe) controlLoop() {
	for {
		typ, payload, err := wire.ReadFrame(p.br)
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
			case "open":
				go p.acceptOpen(head.Sid)
			case "ping":
				_ = p.sendJSON(map[string]any{"t": "pong", "ts": head.Ts})
			case "drain":
				fmt.Println("DRAIN received from relay")
			}
		case wire.TypeData:
			sid, data, err := wire.ParseData(payload)
			if err != nil {
				return
			}
			if c := p.stream(sid); c != nil {
				_, _ = c.Write(data)
			}
		case wire.TypeFin:
			sid, err := wire.ParseSID(payload)
			if err != nil {
				return
			}
			if c := p.stream(sid); c != nil {
				if cw, ok := c.(*net.TCPConn); ok {
					_ = cw.CloseWrite()
				} else {
					_ = c.Close()
				}
			}
		case wire.TypeRst:
			sid, _, err := wire.ParseRST(payload)
			if err != nil {
				return
			}
			if c := p.takeStream(sid); c != nil {
				_ = c.Close()
			}
		}
	}
}

// acceptOpen handles a relay `open`: dial the local echo target and pump bytes.
func (p *probe) acceptOpen(sid uint32) {
	p.opens.Add(1)
	conn, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(p.echoPort), p.timeout)
	if err != nil {
		_ = p.sendJSON(map[string]any{"t": "open_failed", "sid": sid, "code": "local/dial-failed", "message": err.Error()})
		return
	}
	p.streamsMu.Lock()
	p.streams[sid] = conn
	p.streamsMu.Unlock()
	if err := p.sendJSON(map[string]any{"t": "opened", "sid": sid}); err != nil {
		_ = conn.Close()
		return
	}
	go func() {
		buf := make([]byte, 32<<10)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				if sendErr := p.sendData(sid, buf[:n]); sendErr != nil {
					_ = conn.Close()
					return
				}
			}
			if err != nil {
				_ = p.sendFrame(wire.TypeFin, wire.SidPayload(sid))
				p.streamsMu.Lock()
				delete(p.streams, sid)
				p.streamsMu.Unlock()
				return
			}
		}
	}()
}

func (p *probe) stream(sid uint32) net.Conn {
	p.streamsMu.Lock()
	defer p.streamsMu.Unlock()
	return p.streams[sid]
}

func (p *probe) takeStream(sid uint32) net.Conn {
	p.streamsMu.Lock()
	defer p.streamsMu.Unlock()
	c := p.streams[sid]
	delete(p.streams, sid)
	return c
}

func (p *probe) sendJSON(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return p.sendFrame(wire.TypeJSON, data)
}

func (p *probe) sendData(sid uint32, data []byte) error {
	return p.sendFrame(wire.TypeData, wire.EncodeData(sid, data))
}

func (p *probe) sendFrame(typ byte, payload []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_ = p.conn.SetWriteDeadline(time.Now().Add(p.timeout))
	return wire.WriteFrame(p.conn, typ, payload)
}

// --- phone side --------------------------------------------------------------

func (p *probe) startEcho() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	p.echoLn = ln
	p.echoPort = ln.Addr().(*net.TCPAddr).Port
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
	return nil
}

func (p *probe) bridgeChecks(bridgePort int) error {
	small := []byte("hello-through-dshm-relay\n")
	if err := p.phoneEcho(bridgePort, small); err != nil {
		return fmt.Errorf("bridge echo (small): %w", err)
	}
	p.pass("bridge-small", fmt.Sprintf("%d bytes round trip via bridge port %d", len(small), bridgePort))

	payload := make([]byte, 128<<10)
	for i := range payload {
		payload[i] = byte(i*31 + 7) // covers all byte values
	}
	if err := p.phoneEcho(bridgePort, payload); err != nil {
		return fmt.Errorf("bridge echo (128 KiB): %w", err)
	}
	p.pass("bridge-large", fmt.Sprintf("%d bytes round trip with half-close EOF", len(payload)))
	return nil
}

// phoneEcho opens a raw TCP connection to the bridge port (like the phone's TLS
// socket would, but plain TCP here since the relay is byte-transparent), writes
// payload, half-closes, and compares the echoed bytes.
func (p *probe) phoneEcho(bridgePort int, payload []byte) error {
	addr := net.JoinHostPort(p.bridgeHost, strconv.Itoa(bridgePort))
	conn, err := net.DialTimeout("tcp", addr, p.timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	var echoed bytes.Buffer
	readDone := make(chan error, 1)
	go func() {
		_, err := io.Copy(&echoed, conn)
		readDone <- err
	}()
	_ = conn.SetWriteDeadline(time.Now().Add(p.timeout))
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
			return fmt.Errorf("read echoed bytes: %w", err)
		}
	case <-time.After(p.timeout):
		return fmt.Errorf("timed out waiting for echoed bytes")
	}
	if !bytes.Equal(echoed.Bytes(), payload) {
		return fmt.Errorf("echo mismatch: got %d bytes, want %d", echoed.Len(), len(payload))
	}
	return nil
}

// --- App side: lookup + healthz ---------------------------------------------

func (p *probe) pinnedClient(pin string) *http.Client {
	return &http.Client{
		Timeout: p.timeout,
		Transport: &http.Transport{
			DisableKeepAlives: true,
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify:    true,
				VerifyPeerCertificate: certs.VerifyPin(pin),
				NextProtos:            []string{"http/1.1"},
				MinVersion:            tls.VersionTLS12,
			},
		},
	}
}

func (p *probe) fakeLeafPin() string {
	sum := sha256.Sum256([]byte("tunnelprobe-leaf-certificate"))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func (p *probe) fakeLeafFingerprint() string {
	sum := sha256.Sum256([]byte("tunnelprobe-leaf-certificate"))
	hexStr := strings.ToUpper(hex.EncodeToString(sum[:]))
	parts := make([]string, 0, len(hexStr)/2)
	for i := 0; i < len(hexStr); i += 2 {
		parts = append(parts, hexStr[i:i+2])
	}
	return strings.Join(parts, ":")
}

func (p *probe) lookupChecks(ready readyInfo) error {
	client := p.pinnedClient(p.pin)
	leafPin := p.fakeLeafPin()
	fingerprint := p.fakeLeafFingerprint()
	exp := time.Now().Add(90 * time.Second).Unix()

	// healthz over pinned HTTP/1.1.
	resp, body, err := p.httpGet(client, "https://"+p.controlAddr+"/healthz")
	if err != nil {
		return fmt.Errorf("healthz: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthz status = %d", resp.StatusCode)
	}
	if !bytes.Contains(body, []byte(`"ok":true`)) {
		return fmt.Errorf("healthz body = %s", string(body))
	}
	if bytes.Contains(body, []byte("secret")) {
		return fmt.Errorf("healthz leaked a secret field: %s", string(body))
	}
	p.pass("healthz", "200 pinned HTTPS/1.1, no secret fields")

	// Publish code via the control connection, then look it up.
	if err := p.sendJSON(map[string]any{
		"t":                  "code",
		"code":               p.code,
		"exp":                exp,
		"leafPin":            leafPin,
		"leafFingerprint256": fingerprint,
		"hostName":           p.hostName + "-mac",
	}); err != nil {
		return fmt.Errorf("publish code: %w", err)
	}
	time.Sleep(100 * time.Millisecond) // code frame processed by the relay read loop

	status, entry, err := p.lookup(client, p.code)
	if err != nil {
		return fmt.Errorf("lookup hit: %w", err)
	}
	if status != http.StatusOK {
		return fmt.Errorf("lookup status = %d, want 200 (%v)", status, entry)
	}
	wantOrigin := ready.Origin
	if entry["hostId"] != p.hostID || entry["origin"] != wantOrigin ||
		entry["leafPin"] != leafPin || entry["leafFingerprint256"] != fingerprint ||
		entry["hostName"] != p.hostName+"-mac" {
		return fmt.Errorf("lookup response mismatch: %v", entry)
	}
	if expFloat, ok := entry["exp"].(float64); !ok || int64(expFloat) != exp {
		return fmt.Errorf("lookup exp = %v, want %d", entry["exp"], exp)
	}
	if _, leaked := entry["code"]; leaked {
		return fmt.Errorf("lookup response must not contain the pairing code")
	}
	p.pass("lookup-hit", fmt.Sprintf("200 hostId=%s origin=%s", entry["hostId"], entry["origin"]))

	// Unknown code -> 404 code/not-found.
	status, entry, err = p.lookup(client, "00000000")
	if err != nil {
		return fmt.Errorf("lookup miss: %w", err)
	}
	if status != http.StatusNotFound || entry["error"] != "code/not-found" {
		return fmt.Errorf("lookup miss = %d %v", status, entry)
	}
	p.pass("lookup-miss", "404 code/not-found")

	// Expiring code -> 410 code/expired.
	expiring := time.Now().Add(1 * time.Second).Unix()
	if err := p.sendJSON(map[string]any{
		"t":                  "code",
		"code":               "87654321",
		"exp":                expiring,
		"leafPin":            leafPin,
		"leafFingerprint256": fingerprint,
		"hostName":           p.hostName + "-mac",
	}); err != nil {
		return fmt.Errorf("publish expiring code: %w", err)
	}
	time.Sleep(1300 * time.Millisecond)
	status, entry, err = p.lookup(client, "87654321")
	if err != nil {
		return fmt.Errorf("lookup expired: %w", err)
	}
	if status != http.StatusGone || entry["error"] != "code/expired" {
		return fmt.Errorf("lookup expired = %d %v", status, entry)
	}
	p.pass("lookup-expired", "410 code/expired")

	// Wrong pin must be rejected during the TLS handshake.
	wrong := []byte(p.pin)
	if wrong[len(wrong)-1] == 'A' {
		wrong[len(wrong)-1] = 'B'
	} else {
		wrong[len(wrong)-1] = 'A'
	}
	if _, _, err := p.httpGet(p.pinnedClient(string(wrong)), "https://"+p.controlAddr+"/healthz"); err == nil {
		return fmt.Errorf("pin-reject: wrong relay pin was accepted")
	}
	p.pass("pin-reject", "wrong relay pin rejected at TLS handshake")

	// No-ALPN TLS must fall back to HTTP/1.1 (design doc §4.4).
	if err := p.noALPNHealthz(); err != nil {
		return fmt.Errorf("no-alpn fallback: %w", err)
	}
	p.pass("no-alpn", "TLS without ALPN served HTTP/1.1 /healthz")
	return nil
}

func (p *probe) httpGet(client *http.Client, url string) (*http.Response, []byte, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return resp, nil, err
	}
	return resp, body, nil
}

func (p *probe) lookup(client *http.Client, code string) (int, map[string]any, error) {
	reqBody := `{"code":"` + code + `"}`
	resp, err := client.Post("https://"+p.controlAddr+"/v1/lookup", "application/json", strings.NewReader(reqBody))
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return resp.StatusCode, nil, err
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		return resp.StatusCode, nil, fmt.Errorf("invalid JSON response: %w", err)
	}
	return resp.StatusCode, decoded, nil
}

func (p *probe) noALPNHealthz() error {
	raw, err := net.DialTimeout("tcp", p.controlAddr, p.timeout)
	if err != nil {
		return err
	}
	defer raw.Close()
	// No NextProtos: the client sends no ALPN extension; the relay must treat the
	// connection as HTTP/1.1.
	tlsConn := tls.Client(raw, &tls.Config{
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: certs.VerifyPin(p.pin),
		MinVersion:            tls.VersionTLS12,
	})
	_ = tlsConn.SetDeadline(time.Now().Add(p.timeout))
	if err := tlsConn.Handshake(); err != nil {
		return err
	}
	if got := tlsConn.ConnectionState().NegotiatedProtocol; got != "" {
		return fmt.Errorf("negotiated ALPN = %q, want none", got)
	}
	req := "GET /healthz HTTP/1.1\r\nHost: " + p.controlAddr + "\r\nConnection: close\r\n\r\n"
	if _, err := io.WriteString(tlsConn, req); err != nil {
		return err
	}
	resp, err := http.ReadResponse(bufio.NewReader(tlsConn), nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status = %d", resp.StatusCode)
	}
	return nil
}

// --- latency/throughput baseline (M2a acceptance record) --------------------

type benchOptions struct {
	sizes       []int
	concurrency []int
	iterations  int
	warmup      int
}

type benchLatency struct {
	P50  float64 `json:"p50"`
	P95  float64 `json:"p95"`
	Mean float64 `json:"mean"`
	Max  float64 `json:"max"`
}

type benchResult struct {
	PayloadBytes          int          `json:"payloadBytes"`
	Concurrency           int          `json:"concurrency"`
	IterationsPerStream   int          `json:"iterationsPerStream"`
	RoundTrips            int          `json:"roundTrips"`
	StreamsOpened         int64        `json:"streamsOpened"`
	DurationMs            float64      `json:"durationMs"`
	LatencyMs             benchLatency `json:"latencyMs"`
	ThroughputBytesPerSec float64      `json:"throughputBytesPerSec"` // echoed payload bytes/s (one direction; wire ≈2x)
	Errors                int          `json:"errors"`
}

type benchReport struct {
	Tool      string `json:"tool"`
	Version   string `json:"version"`
	Timestamp string `json:"timestamp"`
	Relay     struct {
		ControlAddr string `json:"controlAddr"`
		Origin      string `json:"origin"`
		BridgePort  int    `json:"bridgePort"`
		PublicHost  string `json:"publicHost"`
	} `json:"relay"`
	Params struct {
		Sizes       []int `json:"sizes"`
		Concurrency []int `json:"concurrency"`
		Iterations  int   `json:"iterations"`
		Warmup      int   `json:"warmup"`
	} `json:"params"`
	Results []benchResult `json:"results"`
}

func parseIntListFlag(value string) ([]int, error) {
	parts := strings.Split(value, ",")
	out := make([]int, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.Atoi(part)
		if err != nil || n < 1 {
			return nil, fmt.Errorf("invalid positive integer %q", part)
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("empty list")
	}
	return out, nil
}

// runBenchMode performs the handshake, then measures round-trip latency and
// throughput against the local echo target and prints one JSON report.
func (p *probe) runBenchMode(output string) error {
	if err := p.startEcho(); err != nil {
		return fmt.Errorf("start echo server: %w", err)
	}
	ready, err := p.connect()
	if err != nil {
		return err
	}
	go p.controlLoop()
	report, err := p.runBench(ready)
	if err != nil {
		return err
	}
	_ = p.conn.Close()
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if output != "" {
		if err := os.WriteFile(output, data, 0o644); err != nil {
			return fmt.Errorf("write --bench-output: %w", err)
		}
	}
	fmt.Print(string(data))
	return nil
}

func (p *probe) runBench(ready readyInfo) (*benchReport, error) {
	report := &benchReport{
		Tool:      "dshm-relay-bench",
		Version:   "M2a-local-1",
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}
	report.Relay.ControlAddr = p.controlAddr
	report.Relay.Origin = ready.Origin
	report.Relay.BridgePort = ready.Port
	report.Relay.PublicHost = ready.PublicHost
	report.Params.Sizes = p.bench.sizes
	report.Params.Concurrency = p.bench.concurrency
	report.Params.Iterations = p.bench.iterations
	report.Params.Warmup = p.bench.warmup

	for _, size := range p.bench.sizes {
		for _, concurrency := range p.bench.concurrency {
			result, err := p.benchOne(ready.Port, size, concurrency)
			if err != nil {
				return nil, fmt.Errorf("size=%d concurrency=%d: %w", size, concurrency, err)
			}
			report.Results = append(report.Results, result)
			fmt.Fprintf(os.Stderr,
				"bench %6d B x %2d conns: p50=%.3fms p95=%.3fms mean=%.3fms max=%.3fms thr=%.2f MiB/s opens=%d\n",
				size, concurrency, result.LatencyMs.P50, result.LatencyMs.P95,
				result.LatencyMs.Mean, result.LatencyMs.Max,
				result.ThroughputBytesPerSec/(1<<20), result.StreamsOpened)
			p.waitNoStreams(2 * time.Second)
		}
	}
	return report, nil
}

func (p *probe) benchOne(bridgePort, size, concurrency int) (benchResult, error) {
	zero := benchResult{}
	payload := make([]byte, size)
	for i := range payload {
		payload[i] = byte(i*131 + 17)
	}
	addr := net.JoinHostPort(p.bridgeHost, strconv.Itoa(bridgePort))
	conns := make([]net.Conn, 0, concurrency)
	defer func() {
		for _, conn := range conns {
			_ = conn.Close()
		}
	}()
	opensBefore := p.opens.Load()
	for i := 0; i < concurrency; i++ {
		conn, err := net.DialTimeout("tcp", addr, p.timeout)
		if err != nil {
			return zero, fmt.Errorf("dial bridge stream %d: %w", i, err)
		}
		conns = append(conns, conn)
	}
	// Warmup establishes every stream (open -> opened) and primes socket buffers.
	buf := make([]byte, len(payload))
	for _, conn := range conns {
		for w := 0; w < p.bench.warmup; w++ {
			if _, err := benchRoundTrip(conn, payload, buf, p.timeout); err != nil {
				return zero, fmt.Errorf("warmup: %w", err)
			}
		}
	}
	streamsOpened := p.opens.Load() - opensBefore

	latencies := make([]time.Duration, 0, concurrency*p.bench.iterations)
	var mu sync.Mutex
	errCh := make(chan error, concurrency)
	var wg sync.WaitGroup
	started := time.Now()
	for _, conn := range conns {
		wg.Add(1)
		go func(c net.Conn) {
			defer wg.Done()
			local := make([]time.Duration, 0, p.bench.iterations)
			readBuf := make([]byte, len(payload))
			for i := 0; i < p.bench.iterations; i++ {
				elapsed, err := benchRoundTrip(c, payload, readBuf, p.timeout)
				if err != nil {
					errCh <- err
					return
				}
				local = append(local, elapsed)
			}
			mu.Lock()
			latencies = append(latencies, local...)
			mu.Unlock()
		}(conn)
	}
	wg.Wait()
	elapsed := time.Since(started)
	select {
	case err := <-errCh:
		return zero, err
	default:
	}
	if len(latencies) == 0 {
		return zero, fmt.Errorf("no measurements")
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	toMs := func(d time.Duration) float64 { return float64(d.Microseconds()) / 1000.0 }
	var total time.Duration
	for _, d := range latencies {
		total += d
	}
	result := benchResult{
		PayloadBytes:        size,
		Concurrency:         concurrency,
		IterationsPerStream: p.bench.iterations,
		RoundTrips:          len(latencies),
		StreamsOpened:       streamsOpened,
		DurationMs:          toMs(elapsed),
		LatencyMs: benchLatency{
			P50:  nearestRankMs(latencies, 0.50),
			P95:  nearestRankMs(latencies, 0.95),
			Mean: toMs(total / time.Duration(len(latencies))),
			Max:  toMs(latencies[len(latencies)-1]),
		},
	}
	result.ThroughputBytesPerSec = float64(size*len(latencies)) / elapsed.Seconds()

	// Release this concurrency level's streams before the next measurement.
	for _, conn := range conns {
		if cw, ok := conn.(*net.TCPConn); ok {
			_ = cw.CloseWrite()
		}
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		_, _ = io.Copy(io.Discard, conn)
		_ = conn.Close()
	}
	conns = nil
	return result, nil
}

// nearestRankMs returns the nearest-rank percentile in milliseconds.
func nearestRankMs(sorted []time.Duration, percentile float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	rank := int(math.Ceil(percentile * float64(len(sorted))))
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return float64(sorted[rank-1].Microseconds()) / 1000.0
}

func benchRoundTrip(conn net.Conn, payload, readBuf []byte, timeout time.Duration) (time.Duration, error) {
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return 0, err
	}
	start := time.Now()
	if _, err := conn.Write(payload); err != nil {
		return 0, err
	}
	if _, err := io.ReadFull(conn, readBuf); err != nil {
		return 0, err
	}
	elapsed := time.Since(start)
	if err := conn.SetDeadline(time.Time{}); err != nil {
		return 0, err
	}
	return elapsed, nil
}

func (p *probe) waitNoStreams(timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		p.streamsMu.Lock()
		n := len(p.streams)
		p.streamsMu.Unlock()
		if n == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func randomNonce() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		panic(errors.New("crypto/rand unavailable: " + err.Error()))
	}
	return base64.RawURLEncoding.EncodeToString(buf)
}
