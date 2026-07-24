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
	"net"
	"time"
)

// Reconcile the serving certificate after both initial bootstrap and upgrades.
// This is required for an existing recipe-managed cluster whose stable endpoint
// changes to the VRRP VIP without replacing its Kubernetes PKI.
func (a *agent) ensureAPIServerEndpointSAN(ctx context.Context) (bool, error) {
	if a.cfg.Role != "control-plane" {
		return false, nil
	}
	endpointHost, _, err := net.SplitHostPort(a.cfg.ControlPlaneEndpoint)
	if err != nil || endpointHost == "" {
		return false, fmt.Errorf("parse control-plane endpoint %q", a.cfg.ControlPlaneEndpoint)
	}
	certificatePEM, err := a.readNestedPKIFile(ctx, "apiserver.crt")
	if err != nil {
		return false, fmt.Errorf("read API server certificate: %w", err)
	}
	certificate, err := parseCertificatePEM(certificatePEM)
	if err != nil {
		return false, fmt.Errorf("parse API server certificate: %w", err)
	}
	if certificateHasEndpoint(certificate, endpointHost) && a.servingAPIServerHasEndpointSAN(ctx, endpointHost) {
		return false, nil
	}

	if !certificateHasEndpoint(certificate, endpointHost) {
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

		updatedPEM, err := addEndpointToCertificate(
			certificatePEM,
			caCertificatePEM,
			caKeyPEM,
			serverKeyPEM,
			endpointHost,
			time.Now(),
		)
		if err != nil {
			return false, err
		}
		if err := a.writeNestedAPIServerCertificate(ctx, updatedPEM); err != nil {
			return false, fmt.Errorf("write API server certificate: %w", err)
		}
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
		return true, fmt.Errorf("restart kube-apiserver after endpoint certificate update: %w", err)
	}
	deadline := time.Now().Add(30 * time.Second)
	for !a.servingAPIServerHasEndpointSAN(ctx, endpointHost) {
		if time.Now().After(deadline) {
			return true, fmt.Errorf("kube-apiserver did not present the endpoint certificate within 30 seconds")
		}
		select {
		case <-ctx.Done():
			return true, ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	log.Printf(`{"component":"node-agent","operation":"api-certificate-endpoint-san","status":"reconciled","endpoint":%q}`, endpointHost)
	return true, nil
}

func (a *agent) servingAPIServerHasEndpointSAN(ctx context.Context, endpointHost string) bool {
	const verify = `
set -eu
host=$1
check_flag=$2
certificate=$(mktemp)
trap 'rm -f "$certificate"' EXIT
timeout 5 openssl s_client -connect 127.0.0.1:6443 -servername "$host" </dev/null 2>/dev/null \
  | openssl x509 -outform PEM >"$certificate"
openssl x509 -in "$certificate" -noout "$check_flag" "$host" >/dev/null
`
	checkFlag := "-checkhost"
	if net.ParseIP(endpointHost) != nil {
		checkFlag = "-checkip"
	}
	_, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "sh", "-ec", verify,
		"verify-endpoint", endpointHost, checkFlag,
	}, "")
	return err == nil
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

func addEndpointToCertificate(certificatePEM, caCertificatePEM, caKeyPEM, serverKeyPEM []byte, endpoint string, now time.Time) ([]byte, error) {
	certificate, err := parseCertificatePEM(certificatePEM)
	if err != nil {
		return nil, fmt.Errorf("parse API server certificate: %w", err)
	}
	if certificateHasEndpoint(certificate, endpoint) {
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
	template.DNSNames = append([]string(nil), certificate.DNSNames...)
	template.IPAddresses = append([]net.IP(nil), certificate.IPAddresses...)
	if endpointIP := net.ParseIP(endpoint); endpointIP != nil {
		template.IPAddresses = append(template.IPAddresses, endpointIP)
	} else {
		template.DNSNames = append(template.DNSNames, endpoint)
	}
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
		return nil, fmt.Errorf("issue API server certificate with endpoint SAN: %w", err)
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

func certificateHasEndpoint(certificate *x509.Certificate, endpoint string) bool {
	if endpointIP := net.ParseIP(endpoint); endpointIP != nil {
		for _, candidate := range certificate.IPAddresses {
			if candidate.Equal(endpointIP) {
				return true
			}
		}
		return false
	}
	return certificateHasDNSName(certificate, endpoint)
}
