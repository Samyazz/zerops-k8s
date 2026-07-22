package edge

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type proxy struct {
	name         string
	listener     string
	backends     []string
	healthScheme string
	healthPath   string
	next         atomic.Uint64
}

func Run() error {
	proxies, err := configuredProxies()
	if err != nil {
		return err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	errCh := make(chan error, len(proxies)+1)
	var wg sync.WaitGroup
	for _, p := range proxies {
		if len(p.backends) == 0 {
			return fmt.Errorf("%s has no backends", p.name)
		}
		wg.Add(1)
		go func(p *proxy) {
			defer wg.Done()
			if err := p.serve(ctx); err != nil && !errors.Is(err, net.ErrClosed) {
				errCh <- err
			}
		}(p)
	}

	health := &http.Server{
		Addr:              env("K8S_EDGE_HEALTH_LISTEN", ":18082"),
		Handler:           healthHandler(proxies),
		ReadHeaderTimeout: 5 * time.Second,
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := health.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case <-ctx.Done():
	case err := <-errCh:
		cancel()
		_ = health.Close()
		wg.Wait()
		return err
	}
	_ = health.Close()
	wg.Wait()
	return nil
}

func configuredProxies() ([]*proxy, error) {
	type route struct {
		name             string
		enabledKey       string
		listenerKey      string
		listenerFallback string
		backendsKey      string
		backendsFallback string
		healthScheme     string
		healthPath       string
	}
	routes := []route{
		{name: "kubernetes-api", enabledKey: "K8S_EDGE_API_ENABLED", listenerKey: "K8S_EDGE_API_LISTEN", listenerFallback: ":6443", backendsKey: "K8S_EDGE_API_BACKENDS", backendsFallback: "k8scp1:6443,k8scp2:6443,k8scp3:6443", healthScheme: "https", healthPath: "/readyz"},
		{name: "application-ingress", enabledKey: "K8S_EDGE_INGRESS_ENABLED", listenerKey: "K8S_EDGE_INGRESS_LISTEN", listenerFallback: ":8080", backendsKey: "K8S_EDGE_INGRESS_BACKENDS", backendsFallback: "k8sworker1:32080,k8sworker2:32080,k8sworker3:32080", healthScheme: "http", healthPath: "/healthz"},
		{name: "headlamp", enabledKey: "K8S_EDGE_HEADLAMP_ENABLED", listenerKey: "K8S_EDGE_HEADLAMP_LISTEN", listenerFallback: ":18081", backendsKey: "K8S_EDGE_HEADLAMP_BACKENDS", backendsFallback: "k8sworker1:32081,k8sworker2:32081,k8sworker3:32081"},
	}

	proxies := make([]*proxy, 0, len(routes))
	for _, route := range routes {
		enabled, err := boolEnv(route.enabledKey, true)
		if err != nil {
			return nil, err
		}
		if !enabled {
			continue
		}
		backends := csvEnv(route.backendsKey, route.backendsFallback)
		if len(backends) == 0 {
			return nil, fmt.Errorf("%s has no backends", route.name)
		}
		proxies = append(proxies, &proxy{
			name:         route.name,
			listener:     env(route.listenerKey, route.listenerFallback),
			backends:     backends,
			healthScheme: route.healthScheme,
			healthPath:   route.healthPath,
		})
	}
	return proxies, nil
}

func (p *proxy) serve(ctx context.Context) error {
	listener, err := net.Listen("tcp", p.listener)
	if err != nil {
		return fmt.Errorf("listen %s on %s: %w", p.name, p.listener, err)
	}
	defer listener.Close()
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	log.Printf("edge proxy %s listening on %s for %s", p.name, p.listener, strings.Join(p.backends, ","))
	for {
		client, err := listener.Accept()
		if err != nil {
			return err
		}
		go p.handle(client)
	}
}

func (p *proxy) handle(client net.Conn) {
	defer client.Close()
	backend, err := p.dial()
	if err != nil {
		log.Printf("edge proxy %s: %v", p.name, err)
		return
	}
	defer backend.Close()

	done := make(chan struct{}, 2)
	copyConn := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		if tcp, ok := dst.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyConn(backend, client)
	go copyConn(client, backend)
	<-done
}

func (p *proxy) dial() (net.Conn, error) {
	start := int(p.next.Add(1)-1) % len(p.backends)
	var failures []string
	for i := range p.backends {
		candidate := p.backends[(start+i)%len(p.backends)]
		if !p.backendReady(candidate) {
			failures = append(failures, candidate+": readiness check failed")
			continue
		}
		conn, err := net.DialTimeout("tcp", candidate, 3*time.Second)
		if err == nil {
			return conn, nil
		}
		failures = append(failures, candidate+": "+err.Error())
	}
	return nil, fmt.Errorf("all backends failed: %s", strings.Join(failures, "; "))
}

func (p *proxy) backendReady(candidate string) bool {
	if p.healthPath == "" {
		return true
	}
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true}, // Health-only request to the private kubeadm API certificate.
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Timeout: 3 * time.Second, Transport: transport}
	response, err := client.Get(p.healthScheme + "://" + candidate + p.healthPath)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	return response.StatusCode == http.StatusOK
}

func healthHandler(proxies []*proxy) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		for _, p := range proxies {
			conn, err := p.dial()
			if err != nil {
				http.Error(w, p.name+" unavailable", http.StatusServiceUnavailable)
				return
			}
			_ = conn.Close()
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ready\n")
	})
	return mux
}

func csvEnv(key, fallback string) []string {
	value := env(key, fallback)
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if part = strings.TrimSpace(part); part != "" {
			result = append(result, part)
		}
	}
	return result
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func boolEnv(key string, fallback bool) (bool, error) {
	value := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
	if value == "" {
		return fallback, nil
	}
	switch value {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("%s must be a boolean", key)
	}
}
