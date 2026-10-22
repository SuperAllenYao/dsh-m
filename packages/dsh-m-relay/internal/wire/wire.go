// Package wire implements the framing layer of the DSH-m relay control
// connection (protocol v0). The byte layout is fixed by
// <internal-doc> §4.4:
//
// +--------+--------+-------------------+
// | u32be | u8 | payload |
// | length | type | (length bytes) |
// +--------+--------+-------------------+
//
// length counts the type byte plus the payload, so it is always >= 1.
//
// Frame types:
//
// 0x01 JSON control message (UTF-8)
// 0x02 DATA: u32be sid + opaque bytes
// 0x03 FIN: u32be sid (half close: this direction sends no more data)
// 0x04 RST: u32be sid + u8 code (abort immediately)
package wire

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// Frame types (protocol v0).
const (
	TypeJSON byte = 0x01
	TypeData byte = 0x02
	TypeFin  byte = 0x03
	TypeRst  byte = 0x04
)

const (
	// MaxFrameLen bounds one frame (length prefix included in the boundary) so a
	// malicious peer cannot make the relay allocate unbounded memory.
	MaxFrameLen = 1 << 20 // 1 MiB
	// MaxPayloadLen is the largest payload a caller may hand to WriteFrame.
	MaxPayloadLen = MaxFrameLen - 1
)

var (
	// ErrFrameTooLarge is returned for a length prefix outside [1, MaxFrameLen].
	ErrFrameTooLarge = errors.New("wire: frame length out of range")
	// ErrPayloadTooLarge is returned when a caller tries to write an oversized payload.
	ErrPayloadTooLarge = errors.New("wire: payload too large")
	// ErrPayloadTooShort is returned when a typed payload is shorter than its header.
	ErrPayloadTooShort = errors.New("wire: payload too short")
)

// ReadFrame reads exactly one frame from r.
//
// A clean EOF before the first header byte is reported as io.EOF; an EOF in the
// middle of a frame is reported as io.ErrUnexpectedEOF (the stream is corrupt).
func ReadFrame(r io.Reader) (typ byte, payload []byte, err error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:4]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:4])
	if n < 1 || n > MaxFrameLen {
		return 0, nil, fmt.Errorf("%w: %d", ErrFrameTooLarge, n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return 0, nil, err
	}
	return buf[0], buf[1:], nil
}

// WriteFrame writes one frame to w. w must be serialized by the caller when it
// is shared between goroutines (the relay holds a per-connection write mutex).
func WriteFrame(w io.Writer, typ byte, payload []byte) error {
	if len(payload) > MaxPayloadLen {
		return fmt.Errorf("%w: %d bytes", ErrPayloadTooLarge, len(payload))
	}
	total := uint32(1 + len(payload))
	if len(payload) <= 8<<10 {
		buf := make([]byte, 5+len(payload))
		binary.BigEndian.PutUint32(buf[:4], total)
		buf[4] = typ
		copy(buf[5:], payload)
		_, err := w.Write(buf)
		return err
	}
	var hdr [5]byte
	binary.BigEndian.PutUint32(hdr[:4], total)
	hdr[4] = typ
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

// SidPayload encodes the 4-byte sid payload used by FIN frames and build it for
// DATA/RST frames.
func SidPayload(sid uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, sid)
	return b
}

// EncodeData builds the DATA payload: u32be sid + data.
func EncodeData(sid uint32, data []byte) []byte {
	b := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(b[:4], sid)
	copy(b[4:], data)
	return b
}

// ParseData splits a DATA payload into sid and bytes. The returned slice aliases
// payload; callers must not reuse payload afterwards.
func ParseData(payload []byte) (uint32, []byte, error) {
	if len(payload) < 4 {
		return 0, nil, ErrPayloadTooShort
	}
	return binary.BigEndian.Uint32(payload[:4]), payload[4:], nil
}

// ParseSID decodes a FIN payload.
func ParseSID(payload []byte) (uint32, error) {
	if len(payload) != 4 {
		return 0, fmt.Errorf("%w: FIN payload must be 4 bytes, got %d", ErrPayloadTooShort, len(payload))
	}
	return binary.BigEndian.Uint32(payload), nil
}

// EncodeRST builds the RST payload: u32be sid + u8 code.
func EncodeRST(sid uint32, code byte) []byte {
	b := make([]byte, 5)
	binary.BigEndian.PutUint32(b[:4], sid)
	b[4] = code
	return b
}

// ParseRST decodes a RST payload.
func ParseRST(payload []byte) (uint32, byte, error) {
	if len(payload) != 5 {
		return 0, 0, fmt.Errorf("%w: RST payload must be 5 bytes, got %d", ErrPayloadTooShort, len(payload))
	}
	return binary.BigEndian.Uint32(payload[:4]), payload[4], nil
}

// RST reason codes. They are informational only: both sides must treat any RST
// as "abort immediately". These values are relay-side extensions of protocol v0
// and are documented in README.md.
const (
	RstLocalIO    byte = 0x01 // local socket read/write failed
	RstTimeout    byte = 0x02 // open/opened handshake timed out
	RstLimit      byte = 0x03 // per-host stream/rate limit hit
	RstTunnelGone byte = 0x04 // tunnel went away, relay closed the phone socket
	RstProtocol   byte = 0x05 // unknown sid or protocol error
)

// RstName returns a stable human-readable name for an RST code.
func RstName(code byte) string {
	switch code {
	case RstLocalIO:
		return "local-io"
	case RstTimeout:
		return "timeout"
	case RstLimit:
		return "limit"
	case RstTunnelGone:
		return "tunnel-gone"
	case RstProtocol:
		return "protocol"
	default:
		return fmt.Sprintf("code-%d", code)
	}
}
