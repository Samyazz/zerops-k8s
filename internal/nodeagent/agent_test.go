package nodeagent

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

type recordedCommand struct {
	name string
	args []string
}

type recordingRunner struct {
	commands []recordedCommand
	failAt   int
}

func (r *recordingRunner) run(_ context.Context, name string, args []string, _ string) (string, error) {
	r.commands = append(r.commands, recordedCommand{name: name, args: append([]string(nil), args...)})
	if r.failAt > 0 && len(r.commands) == r.failAt {
		return "", errors.New("test failure")
	}
	return "", nil
}

type scriptedResult struct {
	out string
	err error
}

type scriptedRunner struct {
	commands []recordedCommand
	results  []scriptedResult
}

func (r *scriptedRunner) run(_ context.Context, name string, args []string, _ string) (string, error) {
	r.commands = append(r.commands, recordedCommand{name: name, args: append([]string(nil), args...)})
	if len(r.results) == 0 {
		return "", errors.New("unexpected command")
	}
	result := r.results[0]
	r.results = r.results[1:]
	return result.out, result.err
}

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

func TestInitConfigUsesVRRPIPWithoutPortForCertificateSAN(t *testing.T) {
	a := agent{cfg: config{
		BootstrapToken:       "123456.1234567890123456",
		NodeName:             "k8scp1",
		CertificateKey:       strings.Repeat("a", 64),
		KubernetesVersion:    "v1.36.2",
		ControlPlaneEndpoint: "10.0.71.222:6443",
		PodCIDR:              "10.244.0.0/16",
		ServiceCIDR:          "10.96.0.0/16",
	}}
	config := a.initConfig("10.0.0.1")
	if !strings.Contains(config, "controlPlaneEndpoint: 10.0.71.222:6443") {
		t.Fatal("control-plane endpoint lost its API port")
	}
	if strings.Contains(config, "    - 10.0.71.222:6443") {
		t.Fatal("certificate SAN must not contain a port")
	}
	for _, san := range []string{"k8sedge", "k8sedge.zerops", "10.0.71.222", "10.0.0.1"} {
		if !strings.Contains(config, "    - "+san+"\n") {
			t.Fatalf("certificate SAN is missing %s", san)
		}
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

func TestLoadConfigUsesVRRPControlPlaneEndpoint(t *testing.T) {
	t.Setenv("K8S_AGENT_TOKEN", "test-token")
	t.Setenv("K8S_NODE_NAME", "k8scp1")
	t.Setenv("K8S_CONTROL_PLANE_ENDPOINT", "10.0.71.222:6443")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ControlPlaneEndpoint != "10.0.71.222:6443" {
		t.Fatalf("control-plane endpoint = %q", cfg.ControlPlaneEndpoint)
	}
}

func TestEnsureHostMountPropagationRepairsRootAndSysfs(t *testing.T) {
	runner := &recordingRunner{}
	a := agent{runner: runner}
	if err := a.ensureHostMountPropagation(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []recordedCommand{
		{name: "sudo", args: []string{"mount", "--make-rshared", "/"}},
		{name: "sudo", args: []string{"mount", "--make-rshared", "/sys"}},
	}
	if !reflect.DeepEqual(runner.commands, want) {
		t.Fatalf("mount propagation commands = %#v, want %#v", runner.commands, want)
	}
}

func TestEnsureHostMountPropagationStopsOnFailure(t *testing.T) {
	runner := &recordingRunner{failAt: 1}
	a := agent{runner: runner}
	err := a.ensureHostMountPropagation(context.Background())
	if err == nil || !strings.Contains(err.Error(), "make outer mount recursively shared (/)") {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(runner.commands) != 1 {
		t.Fatalf("commands after failure = %d, want 1", len(runner.commands))
	}
}

func TestStopNodeQuiescesNestedServicesWithoutStoppingWrapper(t *testing.T) {
	stateDir := t.TempDir()
	runner := &scriptedRunner{results: []scriptedResult{
		{out: "running\n"},
		{},
	}}
	a := agent{cfg: config{ContainerName: "nested-node", StateDir: stateDir}, runner: runner}
	recorder := httptest.NewRecorder()
	a.stopNode(recorder, httptest.NewRequest(http.MethodPost, "/v1/node/stop", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), `"status":"quiesced"`) {
		t.Fatalf("body = %s", recorder.Body.String())
	}
	if !a.nodeIsQuiesced() {
		t.Fatal("quiesced marker was not persisted")
	}
	for _, command := range runner.commands {
		if command.name == "docker" && len(command.args) > 0 && (command.args[0] == "stop" || command.args[0] == "kill") {
			t.Fatalf("wrapper lifecycle command was used: %#v", command)
		}
	}
}

func TestStopNodeIsIdempotentWhileQuiesced(t *testing.T) {
	stateDir := t.TempDir()
	a := agent{cfg: config{ContainerName: "nested-node", StateDir: stateDir}, runner: &scriptedRunner{}}
	if err := a.setNodeQuiesced(true); err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	a.stopNode(recorder, httptest.NewRequest(http.MethodPost, "/v1/node/stop", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), `"status":"quiesced"`) {
		t.Fatalf("body = %s", recorder.Body.String())
	}
}

func TestStartNodeRevivesPersistedQuiescedWrapper(t *testing.T) {
	stateDir := t.TempDir()
	runner := &scriptedRunner{results: []scriptedResult{
		{},
		{},
		{out: "running\n"},
		{},
		{},
		{},
		{},
	}}
	a := agent{cfg: config{ContainerName: "nested-node", StateDir: stateDir}, runner: runner}
	if err := a.setNodeQuiesced(true); err != nil {
		t.Fatal(err)
	}
	if err := a.startNodeLocked(context.Background()); err != nil {
		t.Fatal(err)
	}
	if a.nodeIsQuiesced() {
		t.Fatal("quiesced marker remained after successful node revival")
	}
	for _, want := range []recordedCommand{
		{name: "docker", args: []string{"exec", "nested-node", "systemctl", "start", "containerd"}},
		{name: "docker", args: []string{"exec", "nested-node", "systemctl", "restart", "kubelet"}},
	} {
		if !containsRecordedCommand(runner.commands, want) {
			t.Fatalf("commands = %#v, missing %#v", runner.commands, want)
		}
	}
}

func containsRecordedCommand(commands []recordedCommand, want recordedCommand) bool {
	for _, command := range commands {
		if reflect.DeepEqual(command, want) {
			return true
		}
	}
	return false
}
