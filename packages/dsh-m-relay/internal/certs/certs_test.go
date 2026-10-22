package certs

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestGenerateIPCertificate(t *testing.T) {
	m, err := Generate("203.0.113.10", 24*time.Hour)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if len(m.Pin) != 43 {
		t.Fatalf("pin length = %d, want 43", len(m.Pin))
	}
	der := m.Certificate.Raw
	sum := sha256.Sum256(der)
	if want := base64.RawURLEncoding.EncodeToString(sum[:]); want != m.Pin {
		t.Fatalf("pin = %q, want %q", m.Pin, want)
	}
	if !strings.Contains(m.Fingerprint256, ":") || len(m.Fingerprint256) != 95 {
		t.Fatalf("fingerprint = %q (len %d)", m.Fingerprint256, len(m.Fingerprint256))
	}
	if !CoversHost(m.Certificate, "203.0.113.10") {
		t.Fatal("IP SAN not covered")
	}
	if CoversHost(m.Certificate, "203.0.113.11") {
		t.Fatal("wrong IP reported as covered")
	}
	if m.Certificate.Subject.CommonName != "203.0.113.10" {
		t.Fatalf("CN = %q", m.Certificate.Subject.CommonName)
	}
	block, _ := pem.Decode(m.CertPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		t.Fatal("cert PEM is not a CERTIFICATE block")
	}
	block, _ = pem.Decode(m.KeyPEM)
	if block == nil || block.Type != "PRIVATE KEY" {
		t.Fatal("key PEM is not a PRIVATE KEY block")
	}
}

func TestGenerateDNSCertificateAndWildcard(t *testing.T) {
	m, err := Generate("relay.example.com", time.Hour)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if !CoversHost(m.Certificate, "relay.example.com") {
		t.Fatal("DNS SAN not covered")
	}
	if !CoversHost(m.Certificate, "RELAY.example.com.") {
		t.Fatal("DNS SAN should be case/trailing-dot insensitive")
	}
	if CoversHost(m.Certificate, "other.example.com") {
		t.Fatal("wrong DNS name reported as covered")
	}
	wild, err := Generate("*.example.com", time.Hour)
	if err != nil {
		t.Fatalf("Generate wildcard: %v", err)
	}
	if !CoversHost(wild.Certificate, "a.example.com") {
		t.Fatal("wildcard SAN not covered")
	}
	if CoversHost(wild.Certificate, "a.b.example.com") {
		t.Fatal("wildcard must match one label only")
	}
	if got := Sites(m.Certificate); len(got) != 1 || got[0] != "relay.example.com" {
		t.Fatalf("Sites = %v", got)
	}
}

func TestLoadAndVerifyPin(t *testing.T) {
	dir := t.TempDir()
	m, err := Generate("127.0.0.1", time.Hour)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	certFile := filepath.Join(dir, "cert.pem")
	keyFile := filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certFile, m.CertPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, m.KeyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	pair, leaf, err := Load(certFile, keyFile)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(pair.Certificate) == 0 {
		t.Fatal("loaded certificate chain is empty")
	}
	if got := Pin(leaf.Raw); got != m.Pin {
		t.Fatalf("loaded pin = %q, want %q", got, m.Pin)
	}
	verify := VerifyPin(m.Pin)
	if err := verify([][]byte{m.Certificate.Raw}, nil); err != nil {
		t.Fatalf("VerifyPin(valid) = %v", err)
	}
	if err := VerifyPin("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")([][]byte{m.Certificate.Raw}, nil); err == nil {
		t.Fatal("VerifyPin accepted a wrong pin")
	}
	if err := verify(nil, nil); err == nil {
		t.Fatal("VerifyPin accepted an empty chain")
	}
}

func TestLoadMissingFiles(t *testing.T) {
	if _, _, err := Load("/nonexistent/cert.pem", "/nonexistent/key.pem"); err == nil {
		t.Fatal("Load succeeded with missing files")
	}
	dir := t.TempDir()
	certFile := filepath.Join(dir, "cert.pem")
	keyFile := filepath.Join(dir, "key.pem")
	_ = os.WriteFile(certFile, []byte("junk"), 0o600)
	_ = os.WriteFile(keyFile, []byte("junk"), 0o600)
	if _, _, err := Load(certFile, keyFile); err == nil {
		t.Fatal("Load succeeded with junk PEM")
	}
	_ = tls.Certificate{}
}

func TestGenerateRejectsEmptyHost(t *testing.T) {
	if _, err := Generate("", time.Hour); err == nil {
		t.Fatal("Generate accepted an empty host")
	}
}
