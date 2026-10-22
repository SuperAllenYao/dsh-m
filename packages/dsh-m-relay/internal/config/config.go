// Package config parses and writes relay.yaml. The relay is stdlib-only, so the
// configuration uses a deliberately small YAML subset instead of a third-party
// parser: top-level `key: value` pairs, double-quoted scalars, inline integer
// lists (`[30000, 30049]`) and block integer lists for bridgePorts. Comments
// (`#`) and blank lines are ignored. Unknown keys are reported as warnings and
// ignored so future relay releases can add keys without breaking older ones.
package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// PortRange is the bridge port pool, inclusive on both ends.
type PortRange struct {
	Start int
	End   int
}

// Len is the number of ports in the pool.
func (r PortRange) Len() int { return r.End - r.Start + 1 }

// Contains reports whether port belongs to the pool.
func (r PortRange) Contains(port int) bool { return port >= r.Start && port <= r.End }

// String renders the range as "start-end".
func (r PortRange) String() string { return fmt.Sprintf("%d-%d", r.Start, r.End) }

// Config is the relay configuration (relay.yaml).
type Config struct {
	// Listen is the TLS control + lookup HTTP listener, e.g. "0.0.0.0:443".
	Listen string
	// PublicHost is the address phones/Macs dial, without scheme or port.
	PublicHost string
	// BridgePorts is the bridge TCP port pool.
	BridgePorts PortRange
	// BridgeBind is the local address bridge listeners bind to. Additive to the
	// design doc: "" or "0.0.0.0" for public deployments, "127.0.0.1" for tests.
	BridgeBind string
	// StateFile persists hostId -> bridge port.
	StateFile string
	// SecretFile holds the shared HMAC secret (plain text, trimmed on load).
	SecretFile string
	// CertFile / KeyFile are the relay's self-signed TLS material.
	CertFile string
	KeyFile  string
	// AuditFile is the JSONL audit log.
	AuditFile string
	// MaxStreamsPerHost bounds concurrent bridged streams per Mac.
	MaxStreamsPerHost int
	// LookupRateLimitPerMin bounds /v1/lookup requests per source IP per minute.
	LookupRateLimitPerMin int
	// BridgeAcceptRatePerSec bounds new phone connections per bridge port per second.
	BridgeAcceptRatePerSec int
	// HeartbeatSec is the ping interval advertised in `ready` (and used locally).
	HeartbeatSec int
	// OpenTimeoutSec bounds how long a phone connection may wait for `opened`.
	OpenTimeoutSec int
}

// Default returns the documented defaults.
func Default() Config {
	return Config{
		Listen:                 "0.0.0.0:443",
		PublicHost:             "",
		BridgePorts:            PortRange{Start: 30000, End: 30049},
		BridgeBind:             "0.0.0.0",
		StateFile:              "state.json",
		SecretFile:             "relay.secret",
		CertFile:               "tls/cert.pem",
		KeyFile:                "tls/key.pem",
		AuditFile:              "",
		MaxStreamsPerHost:      32,
		LookupRateLimitPerMin:  20,
		BridgeAcceptRatePerSec: 30,
		HeartbeatSec:           15,
		OpenTimeoutSec:         10,
	}
}

// ParseFile reads and parses path. Relative file paths in the config are
// resolved against the directory containing path.
func ParseFile(path string) (Config, []string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, nil, fmt.Errorf("config: read %s: %w", path, err)
	}
	baseDir := filepath.Dir(path)
	cfg, warnings, err := Parse(data, baseDir)
	if err != nil {
		return Config{}, warnings, fmt.Errorf("config: %s: %w", path, err)
	}
	return cfg, warnings, nil
}

// Parse parses YAML-subset config bytes. baseDir resolves relative paths.
func Parse(data []byte, baseDir string) (Config, []string, error) {
	cfg := Default()
	var warnings []string
	lines := strings.Split(string(data), "\n")
	for i := 0; i < len(lines); i++ {
		raw := strings.TrimRight(lines[i], "\r")
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || line == "---" {
			continue
		}
		if strings.HasPrefix(raw, " ") || strings.HasPrefix(raw, "\t") {
			return cfg, warnings, fmt.Errorf("line %d: unexpected indentation", i+1)
		}
		key, rest, ok := strings.Cut(line, ":")
		if !ok {
			return cfg, warnings, fmt.Errorf("line %d: expected `key: value`", i+1)
		}
		key = strings.TrimSpace(key)
		rest = strings.TrimSpace(rest)
		switch key {
		case "listen":
			cfg.Listen = scalar(rest)
		case "publicHost":
			cfg.PublicHost = scalar(rest)
		case "bridgeBind":
			cfg.BridgeBind = scalar(rest)
		case "bridgePorts":
			if rest == "" {
				nums, consumed, err := parseBlockIntList(lines, i+1)
				if err != nil {
					return cfg, warnings, fmt.Errorf("line %d: bridgePorts: %w", i+1, err)
				}
				if err := cfg.setBridgePorts(nums); err != nil {
					return cfg, warnings, fmt.Errorf("line %d: bridgePorts: %w", i+1, err)
				}
				i += consumed
			} else {
				nums, err := parseIntList(rest)
				if err != nil {
					return cfg, warnings, fmt.Errorf("line %d: bridgePorts: %w", i+1, err)
				}
				if err := cfg.setBridgePorts(nums); err != nil {
					return cfg, warnings, fmt.Errorf("line %d: bridgePorts: %w", i+1, err)
				}
			}
		case "stateFile":
			cfg.StateFile = scalar(rest)
		case "secretFile":
			cfg.SecretFile = scalar(rest)
		case "certFile":
			cfg.CertFile = scalar(rest)
		case "keyFile":
			cfg.KeyFile = scalar(rest)
		case "auditFile":
			cfg.AuditFile = scalar(rest)
		case "maxStreamsPerHost":
			v, err := scalarInt(rest)
			if err != nil {
				return cfg, warnings, fmt.Errorf("line %d: maxStreamsPerHost: %w", i+1, err)
			}
			cfg.MaxStreamsPerHost = v
		case "lookupRateLimitPerMin":
			v, err := scalarInt(rest)
			if err != nil {
				return cfg, warnings, fmt.Errorf("line %d: lookupRateLimitPerMin: %w", i+1, err)
			}
			cfg.LookupRateLimitPerMin = v
		case "bridgeAcceptRatePerSec":
			v, err := scalarInt(rest)
			if err != nil {
				return cfg, warnings, fmt.Errorf("line %d: bridgeAcceptRatePerSec: %w", i+1, err)
			}
			cfg.BridgeAcceptRatePerSec = v
		case "heartbeatSec":
			v, err := scalarInt(rest)
			if err != nil {
				return cfg, warnings, fmt.Errorf("line %d: heartbeatSec: %w", i+1, err)
			}
			cfg.HeartbeatSec = v
		case "openTimeoutSec":
			v, err := scalarInt(rest)
			if err != nil {
				return cfg, warnings, fmt.Errorf("line %d: openTimeoutSec: %w", i+1, err)
			}
			cfg.OpenTimeoutSec = v
		default:
			warnings = append(warnings, fmt.Sprintf("line %d: unknown key %q ignored", i+1, key))
		}
	}
	cfg.resolvePaths(baseDir)
	if cfg.AuditFile == "" {
		cfg.AuditFile = filepath.Join(filepath.Dir(cfg.StateFile), "audit.jsonl")
	}
	if err := cfg.Validate(); err != nil {
		return cfg, warnings, err
	}
	return cfg, warnings, nil
}

func (c *Config) setBridgePorts(nums []int) error {
	if len(nums) != 2 {
		return fmt.Errorf("expected [start, end], got %d values", len(nums))
	}
	if nums[0] < 1 || nums[1] > 65535 {
		return fmt.Errorf("ports must be within 1-65535")
	}
	if nums[0] > nums[1] {
		return fmt.Errorf("start port %d is greater than end port %d", nums[0], nums[1])
	}
	c.BridgePorts = PortRange{Start: nums[0], End: nums[1]}
	return nil
}

func (c *Config) resolvePaths(baseDir string) {
	resolve := func(p string) string {
		if p == "" || filepath.IsAbs(p) || baseDir == "" {
			return p
		}
		return filepath.Clean(filepath.Join(baseDir, p))
	}
	c.StateFile = resolve(c.StateFile)
	c.SecretFile = resolve(c.SecretFile)
	c.CertFile = resolve(c.CertFile)
	c.KeyFile = resolve(c.KeyFile)
	if c.AuditFile != "" {
		c.AuditFile = resolve(c.AuditFile)
	}
}

// Validate checks required fields and numeric bounds.
func (c *Config) Validate() error {
	if c.PublicHost == "" {
		return fmt.Errorf("publicHost is required")
	}
	if err := ValidatePublicHost(c.PublicHost); err != nil {
		return err
	}
	if c.Listen == "" {
		return fmt.Errorf("listen is required")
	}
	host, portStr, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return fmt.Errorf("listen %q: %w", c.Listen, err)
	}
	_ = host
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 0 || port > 65535 {
		return fmt.Errorf("listen %q: invalid port", c.Listen)
	}
	if c.BridgePorts.Start < 1 || c.BridgePorts.End > 65535 || c.BridgePorts.Start > c.BridgePorts.End {
		return fmt.Errorf("bridgePorts %s is invalid", c.BridgePorts)
	}
	if c.BridgePorts.Len() > 4096 {
		return fmt.Errorf("bridgePorts %s: pool too large (max 4096)", c.BridgePorts)
	}
	if c.BridgeBind != "" {
		if strings.ContainsAny(c.BridgeBind, "/ ") || strings.Contains(c.BridgeBind, ":") {
			return fmt.Errorf("bridgeBind %q: must be a bare address without port", c.BridgeBind)
		}
	}
	if c.StateFile == "" || c.SecretFile == "" || c.CertFile == "" || c.KeyFile == "" {
		return fmt.Errorf("stateFile, secretFile, certFile and keyFile are required")
	}
	if c.MaxStreamsPerHost < 1 || c.MaxStreamsPerHost > 4096 {
		return fmt.Errorf("maxStreamsPerHost must be within 1-4096")
	}
	if c.LookupRateLimitPerMin < 1 {
		return fmt.Errorf("lookupRateLimitPerMin must be >= 1")
	}
	if c.BridgeAcceptRatePerSec < 1 {
		return fmt.Errorf("bridgeAcceptRatePerSec must be >= 1")
	}
	if c.HeartbeatSec < 1 || c.HeartbeatSec > 300 {
		return fmt.Errorf("heartbeatSec must be within 1-300")
	}
	if c.OpenTimeoutSec < 1 || c.OpenTimeoutSec > 300 {
		return fmt.Errorf("openTimeoutSec must be within 1-300")
	}
	return nil
}

// ValidatePublicHost rejects values that carry a scheme, port, or path.
func ValidatePublicHost(host string) error {
	if host == "" {
		return fmt.Errorf("publicHost is required")
	}
	if strings.Contains(host, "://") {
		return fmt.Errorf("publicHost %q must not contain a scheme", host)
	}
	if strings.ContainsAny(host, "/ \t") {
		return fmt.Errorf("publicHost %q must be an IP or DNS name", host)
	}
	if ip := net.ParseIP(host); ip != nil {
		return nil
	}
	if strings.Contains(host, ":") {
		return fmt.Errorf("publicHost %q must not contain a port", host)
	}
	return nil
}

// MandatoryHosts is only used by runDoctor via Config.Validate; kept unexported.

// Marshal renders c as relay.yaml with comments. The output round-trips through
// Parse (see config tests).
func Marshal(c Config) []byte {
	var b strings.Builder
	b.WriteString("# dshm-relay configuration (generated by `dshm-relay init`).\n")
	b.WriteString("# 控制通道（TLS + ALPN dshm-relay/1）与 App lookup HTTP 共用 listen 端口。\n")
	fmt.Fprintf(&b, "listen: %q\n", c.Listen)
	b.WriteString("# 手机/Mac 看到的地址：IP 或域名，不含协议/端口。\n")
	fmt.Fprintf(&b, "publicHost: %q\n", c.PublicHost)
	b.WriteString("# bridge 端口池（闭区间 [start, end]）：手机直连这些端口的 TCP 流量透传到 Tunnel。\n")
	fmt.Fprintf(&b, "bridgePorts: [%d, %d]\n", c.BridgePorts.Start, c.BridgePorts.End)
	b.WriteString("# bridge 监听地址：公网部署用 0.0.0.0；本机测试可改 127.0.0.1（附加字段）。\n")
	fmt.Fprintf(&b, "bridgeBind: %q\n", c.BridgeBind)
	fmt.Fprintf(&b, "stateFile: %q\n", c.StateFile)
	fmt.Fprintf(&b, "secretFile: %q\n", c.SecretFile)
	fmt.Fprintf(&b, "certFile: %q\n", c.CertFile)
	fmt.Fprintf(&b, "keyFile: %q\n", c.KeyFile)
	fmt.Fprintf(&b, "auditFile: %q\n", c.AuditFile)
	b.WriteString("# 每台 Mac 的最大并发桥接流数。\n")
	fmt.Fprintf(&b, "maxStreamsPerHost: %d\n", c.MaxStreamsPerHost)
	fmt.Fprintf(&b, "lookupRateLimitPerMin: %d\n", c.LookupRateLimitPerMin)
	fmt.Fprintf(&b, "bridgeAcceptRatePerSec: %d\n", c.BridgeAcceptRatePerSec)
	fmt.Fprintf(&b, "heartbeatSec: %d\n", c.HeartbeatSec)
	fmt.Fprintf(&b, "openTimeoutSec: %d\n", c.OpenTimeoutSec)
	return []byte(b.String())
}

// --- YAML-subset helpers -----------------------------------------------------

// scalar unquotes a scalar and strips a trailing comment for unquoted values.
func scalar(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if v[0] == '"' || v[0] == '\'' {
		quote := v[0]
		end := -1
		for i := 1; i < len(v); i++ {
			if v[i] == '\\' && quote == '"' {
				i++
				continue
			}
			if v[i] == quote {
				end = i
				break
			}
		}
		if end < 0 {
			return v
		}
		if quote == '"' {
			if s, err := strconv.Unquote(v[:end+1]); err == nil {
				return s
			}
		}
		return v[1:end]
	}
	if idx := strings.Index(v, " #"); idx >= 0 {
		v = strings.TrimSpace(v[:idx])
	} else if strings.HasPrefix(v, "#") {
		return ""
	}
	return v
}

func scalarInt(v string) (int, error) {
	s := scalar(v)
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("expected integer, got %q", s)
	}
	return n, nil
}

func parseIntList(v string) ([]int, error) {
	v = strings.TrimSpace(v)
	if !strings.HasPrefix(v, "[") || !strings.HasSuffix(v, "]") {
		return nil, fmt.Errorf("expected [n, m], got %q", v)
	}
	inner := strings.TrimSpace(v[1 : len(v)-1])
	if inner == "" {
		return nil, nil
	}
	parts := strings.Split(inner, ",")
	nums := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, fmt.Errorf("expected integers, got %q", p)
		}
		nums = append(nums, n)
	}
	return nums, nil
}

// parseBlockIntList reads a YAML block list starting at startLine:
//
// bridgePorts:
// - 30000
// - 30049
//
// It returns the numbers and the number of consumed lines (excluding the key line).
func parseBlockIntList(lines []string, startLine int) ([]int, int, error) {
	var nums []int
	consumed := 0
	for i := startLine; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, "-") {
			break
		}
		value := strings.TrimSpace(strings.TrimPrefix(line, "-"))
		n, err := strconv.Atoi(value)
		if err != nil {
			return nil, consumed, fmt.Errorf("expected integer list item, got %q", value)
		}
		nums = append(nums, n)
		consumed = i - startLine + 1
	}
	return nums, consumed, nil
}
