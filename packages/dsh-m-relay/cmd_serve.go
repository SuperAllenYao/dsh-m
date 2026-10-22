package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"dshm-relay/internal/config"
	"dshm-relay/internal/relay"
)

func runServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	configPath := fs.String("config", "relay.yaml", "path to relay.yaml")
	listenOverride := fs.String("listen", "", "override the control listen address from relay.yaml")
	addrFile := fs.String("addr-file", "", "write the actual bound address JSON here after start (tests/dev)")
	logLevel := fs.String("log-level", "info", "log level: debug|info|warn|error")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	level, err := parseLogLevel(*logLevel)
	if err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
		return 2
	}
	cfg, warnings, err := config.ParseFile(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
		return 1
	}
	for _, warning := range warnings {
		fmt.Fprintf(os.Stderr, "serve: config warning: %s\n", warning)
	}
	if *listenOverride != "" {
		cfg.Listen = *listenOverride
		if err := cfg.Validate(); err != nil {
			fmt.Fprintf(os.Stderr, "serve: %v\n", err)
			return 2
		}
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	srv, err := relay.New(cfg, relay.Options{Logger: logger})
	if err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
		return 1
	}
	if err := srv.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
		return 1
	}
	if *addrFile != "" {
		info := struct {
			Control       string `json:"control"`
			ControlOrigin string `json:"controlOrigin"`
			BridgePorts   string `json:"bridgePorts"`
			BridgeBind    string `json:"bridgeBind"`
			PublicHost    string `json:"publicHost"`
		}{
			Control:       srv.Addr().String(),
			ControlOrigin: srv.ControlOrigin(),
			BridgePorts:   cfg.BridgePorts.String(),
			BridgeBind:    cfg.BridgeBind,
			PublicHost:    cfg.PublicHost,
		}
		line, _ := json.Marshal(info)
		if err := os.WriteFile(*addrFile, append(line, '\n'), 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "serve: write --addr-file: %v\n", err)
			_ = srv.Shutdown(context.Background())
			return 1
		}
	}
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	sig := <-sigCh
	logger.Info("shutdown signal received", "signal", sig.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown", "err", err)
		return 1
	}
	return 0
}

func parseLogLevel(s string) (slog.Level, error) {
	switch s {
	case "debug":
		return slog.LevelDebug, nil
	case "info", "":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return slog.LevelInfo, fmt.Errorf("invalid log level %q", s)
	}
}
