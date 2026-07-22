package edge

import (
	"bytes"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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

func TestIngressDialSkipsTCPReachableButHTTPUnhealthyBackend(t *testing.T) {
	unhealthy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
	}))
	defer unhealthy.Close()
	healthy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	}))
	defer healthy.Close()

	p := proxy{
		name:         "application-ingress",
		backends:     []string{strings.TrimPrefix(unhealthy.URL, "http://"), strings.TrimPrefix(healthy.URL, "http://")},
		healthScheme: "http",
		healthPath:   "/healthz",
	}
	conn, err := p.dial()
	if err != nil {
		t.Fatalf("expected healthy HTTP backend to accept the connection: %v", err)
	}
	_ = conn.Close()
}

func TestConfiguredIngressUsesApplicationHealthEndpoint(t *testing.T) {
	t.Setenv("K8S_EDGE_API_ENABLED", "false")
	t.Setenv("K8S_EDGE_INGRESS_ENABLED", "true")
	t.Setenv("K8S_EDGE_INGRESS_BACKENDS", "k8sworker1:32080,k8sworker2:32080")
	t.Setenv("K8S_EDGE_HEADLAMP_ENABLED", "false")

	proxies, err := configuredProxies()
	if err != nil {
		t.Fatal(err)
	}
	if len(proxies) != 1 || proxies[0].healthScheme != "http" || proxies[0].healthPath != "/healthz" {
		t.Fatalf("unexpected ingress health configuration: %#v", proxies)
	}
}

func TestSuccessfulProxyConnectionEmitsStructuredLifecycleLog(t *testing.T) {
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

	var output bytes.Buffer
	previousWriter := log.Writer()
	previousFlags := log.Flags()
	previousPrefix := log.Prefix()
	log.SetOutput(&output)
	log.SetFlags(0)
	log.SetPrefix("")
	t.Cleanup(func() {
		log.SetOutput(previousWriter)
		log.SetFlags(previousFlags)
		log.SetPrefix(previousPrefix)
	})

	client, edgeSide := net.Pipe()
	done := make(chan struct{})
	go func() {
		(&proxy{name: "application-ingress", backends: []string{listener.Addr().String()}}).handle(edgeSide)
		close(done)
	}()
	_ = client.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy connection did not finish")
	}
	if !strings.Contains(output.String(), `{"component":"edge-proxy","route":"application-ingress","status":"connected"}`) {
		t.Fatalf("structured lifecycle log missing: %q", output.String())
	}
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
