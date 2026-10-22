package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaultRoundTrip(t *testing.T) {
	cfg := Default()
	cfg.PublicHost = "203.0.113.10"
	data := Marshal(cfg)
	got, warnings, err := Parse(data, "/etc/dshm-relay")
	if err != nil {
		t.Fatalf("Parse(Marshal(Default())): %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("unexpected warnings: %v", warnings)
	}
	if got.Listen != cfg.Listen || got.PublicHost != cfg.PublicHost ||
		got.BridgePorts != cfg.BridgePorts || got.BridgeBind != cfg.BridgeBind ||
		got.StateFile != filepath.Join("/etc/dshm-relay", "state.json") ||
		got.SecretFile != filepath.Join("/etc/dshm-relay", "relay.secret") ||
		got.CertFile != filepath.Join("/etc/dshm-relay", "tls/cert.pem") ||
		got.AuditFile != filepath.Join("/etc/dshm-relay", "audit.jsonl") {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	if got.MaxStreamsPerHost != 32 || got.LookupRateLimitPerMin != 20 ||
		got.BridgeAcceptRatePerSec != 30 || got.HeartbeatSec != 15 || got.OpenTimeoutSec != 10 {
		t.Fatalf("numeric defaults mismatch: %+v", got)
	}
}

func TestParseFullConfig(t *testing.T) {
	raw := `# comment
listen: "127.0.0.1:8443"   # inline comment
publicHost: "relay.example.com"
bridgePorts:
  - 31000
  - 31009
bridgeBind: '127.0.0.1'
stateFile: "data/state.json"
secretFile: "data/relay.secret"
certFile: "data/tls/cert.pem"
keyFile: "data/tls/key.pem"
auditFile: "data/audit.jsonl"
maxStreamsPerHost: 8
lookupRateLimitPerMin: 5
bridgeAcceptRatePerSec: 10
heartbeatSec: 5
openTimeoutSec: 3
`
	cfg, warnings, err := Parse([]byte(raw), "/srv/relay")
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("warnings: %v", warnings)
	}
	if cfg.Listen != "127.0.0.1:8443" || cfg.PublicHost != "relay.example.com" ||
		cfg.BridgePorts != (PortRange{31000, 31009}) || cfg.BridgeBind != "127.0.0.1" {
		t.Fatalf("core fields: %+v", cfg)
	}
	if cfg.StateFile != "/srv/relay/data/state.json" || cfg.AuditFile != "/srv/relay/data/audit.jsonl" {
		t.Fatalf("path resolution: %+v", cfg)
	}
	if cfg.MaxStreamsPerHost != 8 || cfg.LookupRateLimitPerMin != 5 ||
		cfg.BridgeAcceptRatePerSec != 10 || cfg.HeartbeatSec != 5 || cfg.OpenTimeoutSec != 3 {
		t.Fatalf("numbers: %+v", cfg)
	}
}

func TestParseInlineBridgePorts(t *testing.T) {
	cfg, _, err := Parse([]byte("publicHost: 1.2.3.4\nbridgePorts: [41000, 41001]\n"), "")
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if cfg.BridgePorts != (PortRange{41000, 41001}) {
		t.Fatalf("bridgePorts = %v", cfg.BridgePorts)
	}
}

func TestParseUnknownKeyWarns(t *testing.T) {
	_, warnings, err := Parse([]byte("publicHost: 1.2.3.4\nfutureKnob: true\n"), "")
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], "futureKnob") {
		t.Fatalf("warnings = %v", warnings)
	}
}

func TestParseErrors(t *testing.T) {
	cases := map[string]string{
		"missing publicHost":   "listen: \"0.0.0.0:443\"\n",
		"scheme in publicHost": "publicHost: \"https://a.com\"\n",
		"port in publicHost":   "publicHost: \"a.com:443\"\n",
		"bad listen":           "publicHost: a.com\nlisten: \"nope\"\n",
		"bad bridge port":      "publicHost: a.com\nbridgePorts: [0, 10]\n",
		"reversed ports":       "publicHost: a.com\nbridgePorts: [10, 1]\n",
		"too many ports":       "publicHost: a.com\nbridgePorts: [1, 2, 3]\n",
		"indented line":        "publicHost: a.com\n  listen: x\n",
		"bad integer":          "publicHost: a.com\nmaxStreamsPerHost: abc\n",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := Parse([]byte(raw), ""); err == nil {
				t.Fatalf("Parse accepted invalid config")
			}
		})
	}
}

func TestValidateRejectsBadNumbers(t *testing.T) {
	base := Default()
	base.PublicHost = "1.2.3.4"
	if err := base.Validate(); err != nil {
		t.Fatalf("valid default rejected: %v", err)
	}
	mut := func(f func(*Config)) error {
		c := base
		f(&c)
		return c.Validate()
	}
	if mut(func(c *Config) { c.MaxStreamsPerHost = 0 }) == nil {
		t.Fatal("maxStreamsPerHost=0 accepted")
	}
	if mut(func(c *Config) { c.LookupRateLimitPerMin = 0 }) == nil {
		t.Fatal("lookupRateLimitPerMin=0 accepted")
	}
	if mut(func(c *Config) { c.HeartbeatSec = 0 }) == nil {
		t.Fatal("heartbeatSec=0 accepted")
	}
	if mut(func(c *Config) { c.OpenTimeoutSec = 0 }) == nil {
		t.Fatal("openTimeoutSec=0 accepted")
	}
	if mut(func(c *Config) { c.BridgeBind = "127.0.0.1:1" }) == nil {
		t.Fatal("bridgeBind with port accepted")
	}
	if mut(func(c *Config) { c.BridgePorts = PortRange{5000, 4000} }) == nil {
		t.Fatal("reversed bridge range accepted")
	}
}

func TestParseFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.yaml")
	cfg := Default()
	cfg.PublicHost = "127.0.0.1"
	cfg.BridgeBind = "127.0.0.1"
	if err := os.WriteFile(path, Marshal(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	got, _, err := ParseFile(path)
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if got.StateFile != filepath.Join(dir, "state.json") {
		t.Fatalf("stateFile = %q", got.StateFile)
	}
	if _, _, err := ParseFile(filepath.Join(dir, "missing.yaml")); err == nil {
		t.Fatal("ParseFile succeeded for missing file")
	}
}
