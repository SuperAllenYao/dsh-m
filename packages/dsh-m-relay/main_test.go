package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"dshm-relay/internal/config"
)

func TestParseBridgePortsFlag(t *testing.T) {
	cases := []struct {
		arg      string
		wantBind string
		want     config.PortRange
		wantErr  bool
	}{
		{"30000-30049", "0.0.0.0", config.PortRange{Start: 30000, End: 30049}, false},
		{"127.0.0.1:30000-30009", "127.0.0.1", config.PortRange{Start: 30000, End: 30009}, false},
		{"[::1]:40000-40001", "::1", config.PortRange{Start: 40000, End: 40001}, false},
		{"30000", "", config.PortRange{}, true},
		{"10-1", "", config.PortRange{}, true},
		{"0-10", "", config.PortRange{}, true},
		{"bad", "", config.PortRange{}, true},
	}
	for _, tc := range cases {
		t.Run(tc.arg, func(t *testing.T) {
			bind, rng, err := parseBridgePortsFlag(tc.arg)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("parseBridgePortsFlag(%q) accepted invalid input", tc.arg)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseBridgePortsFlag(%q): %v", tc.arg, err)
			}
			if bind != tc.wantBind || rng != tc.want {
				t.Fatalf("got (%q, %v), want (%q, %v)", bind, rng, tc.wantBind, tc.want)
			}
		})
	}
}

func TestParseListenFlag(t *testing.T) {
	host, port, err := parseListenFlag("127.0.0.1:0")
	if err != nil || host != "127.0.0.1" || port != 0 {
		t.Fatalf("parseListenFlag = (%q, %d, %v)", host, port, err)
	}
	if _, _, err := parseListenFlag("nope"); err == nil {
		t.Fatal("parseListenFlag accepted invalid input")
	}
	if _, _, err := parseListenFlag("127.0.0.1:99999"); err == nil {
		t.Fatal("parseListenFlag accepted an out-of-range port")
	}
}

func TestInitPrintJSONContract(t *testing.T) {
	dir := t.TempDir()
	outDir := filepath.Join(dir, "relay")
	poolStart := freePortRangeForTest(t, 10)
	args := []string{
		"--public-host", "127.0.0.1",
		"--control-listen", "127.0.0.1:0",
		"--bridge-ports", fmt.Sprintf("127.0.0.1:%d-%d", poolStart, poolStart+9),
		"--out", outDir,
		"--print-json",
	}
	var code int
	stdout := captureStdout(t, func() {
		code = runInit(args)
	})
	if code != 0 {
		t.Fatalf("runInit exit code = %d", code)
	}
	var parsed map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &parsed); err != nil {
		t.Fatalf("init --print-json output is not one JSON object: %v\n%s", err, stdout)
	}
	for _, key := range []string{"controlOrigin", "pin", "secret", "publicHost", "bridgePorts",
		"appConfig", "configFile", "certFile", "keyFile", "secretFile", "stateFile", "auditFile", "tunnel"} {
		if _, ok := parsed[key]; !ok {
			t.Fatalf("init JSON missing key %q: %s", key, stdout)
		}
	}
	if parsed["publicHost"] != "127.0.0.1" {
		t.Fatalf("publicHost = %v", parsed["publicHost"])
	}
	if parsed["bridgePorts"] != fmt.Sprintf("%d-%d", poolStart, poolStart+9) {
		t.Fatalf("bridgePorts = %v", parsed["bridgePorts"])
	}
	controlOrigin, _ := parsed["controlOrigin"].(string)
	u, err := url.Parse(controlOrigin)
	if err != nil || u.Scheme != "https" || u.Port() == "" || u.Port() == "0" || u.Hostname() != "127.0.0.1" {
		t.Fatalf("controlOrigin = %q (%v)", controlOrigin, err)
	}
	pin, _ := parsed["pin"].(string)
	if len(pin) != 43 {
		t.Fatalf("pin length = %d, want 43", len(pin))
	}
	secret, _ := parsed["secret"].(string)
	if len(secret) < 16 {
		t.Fatalf("secret length = %d", len(secret))
	}
	appConfig, _ := parsed["appConfig"].(string)
	if !strings.HasPrefix(appConfig, "dshm-relay://127.0.0.1:") ||
		!strings.Contains(appConfig, "?pin="+pin) || !strings.HasSuffix(appConfig, "&v=1") {
		t.Fatalf("appConfig = %q", appConfig)
	}
	tunnel, ok := parsed["tunnel"].(map[string]any)
	if !ok {
		t.Fatalf("tunnel config = %v", parsed["tunnel"])
	}
	for _, key := range []string{"enabled", "controlOrigin", "pin", "secret"} {
		if _, ok := tunnel[key]; !ok {
			t.Fatalf("tunnel config missing key %q: %v", key, tunnel)
		}
	}
	if tunnel["controlOrigin"] != controlOrigin || tunnel["pin"] != pin || tunnel["secret"] != secret {
		t.Fatalf("tunnel config does not match summary: %v", tunnel)
	}

	// Generated files exist with the expected layout; relay.yaml re-parses.
	configFile, _ := parsed["configFile"].(string)
	for _, path := range []string{configFile,
		parsed["certFile"].(string), parsed["keyFile"].(string), parsed["secretFile"].(string)} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected file %s: %v", path, err)
		}
	}
	secretFileData, err := os.ReadFile(parsed["secretFile"].(string))
	if err != nil || strings.TrimSpace(string(secretFileData)) != secret {
		t.Fatalf("relay.secret content mismatch: %v", err)
	}
	cfg, warnings, err := config.ParseFile(configFile)
	if err != nil {
		t.Fatalf("parse generated relay.yaml: %v (warnings %v)", err, warnings)
	}
	if len(warnings) != 0 {
		t.Fatalf("generated relay.yaml warnings: %v", warnings)
	}
	if cfg.BridgeBind != "127.0.0.1" || cfg.BridgePorts.Start != poolStart ||
		cfg.PublicHost != "127.0.0.1" || cfg.Listen == "0.0.0.0:443" {
		t.Fatalf("generated config = %+v", cfg)
	}

	// doctor passes on the generated layout.
	var doctorCode int
	doctorOut := captureStdout(t, func() {
		doctorCode = runDoctor([]string{"--config", configFile})
	})
	if doctorCode != 0 {
		t.Fatalf("doctor failed:\n%s", doctorOut)
	}
	if !strings.Contains(doctorOut, "doctor: OK") {
		t.Fatalf("doctor output:\n%s", doctorOut)
	}

	// init must refuse to overwrite without --force.
	if again := runInit(args); again != 1 {
		t.Fatalf("second init exit code = %d, want 1", again)
	}
}

func TestInitRejectsBadPublicHost(t *testing.T) {
	var code int
	captureStdout(t, func() {
		code = runInit([]string{"--public-host", "https://example.com", "--out", t.TempDir()})
	})
	if code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
}

// captureStdout redirects os.Stdout while fn runs and returns what was printed.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	defer func() { os.Stdout = old }()
	fn()
	if err := w.Close(); err != nil {
		t.Fatalf("close pipe: %v", err)
	}
	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read captured stdout: %v", err)
	}
	_ = r.Close()
	return string(data)
}

func freePortRangeForTest(t *testing.T, n int) int {
	t.Helper()
	for attempt := 0; attempt < 100; attempt++ {
		start := 20000 + int(time.Now().UnixNano()%20000)
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
