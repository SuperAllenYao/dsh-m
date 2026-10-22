package relay

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"dshm-relay/internal/certs"
	"dshm-relay/internal/config"
	"dshm-relay/internal/wire"
)

func bridgeAddr(env *testEnv, port int) string {
	return net.JoinHostPort(env.cfg.BridgeBind, fmt.Sprintf("%d", port))
}

func TestBridgeEchoRoundTrip(t *testing.T) {
	env := newTestEnv(t, nil)
	target := startEchoServer(t)
	ft, ready := env.tunnelReady(t, "host-bridge-0001", nil)
	runner := runFakeTunnel(t, ft, tunnelBehavior{targetAddr: target})

	small := []byte("hello-through-the-relay\n")
	if err := phoneEcho(bridgeAddr(env, ready.Port), small, 5*time.Second); err != nil {
		t.Fatalf("small echo: %v", err)
	}
	sids := runner.waitSids(t, 1, 2*time.Second)
	if sids[0]%2 == 0 {
		t.Fatalf("sid %d is not odd (server-assigned odd sids)", sids[0])
	}

	payload := make([]byte, 128<<10)
	for i := range payload {
		payload[i] = byte(i*7 + 3)
	}
	if err := phoneEcho(bridgeAddr(env, ready.Port), payload, 5*time.Second); err != nil {
		t.Fatalf("128 KiB echo: %v", err)
	}
	sids = runner.waitSids(t, 2, 2*time.Second)
	if sids[1] <= sids[0] || sids[1]%2 == 0 {
		t.Fatalf("sid sequence = %v, want increasing odd sids", sids)
	}
	if got := runner.openedCount(); got != 2 {
		t.Fatalf("opened frames = %d, want 2", got)
	}
	if got, ok := env.srv.BridgePort("host-bridge-0001"); !ok || got != ready.Port {
		t.Fatalf("bridge port changed to %d", got)
	}
}

// TestBridgeFirstPacketWithoutHalfClose reproduces the real phone path: the TLS
// ClientHello is one packet and the phone then waits for the ServerHello, without
// sending more data or half-closing. The relay must flush the pre-`opened`
// buffer as soon as the tunnel confirms `opened` (regression: it used to wait
// for more phone data or EOF, so the bridge deadlocked).
func TestBridgeFirstPacketWithoutHalfClose(t *testing.T) {
	env := newTestEnv(t, nil)
	target := startEchoServer(t)
	ft, ready := env.tunnelReady(t, "host-firstpkt-01", nil)
	runner := runFakeTunnel(t, ft, tunnelBehavior{targetAddr: target})

	conn, err := net.DialTimeout("tcp", bridgeAddr(env, ready.Port), 2*time.Second)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	defer conn.Close()
	payload := []byte("TLS-ClientHello-like single first packet")
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write first packet: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("first packet was not forwarded (bridge deadlock): %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("first packet echo = %q, want %q", got, payload)
	}
	// Finish normally: half-close, then drain to EOF.
	if cw, ok := conn.(*net.TCPConn); ok {
		if err := cw.CloseWrite(); err != nil {
			t.Fatalf("close write: %v", err)
		}
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadAll(conn); err != nil {
		t.Fatalf("drain after half-close: %v", err)
	}
	if sids := runner.waitSids(t, 1, 2*time.Second); len(sids) != 1 {
		t.Fatalf("open frames = %v, want 1", sids)
	}
}

// TestBridgeTLSHandshakeThroughRelay is the real-world shape: the phone speaks
// TLS end-to-end to the Mac through the relay's byte-transparent bridge. TLS
// handshakes are multi-flight and the client waits after its ClientHello, which
// exercises exactly the pre-`opened` flush path.
func TestBridgeTLSHandshakeThroughRelay(t *testing.T) {
	env := newTestEnv(t, nil)
	mat, err := certs.Generate("127.0.0.1", time.Hour)
	if err != nil {
		t.Fatalf("generate Mac-like cert: %v", err)
	}
	pair, err := tls.X509KeyPair(mat.CertPEM, mat.KeyPEM)
	if err != nil {
		t.Fatalf("load key pair: %v", err)
	}
	tlsLn, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{pair},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"},
	})
	if err != nil {
		t.Fatalf("tls listen: %v", err)
	}
	t.Cleanup(func() { _ = tlsLn.Close() })
	go func() {
		for {
			conn, err := tlsLn.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				line, err := bufio.NewReader(c).ReadString('\n')
				if err != nil {
					return
				}
				_, _ = c.Write([]byte("pong:" + line))
			}(conn)
		}
	}()

	ft, ready := env.tunnelReady(t, "host-tlsthru-01", nil)
	runFakeTunnel(t, ft, tunnelBehavior{targetAddr: tlsLn.Addr().String()})

	raw, err := net.DialTimeout("tcp", bridgeAddr(env, ready.Port), 2*time.Second)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	defer raw.Close()
	phone := tls.Client(raw, &tls.Config{
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: certs.VerifyPin(mat.Pin),
		ServerName:            "127.0.0.1",
		NextProtos:            []string{"http/1.1"},
		MinVersion:            tls.VersionTLS12,
	})
	_ = phone.SetDeadline(time.Now().Add(5 * time.Second))
	if err := phone.Handshake(); err != nil {
		t.Fatalf("end-to-end TLS handshake through relay: %v", err)
	}
	if _, err := phone.Write([]byte("ping\n")); err != nil {
		t.Fatalf("write over TLS: %v", err)
	}
	reply, err := bufio.NewReader(phone).ReadString('\n')
	if err != nil {
		t.Fatalf("read over TLS: %v", err)
	}
	if reply != "pong:ping\n" {
		t.Fatalf("reply = %q", reply)
	}
}

func TestOpenFailedClosesPhone(t *testing.T) {
	env := newTestEnv(t, nil)
	ft, ready := env.tunnelReady(t, "host-openfail-01", nil)
	runFakeTunnel(t, ft, tunnelBehavior{failOpen: true})
	expectPhoneClosed(t, bridgeAddr(env, ready.Port), 3*time.Second)
}

func TestTunnelResetClosesPhone(t *testing.T) {
	env := newTestEnv(t, nil)
	ft, ready := env.tunnelReady(t, "host-rst-000001", nil)
	runFakeTunnel(t, ft, tunnelBehavior{rstOnOpen: true})
	expectPhoneClosed(t, bridgeAddr(env, ready.Port), 3*time.Second)
}

func TestOpenTimeoutSendsRST(t *testing.T) {
	env := newTestEnv(t, nil)
	env.srv.openTimeoutOverride = 250 * time.Millisecond
	ft, ready := env.tunnelReady(t, "host-opentimeout", nil)
	runner := runFakeTunnel(t, ft, tunnelBehavior{ignoreOpen: true})

	start := time.Now()
	expectPhoneClosed(t, bridgeAddr(env, ready.Port), 3*time.Second)
	if elapsed := time.Since(start); elapsed < 200*time.Millisecond {
		t.Fatalf("phone closed after %s, before the open timeout", elapsed)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, code := range runner.rstSnapshot() {
			if code == wire.RstTimeout {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("tunnel did not receive RST(timeout); got %v", runner.rstSnapshot())
}

func TestMaxStreamsPerHost(t *testing.T) {
	env := newTestEnv(t, func(c *config.Config) {
		c.MaxStreamsPerHost = 1
	})
	ft, ready := env.tunnelReady(t, "host-maxstream-1", nil)
	runner := runFakeTunnel(t, ft, tunnelBehavior{ignoreOpen: true})

	first, err := net.DialTimeout("tcp", bridgeAddr(env, ready.Port), 2*time.Second)
	if err != nil {
		t.Fatalf("dial first phone conn: %v", err)
	}
	defer first.Close()
	runner.waitSids(t, 1, 2*time.Second)

	// The second concurrent stream must be rejected immediately (no open frame).
	expectPhoneClosed(t, bridgeAddr(env, ready.Port), 2*time.Second)
	time.Sleep(200 * time.Millisecond)
	if sids := runner.sidSnapshot(); len(sids) != 1 {
		t.Fatalf("open frames = %v, want only the first stream", sids)
	}
	data, err := os.ReadFile(env.cfg.AuditFile)
	if err != nil {
		t.Fatalf("read audit: %v", err)
	}
	if !strings.Contains(string(data), `"reason":"max-streams"`) {
		t.Fatalf("audit has no max-streams rejection:\n%s", data)
	}
}

func TestBridgeAcceptRateLimit(t *testing.T) {
	env := newTestEnv(t, func(c *config.Config) {
		c.BridgeAcceptRatePerSec = 1
	})
	ft, ready := env.tunnelReady(t, "host-bridgerate", nil)
	runner := runFakeTunnel(t, ft, tunnelBehavior{ignoreOpen: true})

	first, err := net.DialTimeout("tcp", bridgeAddr(env, ready.Port), 2*time.Second)
	if err != nil {
		t.Fatalf("dial first phone conn: %v", err)
	}
	defer first.Close()
	runner.waitSids(t, 1, 2*time.Second)

	expectPhoneClosed(t, bridgeAddr(env, ready.Port), 2*time.Second)
	time.Sleep(200 * time.Millisecond)
	if sids := runner.sidSnapshot(); len(sids) != 1 {
		t.Fatalf("open frames = %v, want only the first stream", sids)
	}
	data, err := os.ReadFile(env.cfg.AuditFile)
	if err != nil {
		t.Fatalf("read audit: %v", err)
	}
	if !strings.Contains(string(data), `"reason":"bridge-rate-limited"`) {
		t.Fatalf("audit has no bridge-rate-limited rejection:\n%s", data)
	}
}

func TestTunnelDisconnectClosesPhone(t *testing.T) {
	env := newTestEnv(t, nil)
	target := startEchoServer(t)
	ft, ready := env.tunnelReady(t, "host-tunneldrop", nil)
	runFakeTunnel(t, ft, tunnelBehavior{targetAddr: target})

	phone, err := net.DialTimeout("tcp", bridgeAddr(env, ready.Port), 2*time.Second)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	defer phone.Close()
	_ = phone.SetWriteDeadline(time.Now().Add(2 * time.Second))
	if _, err := phone.Write([]byte("ping")); err != nil {
		t.Fatalf("phone write: %v", err)
	}
	time.Sleep(100 * time.Millisecond)

	// Drop the tunnel: the relay must close the phone connection.
	_ = ft.conn.Close()
	_ = phone.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, 16)
	for {
		n, err := phone.Read(buf)
		if err != nil {
			break
		}
		if n > 0 {
			continue
		}
	}
	waitHostCount(t, env, 0, 2*time.Second)
}
