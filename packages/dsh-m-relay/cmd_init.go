package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"dshm-relay/internal/certs"
	"dshm-relay/internal/config"
)

// marshalNoEscape encodes v without HTML escaping so `dshm-relay://...?pin=..&v=1`
// keeps its literal `&` (the App/scripts parse the JSON value, but the raw line
// should also be greppable).
func marshalNoEscape(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// initJSON is the machine-readable output of `init --print-json`. It contains
// the relay secret because the caller explicitly asked for automation output;
// plain `init` prints it only in the one-time terminal summary (design doc
// §4.3 "一律一次性打印，secret 不落日志"). Never pipe it into a log file.
type initJSON struct {
	ControlOrigin string         `json:"controlOrigin"`
	Pin           string         `json:"pin"`
	Secret        string         `json:"secret"`
	PublicHost    string         `json:"publicHost"`
	BridgePorts   string         `json:"bridgePorts"`
	AppConfig     string         `json:"appConfig"`
	ControlListen string         `json:"controlListen"`
	BridgeBind    string         `json:"bridgeBind"`
	ConfigFile    string         `json:"configFile"`
	CertFile      string         `json:"certFile"`
	KeyFile       string         `json:"keyFile"`
	SecretFile    string         `json:"secretFile"`
	StateFile     string         `json:"stateFile"`
	AuditFile     string         `json:"auditFile"`
	Tunnel        map[string]any `json:"tunnel"`
}

var bridgePortsFlagRe = regexp.MustCompile(`^([0-9]+)-([0-9]+)$`)

func runInit(args []string) int {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	publicHost := fs.String("public-host", "", "public IP or domain phones/Macs dial (required)")
	controlListen := fs.String("control-listen", "0.0.0.0:443", "control TLS + lookup HTTP listen address; port 0 picks a free port")
	bridgePorts := fs.String("bridge-ports", "30000-30049", "bridge pool as [bindHost:]start-end, e.g. 127.0.0.1:30000-30009")
	outDir := fs.String("out", ".", "output directory for relay.yaml, TLS material, secret and state")
	force := fs.Bool("force", false, "overwrite existing generated files")
	printJSON := fs.Bool("print-json", false, "print one-line machine-readable JSON to stdout (contains the relay secret)")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if *publicHost == "" {
		fmt.Fprintln(os.Stderr, "init: --public-host is required")
		return 2
	}
	if err := config.ValidatePublicHost(*publicHost); err != nil {
		fmt.Fprintf(os.Stderr, "init: %v\n", err)
		return 2
	}
	bindHost, portRange, err := parseBridgePortsFlag(*bridgePorts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "init: --bridge-ports: %v\n", err)
		return 2
	}
	controlHost, controlPort, err := parseListenFlag(*controlListen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "init: --control-listen: %v\n", err)
		return 2
	}
	if controlPort == 0 {
		probeHost := controlHost
		if probeHost == "" || probeHost == "0.0.0.0" || probeHost == "::" || probeHost == "[::]" {
			probeHost = "127.0.0.1"
		}
		controlPort, err = pickFreePort(probeHost)
		if err != nil {
			fmt.Fprintf(os.Stderr, "init: pick free control port: %v\n", err)
			return 1
		}
		*controlListen = net.JoinHostPort(controlHost, strconv.Itoa(controlPort))
	}
	outAbs, err := filepath.Abs(*outDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "init: resolve --out: %v\n", err)
		return 1
	}
	cfg := config.Default()
	cfg.Listen = *controlListen
	cfg.PublicHost = *publicHost
	cfg.BridgePorts = portRange
	cfg.BridgeBind = bindHost
	cfg.StateFile = filepath.Join(outAbs, "state.json")
	cfg.SecretFile = filepath.Join(outAbs, "relay.secret")
	cfg.CertFile = filepath.Join(outAbs, "tls", "cert.pem")
	cfg.KeyFile = filepath.Join(outAbs, "tls", "key.pem")
	cfg.AuditFile = filepath.Join(outAbs, "audit.jsonl")
	configFile := filepath.Join(outAbs, "relay.yaml")
	if err := cfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "init: invalid configuration: %v\n", err)
		return 2
	}
	if !*force {
		for _, path := range []string{configFile, cfg.CertFile, cfg.KeyFile, cfg.SecretFile} {
			if _, err := os.Stat(path); err == nil {
				fmt.Fprintf(os.Stderr, "init: %s already exists (use --force to overwrite)\n", path)
				return 1
			}
		}
	}
	if err := os.MkdirAll(outAbs, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "init: create %s: %v\n", outAbs, err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(cfg.CertFile), 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "init: create TLS directory: %v\n", err)
		return 1
	}
	mat, err := certs.Generate(*publicHost, certs.DefaultValidity)
	if err != nil {
		fmt.Fprintf(os.Stderr, "init: %v\n", err)
		return 1
	}
	secretBytes := make([]byte, 32)
	if _, err := rand.Read(secretBytes); err != nil {
		fmt.Fprintf(os.Stderr, "init: generate secret: %v\n", err)
		return 1
	}
	secret := base64.RawURLEncoding.EncodeToString(secretBytes)

	writes := []struct {
		path string
		data []byte
		mode os.FileMode
	}{
		{cfg.CertFile, mat.CertPEM, 0o644},
		{cfg.KeyFile, mat.KeyPEM, 0o600},
		{cfg.SecretFile, []byte(secret + "\n"), 0o600},
		{configFile, config.Marshal(cfg), 0o644},
	}
	for _, w := range writes {
		if err := os.WriteFile(w.path, w.data, w.mode); err != nil {
			fmt.Fprintf(os.Stderr, "init: write %s: %v\n", w.path, err)
			return 1
		}
	}
	controlOrigin := "https://" + net.JoinHostPort(*publicHost, strconv.Itoa(controlPort))
	appConfig := "dshm-relay://" + net.JoinHostPort(*publicHost, strconv.Itoa(controlPort)) +
		"?pin=" + mat.Pin + "&v=1"
	tunnelCfg := map[string]any{
		"enabled":       true,
		"controlOrigin": controlOrigin,
		"pin":           mat.Pin,
		"secret":        secret,
	}
	out := initJSON{
		ControlOrigin: controlOrigin,
		Pin:           mat.Pin,
		Secret:        secret,
		PublicHost:    *publicHost,
		BridgePorts:   portRange.String(),
		AppConfig:     appConfig,
		ControlListen: *controlListen,
		BridgeBind:    bindHost,
		ConfigFile:    configFile,
		CertFile:      cfg.CertFile,
		KeyFile:       cfg.KeyFile,
		SecretFile:    cfg.SecretFile,
		StateFile:     cfg.StateFile,
		AuditFile:     cfg.AuditFile,
		Tunnel:        tunnelCfg,
	}
	if *printJSON {
		line, err := marshalNoEscape(out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "init: marshal JSON: %v\n", err)
			return 1
		}
		fmt.Println(string(line))
		return 0
	}
	tunnelJSON, _ := json.MarshalIndent(tunnelCfg, "", "  ")
	fmt.Printf(`dshm-relay init 完成

  配置:        %s
  控制监听:    %s (TLS, ALPN %s；同端口 /v1/lookup 与 /healthz)
  publicHost:  %s（手机/Mac 看到的地址）
  bridge 池:   %s（bind %s）
  证书:        %s
  证书 pin:    %s
  secret:      %s
  state:       %s
  audit:       %s

Mac 插件配置（写入 cordis.patch.yml 的 dsh-m-link 段）:
%s

App 服务器配置（扫码/粘贴；host:port 是控制通道 TLS 地址，不是 bridge 端口）:
%s

下一步:
  dshm-relay doctor --config %s
  dshm-relay serve  --config %s

注意: secret 只打印这一次，勿提交、勿贴日志；公网部署请在云安全组放行 %s/tcp 与 %s/tcp。
`, configFile, *controlListen, "dshm-relay/1", *publicHost, portRange, bindHost,
		cfg.CertFile, mat.Pin, cfg.SecretFile, cfg.StateFile, cfg.AuditFile,
		string(tunnelJSON), appConfig, configFile, configFile,
		strconv.Itoa(controlPort), portRange)
	return 0
}

// parseBridgePortsFlag parses "[bindHost:]start-end" into a bind host and a range.
func parseBridgePortsFlag(arg string) (string, config.PortRange, error) {
	bindHost := "0.0.0.0"
	rangePart := strings.TrimSpace(arg)
	if idx := strings.LastIndex(rangePart, ":"); idx >= 0 {
		candidate := rangePart[idx+1:]
		if bridgePortsFlagRe.MatchString(candidate) {
			hostPart := strings.TrimSpace(rangePart[:idx])
			if hostPart != "" {
				bindHost = strings.TrimPrefix(strings.TrimSuffix(hostPart, "]"), "[")
			}
			rangePart = candidate
		}
	}
	m := bridgePortsFlagRe.FindStringSubmatch(strings.TrimSpace(rangePart))
	if m == nil {
		return "", config.PortRange{}, fmt.Errorf("expected [bindHost:]start-end, got %q", arg)
	}
	start, err := strconv.Atoi(m[1])
	if err != nil {
		return "", config.PortRange{}, err
	}
	end, err := strconv.Atoi(m[2])
	if err != nil {
		return "", config.PortRange{}, err
	}
	if start < 1 || end > 65535 || start > end {
		return "", config.PortRange{}, fmt.Errorf("invalid port range %d-%d", start, end)
	}
	return bindHost, config.PortRange{Start: start, End: end}, nil
}

func parseListenFlag(arg string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(strings.TrimSpace(arg))
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 0 || port > 65535 {
		return "", 0, fmt.Errorf("invalid port %q", portStr)
	}
	return host, port, nil
}

func pickFreePort(host string) (int, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort(host, "0"))
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	addr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		return 0, fmt.Errorf("unexpected listener address %s", ln.Addr())
	}
	return addr.Port, nil
}
