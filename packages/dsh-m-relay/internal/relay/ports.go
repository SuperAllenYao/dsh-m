package relay

import (
	"fmt"
	"net"
	"sort"
	"strconv"
	"sync"

	"dshm-relay/internal/config"
)

// portPool hands out bridge ports from the configured pool and owns the
// hostId -> port reservations. Reservations are kept across tunnel disconnects
// (persisted in state.json) so a Mac keeps its public port; `drain` keeps them
// as well (design doc §4.4).
type portPool struct {
	mu       sync.Mutex
	ports    config.PortRange
	bindHost string
	owner    map[int]string // port -> hostId
}

// newPortPool seeds reservations from persisted state. Ports outside the current
// pool are ignored; when two state entries claim the same port the
// lexicographically smaller hostId keeps it and the other is reassigned on next
// connect.
func newPortPool(ports config.PortRange, bindHost string, persisted map[string]int) *portPool {
	p := &portPool{ports: ports, bindHost: bindHost, owner: make(map[int]string, len(persisted))}
	hostIDs := make([]string, 0, len(persisted))
	for hostID := range persisted {
		hostIDs = append(hostIDs, hostID)
	}
	sort.Strings(hostIDs)
	for _, hostID := range hostIDs {
		port := persisted[hostID]
		if !ports.Contains(port) {
			continue
		}
		if _, taken := p.owner[port]; taken {
			continue
		}
		p.owner[port] = hostID
	}
	return p
}

// listen binds one bridge port.
func (p *portPool) listen(port int) (net.Listener, error) {
	return net.Listen("tcp", net.JoinHostPort(p.bindHost, strconv.Itoa(port)))
}

// acquire reserves a bridge port for hostID and returns an already-bound
// listener. wantPort (optional) must be honoured exactly or the acquisition
// fails; `preferred` is the previously persisted port and is reused when still
// free.
//
// Error-code semantics (M2a review task-9): a port outside the pool or already
// assigned to a *different* host is a long-term conflict → port/unavailable
// (the plugin treats it as permanent). A transient failure to bind (the OS port
// is momentarily taken by another process) or pool exhaustion → server/busy
// (the plugin backs off and retries), because it may clear by itself.
func (p *portPool) acquire(hostID string, wantPort *int, preferred int) (int, net.Listener, *protoError) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if wantPort != nil {
		port := *wantPort
		if !p.ports.Contains(port) {
			return 0, nil, &protoError{Code: codePortUnavailable, Message: fmt.Sprintf("port %d is outside the bridge pool %s", port, p.ports)}
		}
		if owner, taken := p.owner[port]; taken && owner != hostID {
			return 0, nil, &protoError{Code: codePortUnavailable, Message: fmt.Sprintf("port %d is assigned to another host", port)}
		}
		ln, err := p.listen(port)
		if err != nil {
			// Transient: the requested port is in the pool and not owned by another
			// host, but the OS refuses the bind right now (another process holds it,
			// race with a closing listener, ...). The plugin retries on server/busy.
			return 0, nil, &protoError{Code: codeServerBusy, Message: fmt.Sprintf("bridge port %d temporarily unbindable", port)}
		}
		p.owner[port] = hostID
		return port, ln, nil
	}

	if preferred > 0 && p.ports.Contains(preferred) {
		owner, taken := p.owner[preferred]
		if !taken || owner == hostID {
			if ln, err := p.listen(preferred); err == nil {
				p.owner[preferred] = hostID
				return preferred, ln, nil
			}
		}
	}

	candidates := 0
	for port := p.ports.Start; port <= p.ports.End; port++ {
		if owner, taken := p.owner[port]; taken && owner != hostID {
			continue
		}
		candidates++
		ln, err := p.listen(port)
		if err != nil {
			continue
		}
		p.owner[port] = hostID
		return port, ln, nil
	}
	if candidates == 0 {
		// Every port in the pool is reserved by another host: long-term conflict.
		return 0, nil, &protoError{Code: codePortUnavailable, Message: fmt.Sprintf("bridge port pool %s exhausted (all ports assigned to other hosts)", p.ports)}
	}
	// Candidate ports exist but none is bindable right now: transient, so the
	// plugin can back off and retry.
	return 0, nil, &protoError{Code: codeServerBusy, Message: fmt.Sprintf("%d candidate bridge port(s) temporarily unbindable", candidates)}
}

// reservedPorts returns a copy of the port -> hostId reservations (diagnostics).
func (p *portPool) reservedPorts() map[int]string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make(map[int]string, len(p.owner))
	for port, hostID := range p.owner {
		out[port] = hostID
	}
	return out
}
