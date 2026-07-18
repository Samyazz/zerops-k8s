package nodeagent

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestWriteJSONSetsExplicitContentLength(t *testing.T) {
	recorder := httptest.NewRecorder()
	writeJSON(recorder, http.StatusCreated, response{Status: "ok"})

	result := recorder.Result()
	t.Cleanup(func() { _ = result.Body.Close() })
	want := strconv.Itoa(recorder.Body.Len())
	if got := result.Header.Get("Content-Length"); got != want {
		t.Fatalf("Content-Length = %q, want %q", got, want)
	}
}

func TestValidCAHash(t *testing.T) {
	valid := "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if !validCAHash(valid) {
		t.Fatal("expected a valid CA hash")
	}
	for _, invalid := range []string{"", "sha256:abc", "sha512:" + valid, "sha256:ABCDEF"} {
		if validCAHash(invalid) {
			t.Fatalf("accepted invalid hash %q", invalid)
		}
	}
}

func TestInitConfigUsesHostWithoutPortForCertificateSAN(t *testing.T) {
	a := agent{cfg: config{
		BootstrapToken:       "123456.1234567890123456",
		NodeName:             "k8scp1",
		CertificateKey:       strings.Repeat("a", 64),
		KubernetesVersion:    "v1.36.2",
		ControlPlaneEndpoint: "k8sedge:6443",
		PodCIDR:              "10.244.0.0/16",
		ServiceCIDR:          "10.96.0.0/16",
	}}
	config := a.initConfig("10.0.0.1")
	if !strings.Contains(config, "controlPlaneEndpoint: k8sedge:6443") {
		t.Fatal("control-plane endpoint lost its API port")
	}
	if strings.Contains(config, "    - k8sedge:6443") {
		t.Fatal("certificate SAN must not contain a port")
	}
	if !strings.Contains(config, "    - k8sedge\n") {
		t.Fatal("certificate SAN is missing the endpoint hostname")
	}
	if !strings.Contains(config, "kind: KubeletConfiguration\nresolvConf: /etc/kubernetes/resolv.conf\n") {
		t.Fatal("kubelet resolver configuration is missing")
	}
}

func TestResolverConfigKeepsNameserversAndDropsSearchDomains(t *testing.T) {
	got, err := resolverConfig("nameserver 10.0.68.1\nsearch zerops\noptions ndots:5\nnameserver 2001:db8::53\n")
	if err != nil {
		t.Fatal(err)
	}
	want := "nameserver 10.0.68.1\nnameserver 2001:db8::53\n"
	if got != want {
		t.Fatalf("resolver config = %q, want %q", got, want)
	}
	if _, err := resolverConfig("search zerops\n"); err == nil {
		t.Fatal("resolver without a nameserver was accepted")
	}
}
