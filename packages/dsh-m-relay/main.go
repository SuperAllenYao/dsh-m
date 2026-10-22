// Command dshm-relay is the DSH-m transparent relay server (M2a).
//
// Subcommands:
//
// init generate relay.yaml, self-signed TLS material, relay.secret and
// print the Mac plugin tunnel config + App server config
// serve run the relay
// doctor check configuration, certificate, secret, state and ports
// version print the version
//
// The wire contract lives in <internal-doc> §4.
package main

import (
	"fmt"
	"os"

	"dshm-relay/internal/relay"
)

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	var code int
	switch os.Args[1] {
	case "init":
		code = runInit(os.Args[2:])
	case "serve":
		code = runServe(os.Args[2:])
	case "doctor":
		code = runDoctor(os.Args[2:])
	case "version", "-v", "--version":
		fmt.Printf("dshm-relay %s (protocol dshm-relay/1)\n", relay.Version)
		code = 0
	case "help", "-h", "--help":
		usage(os.Stdout)
		code = 0
	default:
		fmt.Fprintf(os.Stderr, "dshm-relay: unknown command %q\n\n", os.Args[1])
		usage(os.Stderr)
		code = 2
	}
	os.Exit(code)
}

func usage(w *os.File) {
	fmt.Fprint(w, `dshm-relay — DSH-m transparent relay (M2a)

Usage:
  dshm-relay init   --public-host <ip-or-domain> [--control-listen <addr>] [--bridge-ports <[host:]start-end>] [--out <dir>] [--force] [--print-json]
  dshm-relay serve  --config <relay.yaml> [--listen <addr>] [--addr-file <path>] [--log-level debug|info|warn|error]
  dshm-relay doctor --config <relay.yaml>
  dshm-relay version

The relay is a stdlib-only single binary: TLS control channel (ALPN
dshm-relay/1) + App lookup (/v1/lookup, /healthz) on one port, and one bridge
TCP port per Mac (opaque byte forwarding). Phones pin the Mac certificate, so
the relay never sees plaintext.
`)
}
