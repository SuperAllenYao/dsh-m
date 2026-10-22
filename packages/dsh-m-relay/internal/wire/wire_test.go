package wire

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	payloads := [][]byte{
		nil,
		[]byte(`{"t":"ping","ts":1}`),
		bytes.Repeat([]byte{0x00, 0xff, 0x7f}, 5000),
	}
	types := []byte{TypeJSON, TypeFin, TypeRst, TypeData}
	for i, payload := range payloads {
		var buf bytes.Buffer
		typ := types[i%len(types)]
		if err := WriteFrame(&buf, typ, payload); err != nil {
			t.Fatalf("WriteFrame(%d bytes): %v", len(payload), err)
		}
		gotType, gotPayload, err := ReadFrame(&buf)
		if err != nil {
			t.Fatalf("ReadFrame: %v", err)
		}
		if gotType != typ {
			t.Fatalf("type = 0x%02x, want 0x%02x", gotType, typ)
		}
		if !bytes.Equal(gotPayload, payload) {
			t.Fatalf("payload mismatch: got %d bytes, want %d", len(gotPayload), len(payload))
		}
	}
}

func TestReadFrameCleanEOF(t *testing.T) {
	_, _, err := ReadFrame(bytes.NewReader(nil))
	if !errors.Is(err, io.EOF) {
		t.Fatalf("err = %v, want io.EOF", err)
	}
}

func TestReadFrameTruncatedHeader(t *testing.T) {
	_, _, err := ReadFrame(bytes.NewReader([]byte{0, 0, 0}))
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("err = %v, want io.ErrUnexpectedEOF", err)
	}
}

func TestReadFrameTruncatedPayload(t *testing.T) {
	buf := make([]byte, 4+3)
	binary.BigEndian.PutUint32(buf[:4], 10) // claims 10 bytes, only 3 follow
	_, _, err := ReadFrame(bytes.NewReader(buf))
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("err = %v, want io.ErrUnexpectedEOF", err)
	}
}

func TestReadFrameRejectsInvalidLengths(t *testing.T) {
	for _, n := range []uint32{0, MaxFrameLen + 1, 0xffffffff} {
		buf := make([]byte, 4)
		binary.BigEndian.PutUint32(buf, n)
		_, _, err := ReadFrame(bytes.NewReader(buf))
		if !errors.Is(err, ErrFrameTooLarge) {
			t.Fatalf("length %d: err = %v, want ErrFrameTooLarge", n, err)
		}
	}
}

func TestWriteFrameRejectsOversizedPayload(t *testing.T) {
	var buf bytes.Buffer
	err := WriteFrame(&buf, TypeData, make([]byte, MaxPayloadLen+1))
	if !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatalf("err = %v, want ErrPayloadTooLarge", err)
	}
}

func TestDataAndSIDPayloads(t *testing.T) {
	sid := uint32(0xdeadbeef)
	gotSid, gotData, err := ParseData(EncodeData(sid, []byte("abc")))
	if err != nil || gotSid != sid || string(gotData) != "abc" {
		t.Fatalf("ParseData = (%d, %q, %v)", gotSid, gotData, err)
	}
	if _, _, err := ParseData([]byte{1, 2, 3}); !errors.Is(err, ErrPayloadTooShort) {
		t.Fatalf("short DATA err = %v", err)
	}
	gotSid, err = ParseSID(SidPayload(sid))
	if err != nil || gotSid != sid {
		t.Fatalf("ParseSID = (%d, %v)", gotSid, err)
	}
	if _, err := ParseSID([]byte{1, 2, 3}); err == nil {
		t.Fatal("ParseSID accepted a 3-byte payload")
	}
	gotSid, code, err := ParseRST(EncodeRST(sid, RstTimeout))
	if err != nil || gotSid != sid || code != RstTimeout {
		t.Fatalf("ParseRST = (%d, %d, %v)", gotSid, code, err)
	}
	if _, _, err := ParseRST([]byte{1}); err == nil {
		t.Fatal("ParseRST accepted a 1-byte payload")
	}
	if RstName(RstLocalIO) != "local-io" || RstName(RstTimeout) != "timeout" ||
		RstName(RstLimit) != "limit" || RstName(RstTunnelGone) != "tunnel-gone" ||
		RstName(RstProtocol) != "protocol" || RstName(0xee) != "code-238" {
		t.Fatalf("RstName mismatch: %q %q %q %q %q %q", RstName(RstLocalIO), RstName(RstTimeout),
			RstName(RstLimit), RstName(RstTunnelGone), RstName(RstProtocol), RstName(0xee))
	}
}
