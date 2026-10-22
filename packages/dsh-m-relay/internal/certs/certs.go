// Package certs generates, loads, and pins the relay's self-signed TLS
// certificate. The pin used by the Mac plugin and the iOS App is
// base64url(SHA-256(certificate DER)) — the same format as the M1 plugin pins
// (see <internal-doc> §4.3/§4.4).
package certs

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"strings"
	"time"
)

// DefaultValidity is how long a freshly generated relay certificate is valid.
// Certificates are not renewed automatically; README.md documents rotation.
const DefaultValidity = 10 * 365 * 24 * time.Hour

// Material is a freshly generated key pair plus its pin.
type Material struct {
	Certificate    *x509.Certificate
	CertPEM        []byte
	KeyPEM         []byte
	Pin            string
	Fingerprint256 string
}

// Generate creates a self-signed ECDSA P-256 certificate for publicHost.
// publicHost may be an IP literal or a DNS name; the SAN list matches it.
func Generate(publicHost string, validity time.Duration) (*Material, error) {
	if publicHost == "" {
		return nil, fmt.Errorf("certs: publicHost is empty")
	}
	if validity <= 0 {
		validity = DefaultValidity
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("certs: generate key: %w", err)
	}
	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return nil, fmt.Errorf("certs: serial: %w", err)
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: publicHost, Organization: []string{"DSH-m relay"}},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(validity),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
	}
	if ip := net.ParseIP(publicHost); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	} else {
		tmpl.DNSNames = []string{publicHost}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, fmt.Errorf("certs: create certificate: %w", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, fmt.Errorf("certs: parse generated certificate: %w", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("certs: marshal private key: %w", err)
	}
	return &Material{
		Certificate:    cert,
		CertPEM:        pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		KeyPEM:         pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
		Pin:            Pin(der),
		Fingerprint256: Fingerprint256(der),
	}, nil
}

// Load reads a PEM cert/key pair from disk.
func Load(certFile, keyFile string) (tls.Certificate, *x509.Certificate, error) {
	certPEM, err := os.ReadFile(certFile)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("certs: read certificate %s: %w", certFile, err)
	}
	keyPEM, err := os.ReadFile(keyFile)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("certs: read key %s: %w", keyFile, err)
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("certs: load key pair: %w", err)
	}
	if len(pair.Certificate) == 0 {
		return tls.Certificate{}, nil, fmt.Errorf("certs: certificate chain is empty")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("certs: parse leaf certificate: %w", err)
	}
	return pair, leaf, nil
}

// Pin returns base64url(SHA-256(der)) without padding (43 chars for a 32-byte hash).
func Pin(der []byte) string {
	sum := sha256.Sum256(der)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// Fingerprint256 returns the colon-separated uppercase hex SHA-256 of der,
// matching the M1 plugin's `leafFingerprint256` format.
func Fingerprint256(der []byte) string {
	sum := sha256.Sum256(der)
	hexStr := strings.ToUpper(hex.EncodeToString(sum[:]))
	var b strings.Builder
	b.Grow(len(hexStr) + len(hexStr)/2)
	for i := 0; i < len(hexStr); i += 2 {
		if i > 0 {
			b.WriteByte(':')
		}
		b.WriteString(hexStr[i : i+2])
	}
	return b.String()
}

// VerifyPin returns a tls.Config.VerifyPeerCertificate callback that accepts the
// peer certificate only when its DER SHA-256 equals expectedPin. The relay is
// self-signed, so system roots are deliberately bypassed by the caller
// (InsecureSkipVerify=true + this callback).
func VerifyPin(expectedPin string) func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
	expected := strings.TrimSpace(expectedPin)
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if len(rawCerts) == 0 {
			return fmt.Errorf("certs: peer presented no certificate")
		}
		got := Pin(rawCerts[0])
		if subtle.ConstantTimeCompare([]byte(got), []byte(expected)) != 1 {
			return fmt.Errorf("certs: relay pin mismatch: got %s", got)
		}
		return nil
	}
}

// CoversHost reports whether cert is valid for host (IP SAN or DNS SAN,
// including one-level wildcards such as *.example.com).
func CoversHost(cert *x509.Certificate, host string) bool {
	if cert == nil || host == "" {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		for _, san := range cert.IPAddresses {
			if san.Equal(ip) {
				return true
			}
		}
		return false
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	for _, name := range cert.DNSNames {
		name = strings.ToLower(strings.TrimSuffix(name, "."))
		if name == host {
			return true
		}
		if strings.HasPrefix(name, "*.") {
			suffix := name[1:] // ".example.com"
			if strings.HasSuffix(host, suffix) && strings.Count(host, ".") == strings.Count(suffix, ".") {
				return true
			}
		}
	}
	return false
}

// Sites returns the SAN entries of cert (DNS names then IP addresses) for
// human-readable diagnostics.
func Sites(cert *x509.Certificate) []string {
	if cert == nil {
		return nil
	}
	out := make([]string, 0, len(cert.DNSNames)+len(cert.IPAddresses))
	out = append(out, cert.DNSNames...)
	for _, ip := range cert.IPAddresses {
		out = append(out, ip.String())
	}
	return out
}
