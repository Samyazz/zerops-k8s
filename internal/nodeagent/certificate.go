package nodeagent

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"time"
)

const dsrAPIServerHostname = "_dsr.k8sedge.zerops"

// kubeadm correctly rejects the underscore in Zerops' reserved _dsr service
// label as non-RFC-1123. Go's TLS verifier intentionally accepts underscores
// used by private infrastructure, so extend kubeadm's generated serving
// certificate after creation while leaving kubeadm's own endpoint valid.
func (a *agent) ensureAPIServerDSRSAN(ctx context.Context) (bool, error) {
	if a.cfg.Role != "control-plane" {
		return false, nil
	}
	certificatePEM, err := a.readNestedPKIFile(ctx, "apiserver.crt")
	if err != nil {
		return false, fmt.Errorf("read API server certificate: %w", err)
	}
	certificate, err := parseCertificatePEM(certificatePEM)
	if err != nil {
		return false, fmt.Errorf("parse API server certificate: %w", err)
	}
	if certificateHasDNSName(certificate, dsrAPIServerHostname) {
		return false, nil
	}

	caCertificatePEM, err := a.readNestedPKIFile(ctx, "ca.crt")
	if err != nil {
		return false, fmt.Errorf("read Kubernetes CA certificate: %w", err)
	}
	caKeyPEM, err := a.readNestedPKIFile(ctx, "ca.key")
	if err != nil {
		return false, fmt.Errorf("read Kubernetes CA key: %w", err)
	}
	serverKeyPEM, err := a.readNestedPKIFile(ctx, "apiserver.key")
	if err != nil {
		return false, fmt.Errorf("read API server key: %w", err)
	}

	updatedPEM, err := addDNSNameToCertificate(
		certificatePEM,
		caCertificatePEM,
		caKeyPEM,
		serverKeyPEM,
		dsrAPIServerHostname,
		time.Now(),
	)
	if err != nil {
		return false, err
	}
	if err := a.writeNestedAPIServerCertificate(ctx, updatedPEM); err != nil {
		return false, fmt.Errorf("write API server certificate: %w", err)
	}

	const restart = `
set -eu
container_id=$(crictl ps --name kube-apiserver -q | head -n 1)
test -n "$container_id"
crictl stop "$container_id" >/dev/null
`
	if _, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "sh", "-ec", restart,
	}, ""); err != nil {
		return true, fmt.Errorf("restart kube-apiserver after DSR certificate update: %w", err)
	}
	log.Printf(`{"component":"node-agent","operation":"api-certificate-dsr-san","status":"updated"}`)
	return true, nil
}

func (a *agent) readNestedPKIFile(ctx context.Context, name string) ([]byte, error) {
	value, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "cat", "/etc/kubernetes/pki/" + name,
	}, "")
	if err != nil {
		return nil, err
	}
	return []byte(value), nil
}

func (a *agent) writeNestedAPIServerCertificate(ctx context.Context, certificate []byte) error {
	const writeCertificate = `
set -eu
temporary=$(mktemp /etc/kubernetes/pki/.apiserver.crt.XXXXXX)
trap 'rm -f "$temporary"' EXIT
cat >"$temporary"
chown root:root "$temporary"
chmod 0644 "$temporary"
sync "$temporary"
mv "$temporary" /etc/kubernetes/pki/apiserver.crt
trap - EXIT
`
	_, err := a.runner.run(ctx, "docker", []string{
		"exec", "-i", a.cfg.ContainerName, "sh", "-ec", writeCertificate,
	}, string(certificate))
	return err
}

func addDNSNameToCertificate(certificatePEM, caCertificatePEM, caKeyPEM, serverKeyPEM []byte, hostname string, now time.Time) ([]byte, error) {
	certificate, err := parseCertificatePEM(certificatePEM)
	if err != nil {
		return nil, fmt.Errorf("parse API server certificate: %w", err)
	}
	if certificateHasDNSName(certificate, hostname) {
		return certificatePEM, nil
	}
	caCertificate, err := parseCertificatePEM(caCertificatePEM)
	if err != nil {
		return nil, fmt.Errorf("parse Kubernetes CA certificate: %w", err)
	}
	caSigner, err := parseSignerPEM(caKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse Kubernetes CA key: %w", err)
	}
	serverSigner, err := parseSignerPEM(serverKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse API server key: %w", err)
	}
	if certificate.NotAfter.Before(now.Add(5 * time.Minute)) {
		return nil, fmt.Errorf("refusing to reissue an expired or imminently expiring API server certificate")
	}

	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return nil, fmt.Errorf("generate API server certificate serial: %w", err)
	}
	if serial.Sign() == 0 {
		serial.SetInt64(1)
	}
	template := *certificate
	template.SerialNumber = serial
	template.NotBefore = now.Add(-5 * time.Minute)
	template.DNSNames = append(append([]string(nil), certificate.DNSNames...), hostname)
	template.Raw = nil
	template.RawTBSCertificate = nil
	template.RawSubjectPublicKeyInfo = nil
	template.RawSubject = nil
	template.RawIssuer = nil
	template.Signature = nil
	template.Extensions = nil
	template.ExtraExtensions = nil
	template.UnhandledCriticalExtensions = nil

	der, err := x509.CreateCertificate(rand.Reader, &template, caCertificate, serverSigner.Public(), caSigner)
	if err != nil {
		return nil, fmt.Errorf("issue API server certificate with DSR SAN: %w", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}

func parseCertificatePEM(data []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("PEM certificate block is missing")
	}
	return x509.ParseCertificate(block.Bytes)
}

func parseSignerPEM(data []byte) (crypto.Signer, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("PEM private-key block is missing")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if signer, ok := key.(crypto.Signer); ok {
			return signer, nil
		}
	}
	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	if key, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	return nil, fmt.Errorf("unsupported private-key encoding")
}

func certificateHasDNSName(certificate *x509.Certificate, hostname string) bool {
	for _, candidate := range certificate.DNSNames {
		if candidate == hostname {
			return true
		}
	}
	return false
}
