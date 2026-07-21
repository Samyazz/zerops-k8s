package edge

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestConfiguredProxiesPreserveFullDefaults(t *testing.T) {
	for _, key := range []string{
		"K8S_EDGE_API_ENABLED", "K8S_EDGE_API_BACKENDS",
		"K8S_EDGE_INGRESS_ENABLED", "K8S_EDGE_INGRESS_BACKENDS",
		"K8S_EDGE_HEADLAMP_ENABLED", "K8S_EDGE_HEADLAMP_BACKENDS",
	} {
		t.Setenv(key, "")
	}

	proxies, err := configuredProxies()
	if err != nil {
		t.Fatal(err)
	}
	if len(proxies) != 3 {
		t.Fatalf("expected all three full-profile routes, got %d", len(proxies))
	}
	for _, p := range proxies {
		if len(p.backends) != 3 {
			t.Fatalf("expected three default backends for %s, got %v", p.name, p.backends)
		}
	}
}

func TestConfiguredProxiesAllowDisabledRoutesAndOneAPIBackend(t *testing.T) {
	t.Setenv("K8S_EDGE_API_BACKENDS", "k8scp1:6443")
	t.Setenv("K8S_EDGE_INGRESS_ENABLED", "false")
	t.Setenv("K8S_EDGE_HEADLAMP_ENABLED", "false")

	proxies, err := configuredProxies()
	if err != nil {
		t.Fatal(err)
	}
	if len(proxies) != 1 || proxies[0].name != "kubernetes-api" {
		t.Fatalf("expected only the API proxy, got %#v", proxies)
	}
	if got := proxies[0].backends; len(got) != 1 || got[0] != "k8scp1:6443" {
		t.Fatalf("unexpected API backends: %v", got)
	}
}

func TestConfiguredProxiesRejectEnabledRouteWithoutBackends(t *testing.T) {
	t.Setenv("K8S_EDGE_API_BACKENDS", " , ")
	_, err := configuredProxies()
	if err == nil || !strings.Contains(err.Error(), "kubernetes-api has no backends") {
		t.Fatalf("expected missing-backend error, got %v", err)
	}
}

func TestDialFailsOverToNextBackend(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			_ = conn.Close()
		}
	}()

	p := proxy{name: "test", backends: []string{"127.0.0.1:1", listener.Addr().String()}}
	conn, err := p.dial()
	if err != nil {
		t.Fatalf("expected second backend to accept the connection: %v", err)
	}
	_ = conn.Close()
}

func TestReadinessChecksOnlyConfiguredRoutes(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			_ = conn.Close()
		}
	}()

	handler := healthHandler([]*proxy{{name: "enabled", backends: []string{listener.Addr().String()}}})
	request := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || response.Body.String() != "ready\n" {
		t.Fatalf("unexpected readiness response: status=%d body=%q", response.Code, response.Body.String())
	}
}

func TestBackendReadyRequiresSuccessfulHealthResponse(t *testing.T) {
	status := http.StatusOK
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
	}))
	defer server.Close()

	p := proxy{healthScheme: "https", healthPath: "/readyz"}
	backend := strings.TrimPrefix(server.URL, "https://")
	if !p.backendReady(backend) {
		t.Fatal("expected healthy TLS backend to be accepted")
	}
	status = http.StatusInternalServerError
	if p.backendReady(backend) {
		t.Fatal("expected unready TLS backend to be rejected")
	}
}
