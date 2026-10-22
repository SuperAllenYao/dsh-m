package main

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"dshm-relay/internal/certs"
	"dshm-relay/internal/config"
	"dshm-relay/internal/relay"
	"dshm-relay/internal/state"
)

type doctorCheck struct {
	name   string
	ok     bool
	detail string
}

func runDoctor(args []string) int {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	configPath := fs.String("config", "relay.yaml", "path to relay.yaml")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	fmt.Printf("dshm-relay doctor %s — %s\n", relay.Version, *configPath)
	var checks []doctorCheck
	add := func(name string, err error, okDetail string) bool {
		if err != nil {
			checks = append(checks, doctorCheck{name: name, ok: false, detail: err.Error()})
			return false
		}
		checks = append(checks, doctorCheck{name: name, ok: true, detail: okDetail})
		return true
	}

	cfg, warnings, err := config.ParseFile(*configPath)
	if err != nil {
		add("config", err, "")
		return finishDoctor(checks)
	}
	add("config", nil, fmt.Sprintf("parsed %s (%d warnings)", *configPath, len(warnings)))
	for _, warning := range warnings {
		fmt.Printf("  [warn] %s\n", warning)
	}
	add("publicHost", config.ValidatePublicHost(cfg.PublicHost), cfg.PublicHost)

	pair, leaf, err := certs.Load(cfg.CertFile, cfg.KeyFile)
	if add("tls", err, fmt.Sprintf("cert/key loaded, SAN: %s", strings.Join(certs.Sites(leaf), ", "))) {
		_ = pair
		add("tls pin", nil, fmt.Sprintf("%s (fingerprint %s)", certs.Pin(leaf.Raw), certs.Fingerprint256(leaf.Raw)))
		add("tls SAN", func() error {
			if !certs.CoversHost(leaf, cfg.PublicHost) {
				return fmt.Errorf("certificate SAN %v does not cover publicHost %q (regenerate with `init --public-host`)", certs.Sites(leaf), cfg.PublicHost)
			}
			return nil
		}(), "covers publicHost")
		remaining := time.Until(leaf.NotAfter)
		expiryDetail := fmt.Sprintf("expires %s (in %d days)", leaf.NotAfter.Format("2006-01-02"), int(remaining.Hours()/24))
		if remaining < 30*24*time.Hour {
			add("tls validity", fmt.Errorf("certificate expires soon: %s", expiryDetail), "")
		} else {
			add("tls validity", nil, expiryDetail)
		}
	}

	secretData, err := os.ReadFile(cfg.SecretFile)
	secretDetail := "not printed"
	if err == nil {
		if n := len(strings.TrimSpace(string(secretData))); n < 16 {
			err = fmt.Errorf("secret is too short (%d chars, min 16)", n)
		} else {
			secretDetail = fmt.Sprintf("%d chars (%s)", n, secretDetail)
		}
	}
	add("secret", err, secretDetail)

	add("state file", state.CheckFile(cfg.StateFile), stateDetail(cfg.StateFile))
	add("state dir writable", writeProbe(filepath.Dir(cfg.StateFile)), filepath.Dir(cfg.StateFile))
	add("audit dir writable", writeProbe(filepath.Dir(cfg.AuditFile)), filepath.Dir(cfg.AuditFile))

	add("control listen", bindProbe(cfg.Listen), fmt.Sprintf("%s bindable", cfg.Listen))
	bridgeAddr := net.JoinHostPort(cfg.BridgeBind, fmt.Sprintf("%d", cfg.BridgePorts.Start))
	add("bridge port", bindProbe(bridgeAddr), fmt.Sprintf("%s bindable (pool %s)", bridgeAddr, cfg.BridgePorts))

	return finishDoctor(checks)
}

func finishDoctor(checks []doctorCheck) int {
	failed := 0
	for _, c := range checks {
		status := "[ok]  "
		if !c.ok {
			status = "[fail]"
			failed++
		}
		fmt.Printf("  %s %s: %s\n", status, c.name, c.detail)
	}
	if failed > 0 {
		fmt.Printf("doctor: FAILED (%d of %d checks failed)\n", failed, len(checks))
		return 1
	}
	fmt.Printf("doctor: OK (%d/%d checks)\n", len(checks), len(checks))
	return 0
}

func stateDetail(path string) string {
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return path + " (not created yet; serve will create it)"
		}
		return path
	}
	return path + " (valid)"
}

func writeProbe(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".doctor-*")
	if err != nil {
		return err
	}
	name := f.Name()
	_ = f.Close()
	return os.Remove(name)
}

func bindProbe(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("cannot bind (in use, privileged or wrong address): %w", err)
	}
	return ln.Close()
}
