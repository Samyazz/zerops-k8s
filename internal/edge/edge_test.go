package edge

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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
