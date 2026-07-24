package nodeagent

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"
)

type certificateFixture struct {
	caCertificate []byte
	caKey         []byte
	serverCert    []byte
	serverKey     []byte
}

func newCertificateFixture(t *testing.T, dnsNames ...string) certificateFixture {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "kubernetes"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	serverKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "kube-apiserver"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     append([]string(nil), dnsNames...),
		IPAddresses:  []net.IP{net.ParseIP("10.0.0.1")},
	}
	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &serverKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return certificateFixture{
		caCertificate: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}),
		caKey:         pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(caKey)}),
		serverCert:    pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverDER}),
		serverKey:     pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(serverKey)}),
	}
}

func TestAddEndpointIPProducesAClientVerifiableCertificate(t *testing.T) {
	fixture := newCertificateFixture(t, "k8sedge", "k8sedge.zerops")
	const endpoint = "10.0.71.222"
	updated, err := addEndpointToCertificate(
		fixture.serverCert,
		fixture.caCertificate,
		fixture.caKey,
		fixture.serverKey,
		endpoint,
		time.Now(),
	)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := parseCertificatePEM(updated)
	if err != nil {
		t.Fatal(err)
	}
	for _, hostname := range []string{"k8sedge", "k8sedge.zerops"} {
		if !certificateHasDNSName(certificate, hostname) {
			t.Fatalf("updated certificate is missing %s", hostname)
		}
	}
	if !certificateHasEndpoint(certificate, endpoint) {
		t.Fatalf("updated certificate is missing endpoint IP %s", endpoint)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(fixture.caCertificate) {
		t.Fatal("failed to add fixture CA")
	}
	if _, err := certificate.Verify(x509.VerifyOptions{Roots: roots, DNSName: endpoint}); err != nil {
		t.Fatalf("Go TLS clients cannot verify the endpoint IP: %v", err)
	}
}

func TestEnsureAPIServerEndpointSANIsAtomicAndIdempotent(t *testing.T) {
	fixture := newCertificateFixture(t, "k8sedge", "k8sedge.zerops")
	runner := &certificateRunner{files: map[string]string{
		"ca.crt":        string(fixture.caCertificate),
		"ca.key":        string(fixture.caKey),
		"apiserver.crt": string(fixture.serverCert),
		"apiserver.key": string(fixture.serverKey),
	}}
	a := agent{cfg: config{
		Role:                 "control-plane",
		ContainerName:        "zerops-k8s-node",
		ControlPlaneEndpoint: "10.0.71.222:6443",
	}, runner: runner}
	updated, err := a.ensureAPIServerEndpointSAN(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !updated {
		t.Fatalf("updated=%v commands=%#v", updated, runner.commands)
	}
	joined := runner.joinedCommands()
	if !strings.Contains(joined, "mktemp /etc/kubernetes/pki/.apiserver.crt") ||
		!strings.Contains(joined, "crictl ps --name kube-apiserver") ||
		!strings.Contains(joined, "crictl stop") ||
		!strings.Contains(joined, "openssl x509 -in \"$certificate\" -noout \"$check_flag\"") ||
		!strings.Contains(joined, "10.0.71.222 -checkip") {
		t.Fatalf("atomic update or API restart command is incomplete: %s", joined)
	}
	firstCommandCount := len(runner.commands)
	updated, err = a.ensureAPIServerEndpointSAN(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if updated || len(runner.commands) != firstCommandCount+2 {
		t.Fatalf("second reconciliation was not idempotent: updated=%v commands=%#v", updated, runner.commands)
	}
}

type certificateRunner struct {
	commands        []recordedCommand
	files           map[string]string
	servingEndpoint bool
}

func (r *certificateRunner) run(_ context.Context, name string, args []string, stdin string) (string, error) {
	r.commands = append(r.commands, recordedCommand{name: name, args: append([]string(nil), args...)})
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "openssl s_client -connect 127.0.0.1:6443") {
		if r.servingEndpoint {
			return "", nil
		}
		return "", errors.New("serving certificate has not reloaded")
	}
	for filename, contents := range r.files {
		if strings.HasSuffix(joined, "/etc/kubernetes/pki/"+filename) && strings.Contains(joined, " cat ") {
			return contents, nil
		}
	}
	if strings.Contains(joined, "mktemp /etc/kubernetes/pki/.apiserver.crt") {
		r.files["apiserver.crt"] = stdin
	}
	if strings.Contains(joined, "crictl stop") {
		r.servingEndpoint = true
	}
	return "", nil
}

func (r *certificateRunner) joinedCommands() string {
	commands := make([]string, 0, len(r.commands))
	for _, command := range r.commands {
		commands = append(commands, command.name+" "+strings.Join(command.args, " "))
	}
	return strings.Join(commands, "\n")
}
