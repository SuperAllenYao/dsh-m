package relay

import (
	"bufio"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"dshm-relay/internal/certs"
	"dshm-relay/internal/config"
)

func testLeafPin() string {
	sum := sha256.Sum256([]byte("test-mac-leaf-certificate"))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func testLeafFingerprint() string {
	sum := sha256.Sum256([]byte("test-mac-leaf-certificate"))
	const hexDigits = "0123456789ABCDEF"
	parts := make([]string, 0, len(sum))
	for _, b := range sum {
		parts = append(parts, string([]byte{hexDigits[b>>4], hexDigits[b&0x0f]}))
	}
	return strings.Join(parts, ":")
}

// publishCode sends a `code` control message and waits for the relay read loop
// to process it.
func publishCode(t *testing.T, ft *fakeTunnel, code string, exp int64, hostName string) {
	t.Helper()
	if err := ft.sendJSON(map[string]any{
		"t":                  "code",
		"code":               code,
		"exp":                exp,
		"leafPin":            testLeafPin(),
		"leafFingerprint256": testLeafFingerprint(),
		"hostName":           hostName,
	}); err != nil {
		t.Fatalf("publish code: %v", err)
	}
	time.Sleep(80 * time.Millisecond)
}

func doLookup(t *testing.T, client *http.Client, controlAddr, code string) (int, map[string]any) {
	t.Helper()
	resp, err := client.Post("https://"+controlAddr+"/v1/lookup", "application/json",
		strings.NewReader(`{"code":"`+code+`"}`))
	if err != nil {
		t.Fatalf("POST /v1/lookup: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		t.Fatalf("read lookup response: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("lookup response is not JSON: %v (%s)", err, body)
	}
	return resp.StatusCode, decoded
}

func TestLookupHitMissExpiredAndClear(t *testing.T) {
	env := newTestEnv(t, nil)
	ft, ready := env.tunnelReady(t, "host-lookup-0001", nil)
	client := env.httpClient(t)

	exp := time.Now().Add(90 * time.Second).Unix()
	publishCode(t, ft, "12345678", exp, "Mac Lookup")

	status, entry := doLookup(t, client, env.controlAddr(), "12345678")
	if status != http.StatusOK {
		t.Fatalf("lookup status = %d, want 200 (%v)", status, entry)
	}
	if entry["ok"] != true || entry["hostId"] != "host-lookup-0001" ||
		entry["hostName"] != "Mac Lookup" || entry["origin"] != ready.Origin ||
		entry["leafPin"] != testLeafPin() || entry["leafFingerprint256"] != testLeafFingerprint() {
		t.Fatalf("lookup response mismatch: %v", entry)
	}
	if expFloat, ok := entry["exp"].(float64); !ok || int64(expFloat) != exp {
		t.Fatalf("exp = %v, want %d", entry["exp"], exp)
	}
	if _, leaked := entry["code"]; leaked {
		t.Fatal("lookup response must not contain the pairing code")
	}

	status, entry = doLookup(t, client, env.controlAddr(), "00000000")
	if status != http.StatusNotFound || entry["error"] != "code/not-found" {
		t.Fatalf("unknown code = %d %v", status, entry)
	}

	// Expired code: still reported as 410 code/expired (not 404) so the App can
	// show "expired, please refresh".
	expiring := time.Now().Add(1 * time.Second).Unix()
	publishCode(t, ft, "87654321", expiring, "Mac Lookup")
	time.Sleep(1300 * time.Millisecond)
	status, entry = doLookup(t, client, env.controlAddr(), "87654321")
	if status != http.StatusGone || entry["error"] != "code/expired" {
		t.Fatalf("expired code = %d %v", status, entry)
	}

	// code_clear removes the current code.
	publishCode(t, ft, "11223344", time.Now().Add(60*time.Second).Unix(), "Mac Lookup")
	if status, _ := doLookup(t, client, env.controlAddr(), "11223344"); status != http.StatusOK {
		t.Fatalf("cleared-code precondition failed: status %d", status)
	}
	if err := ft.sendJSON(map[string]any{"t": "code_clear"}); err != nil {
		t.Fatalf("send code_clear: %v", err)
	}
	time.Sleep(80 * time.Millisecond)
	if status, entry := doLookup(t, client, env.controlAddr(), "11223344"); status != http.StatusNotFound {
		t.Fatalf("after code_clear status = %d (%v), want 404", status, entry)
	}

	// Disconnecting the tunnel drops its code.
	publishCode(t, ft, "55667788", time.Now().Add(60*time.Second).Unix(), "Mac Lookup")
	_ = ft.conn.Close()
	waitHostCount(t, env, 0, 2*time.Second)
	if status, entry := doLookup(t, client, env.controlAddr(), "55667788"); status != http.StatusNotFound {
		t.Fatalf("after disconnect status = %d (%v), want 404", status, entry)
	}
}

func TestLookupRateLimited(t *testing.T) {
	env := newTestEnv(t, func(c *config.Config) {
		c.LookupRateLimitPerMin = 2
	})
	client := env.httpClient(t)
	for i := 0; i < 2; i++ {
		if status, _ := doLookup(t, client, env.controlAddr(), "00000000"); status != http.StatusNotFound {
			t.Fatalf("request %d status = %d, want 404", i, status)
		}
	}
	status, entry := doLookup(t, client, env.controlAddr(), "00000000")
	if status != http.StatusTooManyRequests || entry["error"] != "rate-limited" {
		t.Fatalf("rate-limited = %d %v, want 429 rate-limited", status, entry)
	}
}

func TestLookupWithoutALPN(t *testing.T) {
	env := newTestEnv(t, nil)
	raw, err := net.DialTimeout("tcp", env.controlAddr(), 3*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer raw.Close()
	// No NextProtos => client sends no ALPN; the relay must serve HTTP/1.1.
	conn := tls.Client(raw, &tls.Config{
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: certs.VerifyPin(env.pin),
		MinVersion:            tls.VersionTLS12,
	})
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if err := conn.Handshake(); err != nil {
		t.Fatalf("handshake: %v", err)
	}
	body := `{"code":"00000000"}`
	req := "POST /v1/lookup HTTP/1.1\r\nHost: " + env.controlAddr() +
		"\r\nContent-Type: application/json\r\nContent-Length: " + fmt.Sprint(len(body)) +
		"\r\nConnection: close\r\n\r\n" + body
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatalf("write request: %v", err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", resp.StatusCode)
	}
}

func TestAuditHasNoSecret(t *testing.T) {
	env := newTestEnv(t, nil)
	ft, _ := env.tunnelReady(t, "host-audit-0001", nil)
	client := env.httpClient(t)
	publishCode(t, ft, "12345678", time.Now().Add(60*time.Second).Unix(), "Mac Audit")
	okStatus, _ := doLookup(t, client, env.controlAddr(), "12345678")

	// A failed hello must be audited without the secret or the HMAC.
	bad := helloMessage(env.secret, "host-audit-fail", time.Now().UnixMilli(), testNonce(t), nil)
	bad["auth"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	env.expectHelloError(t, "host-audit-fail", bad)

	if okStatus != http.StatusOK {
		t.Fatalf("lookup precondition failed: %d", okStatus)
	}
	data, err := os.ReadFile(env.cfg.AuditFile)
	if err != nil {
		t.Fatalf("read audit: %v", err)
	}
	text := string(data)
	if strings.Contains(text, string(env.secret)) {
		t.Fatal("audit log contains the relay secret")
	}
	if strings.Contains(text, bad["auth"].(string)) {
		t.Fatal("audit log contains a hello HMAC")
	}
	for _, want := range []string{"host.connect", "host.ready", "auth.fail", "lookup.hit", "code.publish", "stream."} {
		if want == "stream." {
			continue
		}
		if !strings.Contains(text, `"event":"`+want+`"`) {
			t.Fatalf("audit log missing event %q:\n%s", want, text)
		}
	}
}
