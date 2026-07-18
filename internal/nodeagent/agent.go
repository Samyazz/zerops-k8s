package nodeagent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type agent struct {
	cfg    config
	runner commandRunner
	mu     sync.Mutex
}

type response struct {
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
	CAHash string `json:"caHash,omitempty"`
	Digest string `json:"digest,omitempty"`
}

func Run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	a := &agent{cfg: cfg, runner: osRunner{}}
	if err := a.ensureStateDirs(); err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.health)
	mux.Handle("GET /v1/state", a.auth(http.HandlerFunc(a.state)))
	mux.Handle("POST /v1/node/start", a.auth(http.HandlerFunc(a.startNode)))
	mux.Handle("POST /v1/node/stop", a.auth(http.HandlerFunc(a.stopNode)))
	mux.Handle("PUT /v1/node/image", a.auth(http.HandlerFunc(a.loadNodeImage)))
	mux.Handle("POST /v1/cluster/init", a.auth(http.HandlerFunc(a.initCluster)))
	mux.Handle("POST /v1/cluster/join", a.auth(http.HandlerFunc(a.joinCluster)))
	mux.Handle("POST /v1/cluster/reset", a.auth(http.HandlerFunc(a.resetCluster)))
	mux.Handle("GET /v1/cluster/kubeconfig", a.auth(http.HandlerFunc(a.kubeconfig)))

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           requestLog(mux),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      15 * time.Minute,
		IdleTimeout:       60 * time.Second,
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	errCh := make(chan error, 1)
	go func() {
		log.Printf("node agent for %s (%s) listening on %s", cfg.NodeName, cfg.Role, cfg.Listen)
		errCh <- server.ListenAndServe()
	}()
	select {
	case <-ctx.Done():
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		return server.Shutdown(shutdownCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func (a *agent) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if len(provided) != len(a.cfg.Token) || subtle.ConstantTimeCompare([]byte(provided), []byte(a.cfg.Token)) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *agent) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, response{Status: "ok"})
}

func (a *agent) state(w http.ResponseWriter, r *http.Request) {
	state, detail := a.containerState(r.Context())
	writeJSON(w, http.StatusOK, response{Status: state, Detail: detail})
}

func (a *agent) startNode(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.startNodeLocked(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, response{Status: "running"})
}

func (a *agent) startNodeLocked(ctx context.Context) error {
	state, _ := a.containerState(ctx)
	switch state {
	case "running":
		return a.ensureNestedNodeReady(ctx, false)
	case "stopped":
		a.terminateOrphanedPodProcesses(ctx)
		if _, err := a.runner.run(ctx, "docker", []string{"start", a.cfg.ContainerName}, ""); err != nil {
			return err
		}
		return a.ensureNestedNodeReady(ctx, true)
	}
	if err := a.ensureNodeImage(ctx); err != nil {
		return err
	}
	args := []string{
		"run", "--detach", "--name", a.cfg.ContainerName,
		"--hostname", a.cfg.NodeName,
		"--privileged", "--network=host", "--cgroupns=host",
		"--security-opt", "seccomp=unconfined",
		"--restart=unless-stopped", "--stop-signal=SIGRTMIN+3",
		"--tmpfs", "/run", "--tmpfs", "/run/lock",
		"--volume", "/sys:/sys:rshared",
		"--volume", "/lib/modules:/lib/modules:ro",
		"--volume", "/dev:/dev",
		"--volume", a.path("etc-kubernetes") + ":/etc/kubernetes",
		"--volume", a.path("etcd") + ":/var/lib/etcd",
		"--volume", a.path("kubelet") + ":/var/lib/kubelet:rshared",
		"--volume", a.path("containerd") + ":/var/lib/containerd",
		"--volume", a.path("cni-config") + ":/etc/cni/net.d",
		"--volume", a.path("cni-bin") + ":/opt/cni/bin",
		"--volume", a.path("longhorn") + ":/var/lib/longhorn:rshared",
		"--volume", a.path("logs", "pods") + ":/var/log/pods:rshared",
		"--volume", a.path("logs", "containers") + ":/var/log/containers:rshared",
		"--volume", a.path("logs", "kubernetes") + ":/var/log/kubernetes:rshared",
		"--volume", a.path("logs", "journal") + ":/var/log/journal",
		a.cfg.NodeImage,
	}
	if _, err := a.runner.run(ctx, "docker", args, ""); err != nil {
		return err
	}
	return a.ensureNestedNodeReady(ctx, true)
}

// terminateOrphanedPodProcesses is a recovery path for an unclean wrapper
// stop. Nested pods use the host cgroup namespace, so their processes can
// outlive the Docker container. Match only cgroups containing a Pod UID from
// this node's persisted kubelet state; outer Zerops workloads have different
// UIDs and are left untouched.
func (a *agent) terminateOrphanedPodProcesses(ctx context.Context) {
	podDirs, err := os.ReadDir(a.path("kubelet", "pods"))
	if err != nil {
		return
	}
	podUIDs := make([]string, 0, len(podDirs)*2)
	for _, entry := range podDirs {
		if !entry.IsDir() {
			continue
		}
		podUIDs = append(podUIDs, entry.Name(), strings.ReplaceAll(entry.Name(), "-", "_"))
	}
	if len(podUIDs) == 0 {
		return
	}
	procDirs, err := os.ReadDir("/proc")
	if err != nil {
		return
	}
	for _, entry := range procDirs {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == os.Getpid() {
			continue
		}
		cgroup, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "cgroup"))
		if err != nil {
			continue
		}
		for _, uid := range podUIDs {
			if strings.Contains(string(cgroup), uid) {
				_, _ = a.runner.run(ctx, "sudo", []string{"kill", "-KILL", "--", entry.Name()}, "")
				break
			}
		}
	}
}

func (a *agent) ensureNestedNodeReady(ctx context.Context, restartKubelet bool) error {
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		checkCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		_, err := a.runner.run(checkCtx, "docker", []string{"exec", a.cfg.ContainerName, "systemctl", "is-active", "containerd"}, "")
		cancel()
		if err == nil {
			if _, err := a.runner.run(ctx, "docker", []string{
				"exec", a.cfg.ContainerName, "mount", "--make-rshared", "/",
			}, ""); err != nil {
				return fmt.Errorf("make nested node mounts recursively shared: %w", err)
			}
			if restartKubelet {
				if _, err := a.runner.run(ctx, "docker", []string{
					"exec", a.cfg.ContainerName, "systemctl", "restart", "kubelet",
				}, ""); err != nil {
					return fmt.Errorf("restart kubelet after nested node start: %w", err)
				}
			}
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("node container did not start containerd within 3 minutes")
}

func (a *agent) ensureNodeImage(ctx context.Context) error {
	if _, err := a.runner.run(ctx, "docker", []string{"image", "inspect", a.cfg.NodeImage}, ""); err == nil {
		return nil
	}
	if !strings.Contains(a.cfg.NodeImage, "/") {
		return fmt.Errorf("node image %s is not loaded; upload it through PUT /v1/node/image", a.cfg.NodeImage)
	}
	_, err := a.runner.run(ctx, "docker", []string{"pull", a.cfg.NodeImage}, "")
	return err
}

func (a *agent) loadNodeImage(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	expected := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Zerops-Image-SHA256")))
	if len(expected) != 64 {
		http.Error(w, "X-Zerops-Image-SHA256 is required", http.StatusBadRequest)
		return
	}
	if _, err := hex.DecodeString(expected); err != nil {
		http.Error(w, "X-Zerops-Image-SHA256 must be lowercase hexadecimal", http.StatusBadRequest)
		return
	}

	hasher := sha256.New()
	body := http.MaxBytesReader(w, r.Body, 4<<30)
	defer body.Close()
	cmd := exec.CommandContext(r.Context(), "docker", "image", "load")
	cmd.Stdin = io.TeeReader(body, hasher)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		log.Printf("docker image load failed: %v: %s", err, strings.TrimSpace(output.String()))
		writeJSON(w, http.StatusInternalServerError, response{Status: "error", Detail: "image load failed; inspect service logs"})
		return
	}
	actual := hex.EncodeToString(hasher.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(actual), []byte(expected)) != 1 {
		_, _ = a.runner.run(r.Context(), "docker", []string{"image", "rm", "--force", a.cfg.NodeImage}, "")
		http.Error(w, "image archive checksum mismatch", http.StatusUnprocessableEntity)
		return
	}
	if _, err := a.runner.run(r.Context(), "docker", []string{"image", "inspect", a.cfg.NodeImage}, ""); err != nil {
		writeError(w, fmt.Errorf("archive did not contain expected image %s", a.cfg.NodeImage))
		return
	}
	writeJSON(w, http.StatusOK, response{Status: "loaded", Digest: "sha256:" + actual})
}

func (a *agent) stopNode(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	state, _ := a.containerState(r.Context())
	if state == "missing" || state == "stopped" {
		writeJSON(w, http.StatusOK, response{Status: state})
		return
	}
	// Pods run in the host cgroup namespace. If Docker stops the systemd
	// container first, containerd shims can survive outside its cgroup and
	// retain host ports. Stop kubelet and its tasks while containerd can still
	// account for them, then shut containerd down before stopping the wrapper.
	gracefulStop := `
systemctl stop kubelet || true
if systemctl is-active --quiet containerd; then
  for id in $(ctr -n k8s.io tasks ls -q 2>/dev/null); do
    ctr -n k8s.io tasks kill --signal SIGKILL --all "$id" >/dev/null 2>&1 || true
  done
  for attempt in $(seq 1 30); do
    [ -z "$(ctr -n k8s.io tasks ls -q 2>/dev/null)" ] && break
    sleep 1
  done
  systemctl stop containerd || true
fi
`
	if _, err := a.runner.run(r.Context(), "docker", []string{
		"exec", a.cfg.ContainerName, "sh", "-lc", gracefulStop,
	}, ""); err != nil {
		writeError(w, fmt.Errorf("quiesce nested Kubernetes node: %w", err))
		return
	}
	if _, err := a.runner.run(r.Context(), "docker", []string{"stop", "--time", "60", a.cfg.ContainerName}, ""); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, response{Status: "stopped"})
}

func (a *agent) initCluster(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.cfg.Role != "control-plane" || a.cfg.NodeName != "k8scp1" {
		http.Error(w, "cluster initialization is restricted to k8scp1", http.StatusForbidden)
		return
	}
	if err := a.requireBootstrapSecrets(); err != nil {
		writeError(w, err)
		return
	}
	if err := a.startNodeLocked(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	if a.isJoined(r.Context()) {
		hash, err := a.caHash(r.Context())
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, response{Status: "already-initialized", CAHash: hash})
		return
	}
	ip, err := primaryIPv4()
	if err != nil {
		writeError(w, err)
		return
	}
	if err := a.writeControlPlaneFiles(); err != nil {
		writeError(w, err)
		return
	}
	configText := a.initConfig(ip)
	if err := os.WriteFile(a.path("etc-kubernetes", "zerops-init.yaml"), []byte(configText), 0600); err != nil {
		writeError(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()
	if _, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "kubeadm", "init",
		"--config", "/etc/kubernetes/zerops-init.yaml",
		"--upload-certs", "--ignore-preflight-errors=SystemVerification",
	}, ""); err != nil {
		writeError(w, err)
		return
	}
	hash, err := a.caHash(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, response{Status: "initialized", CAHash: hash})
}

type joinRequest struct {
	CAHash string `json:"caHash"`
}

func (a *agent) joinCluster(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.requireBootstrapSecrets(); err != nil {
		writeError(w, err)
		return
	}
	var req joinRequest
	decoder := json.NewDecoder(io.LimitReader(r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if !validCAHash(req.CAHash) {
		http.Error(w, "caHash must be sha256 followed by 64 lowercase hexadecimal characters", http.StatusBadRequest)
		return
	}
	if err := a.startNodeLocked(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	if a.isJoined(r.Context()) {
		writeJSON(w, http.StatusOK, response{Status: "already-joined"})
		return
	}
	ip, err := primaryIPv4()
	if err != nil {
		writeError(w, err)
		return
	}
	if a.cfg.Role == "control-plane" {
		if err := a.writeControlPlaneFiles(); err != nil {
			writeError(w, err)
			return
		}
	}
	configText := a.joinConfig(ip, req.CAHash)
	if err := os.WriteFile(a.path("etc-kubernetes", "zerops-join.yaml"), []byte(configText), 0600); err != nil {
		writeError(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()
	if _, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "kubeadm", "join",
		"--config", "/etc/kubernetes/zerops-join.yaml",
		"--ignore-preflight-errors=SystemVerification",
	}, ""); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, response{Status: "joined"})
}

func (a *agent) resetCluster(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	state, _ := a.containerState(r.Context())
	if state != "missing" {
		if state != "running" {
			if _, err := a.runner.run(r.Context(), "docker", []string{"start", a.cfg.ContainerName}, ""); err != nil {
				writeError(w, err)
				return
			}
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
		_, _ = a.runner.run(ctx, "docker", []string{"exec", a.cfg.ContainerName, "kubeadm", "reset", "--force"}, "")
		cancel()
		_, _ = a.runner.run(r.Context(), "docker", []string{"rm", "--force", a.cfg.ContainerName}, "")
	}
	if err := a.clearState(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, response{Status: "reset"})
}

func (a *agent) kubeconfig(w http.ResponseWriter, r *http.Request) {
	if a.cfg.NodeName != "k8scp1" {
		http.Error(w, "kubeconfig is only available from k8scp1", http.StatusForbidden)
		return
	}
	data, err := a.runner.run(r.Context(), "docker", []string{
		"exec", a.cfg.ContainerName, "cat", "/etc/kubernetes/admin.conf",
	}, "")
	if err != nil {
		http.Error(w, "cluster is not initialized", http.StatusConflict)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/yaml")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(data))
}

func (a *agent) containerState(ctx context.Context) (string, string) {
	out, err := a.runner.run(ctx, "docker", []string{"inspect", "--format", "{{.State.Status}}", a.cfg.ContainerName}, "")
	if err != nil {
		if strings.Contains(err.Error(), "No such object") {
			return "missing", ""
		}
		return "error", err.Error()
	}
	state := strings.TrimSpace(out)
	if state == "exited" || state == "created" || state == "dead" {
		state = "stopped"
	}
	return state, ""
}

func (a *agent) isJoined(ctx context.Context) bool {
	_, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "test", "-s", "/etc/kubernetes/kubelet.conf",
	}, "")
	return err == nil
}

func (a *agent) ensureStateDirs() error {
	for _, dir := range []string{
		"etc-kubernetes", "etcd", "kubelet", "containerd", "cni-config", "cni-bin", "longhorn",
		filepath.Join("logs", "pods"), filepath.Join("logs", "containers"),
		filepath.Join("logs", "kubernetes"), filepath.Join("logs", "journal"),
	} {
		if err := os.MkdirAll(a.path(dir), 0700); err != nil {
			return err
		}
	}
	return nil
}

func (a *agent) clearState() error {
	if _, err := a.runner.run(context.Background(), "sudo", []string{"rm", "-rf", "--", a.cfg.StateDir}, ""); err != nil {
		return err
	}
	if _, err := a.runner.run(context.Background(), "sudo", []string{
		"install", "-d", "-m", "0700",
		"-o", strconv.Itoa(os.Getuid()), "-g", strconv.Itoa(os.Getgid()),
		a.cfg.StateDir,
	}, ""); err != nil {
		return err
	}
	return a.ensureStateDirs()
}

func (a *agent) path(elements ...string) string {
	parts := append([]string{a.cfg.StateDir}, elements...)
	return filepath.Join(parts...)
}

func (a *agent) requireBootstrapSecrets() error {
	if a.cfg.BootstrapToken == "" {
		return fmt.Errorf("K8S_BOOTSTRAP_TOKEN is required")
	}
	if a.cfg.Role == "control-plane" && (a.cfg.CertificateKey == "" || a.cfg.EncryptionKey == "") {
		return fmt.Errorf("K8S_CERTIFICATE_KEY and K8S_ENCRYPTION_KEY are required for control-plane nodes")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "failed to encode response", http.StatusInternalServerError)
		return
	}
	data = append(data, '\n')
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func writeError(w http.ResponseWriter, err error) {
	log.Printf("request failed: %v", err)
	writeJSON(w, http.StatusInternalServerError, response{Status: "error", Detail: "operation failed; inspect service logs"})
}

func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s completed in %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}
