package nodeagent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type upgradeRunner struct {
	commands     []recordedCommand
	kubeletReads int
	upgradeTo    string
}

func (r *upgradeRunner) run(_ context.Context, name string, args []string, _ string) (string, error) {
	r.commands = append(r.commands, recordedCommand{name: name, args: append([]string(nil), args...)})
	joined := name + " " + strings.Join(args, " ")
	switch {
	case strings.Contains(joined, "docker inspect --format"):
		return "running\n", nil
	case strings.Contains(joined, "kubelet --version"):
		r.kubeletReads++
		if r.kubeletReads > 1 && r.upgradeTo != "" {
			return "Kubernetes " + r.upgradeTo + "\n", nil
		}
		return "Kubernetes v1.36.2\n", nil
	default:
		return "", nil
	}
}

func runUpgradeRequest(t *testing.T, a *agent, body string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/cluster/upgrade", strings.NewReader(body))
	a.upgradeCluster(recorder, request)
	return recorder
}

func mustVersion(t *testing.T, value string) kubernetesVersion {
	t.Helper()
	version, err := parseKubernetesVersion(value)
	if err != nil {
		t.Fatal(err)
	}
	return version
}

func TestParseKubernetesVersion(t *testing.T) {
	for _, input := range []string{"v1.36.2", "1.36.2", "Kubernetes v1.36.2"} {
		if got := mustVersion(t, input).String(); got != "v1.36.2" {
			t.Fatalf("parse %q = %q", input, got)
		}
	}
	for _, input := range []string{"", "v1.36", "v1.036.2", "v1.36.x", "v2.0.0-rc.1"} {
		if _, err := parseKubernetesVersion(input); err == nil {
			t.Fatalf("accepted invalid version %q", input)
		}
	}
}

func TestValidateUpgradePath(t *testing.T) {
	current := mustVersion(t, "v1.36.2")
	for _, target := range []string{"v1.36.2", "v1.36.3", "v1.37.0"} {
		if err := validateUpgradePath(current, mustVersion(t, target)); err != nil {
			t.Fatalf("rejected supported path to %s: %v", target, err)
		}
	}
	for _, target := range []string{"v1.36.1", "v1.35.9", "v1.38.0", "v2.0.0"} {
		if err := validateUpgradePath(current, mustVersion(t, target)); err == nil {
			t.Fatalf("accepted unsupported path to %s", target)
		}
	}
}

func TestUpgradeAlreadyCurrentIsAnIdempotentNoOp(t *testing.T) {
	runner := &upgradeRunner{}
	a := agent{cfg: config{ContainerName: "k8s-node", NodeName: "k8scp1", Role: "control-plane"}, runner: runner}
	recorder := runUpgradeRequest(t, &a, `{"mode":"apply","targetVersion":"v1.36.2","packageVersion":"1.36.2-1.1"}`)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var got response
	if err := json.Unmarshal(recorder.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Status != "already-current" || got.CurrentVersion != "v1.36.2" || got.TargetVersion != "v1.36.2" {
		t.Fatalf("response = %#v", got)
	}
	for _, command := range runner.commands {
		if strings.Contains(strings.Join(command.args, " "), "apt-get") {
			t.Fatal("already-current request attempted a package change")
		}
	}
}

func TestUpgradeRejectsDowngradeAndPackageMismatch(t *testing.T) {
	for name, body := range map[string]string{
		"downgrade":        `{"mode":"preflight","targetVersion":"v1.36.1","packageVersion":"1.36.1-1.1"}`,
		"package mismatch": `{"mode":"preflight","targetVersion":"v1.37.0","packageVersion":"1.36.2-1.1"}`,
	} {
		t.Run(name, func(t *testing.T) {
			a := agent{cfg: config{ContainerName: "k8s-node", NodeName: "k8scp1", Role: "control-plane"}, runner: &upgradeRunner{}}
			recorder := runUpgradeRequest(t, &a, body)
			if recorder.Code != http.StatusConflict && recorder.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestWorkerApplyUsesKubeadmNodeAndVerifiesKubelet(t *testing.T) {
	runner := &upgradeRunner{upgradeTo: "v1.36.3"}
	a := agent{cfg: config{ContainerName: "k8s-node", NodeName: "k8sworker1", Role: "worker"}, runner: runner}
	recorder := runUpgradeRequest(t, &a, `{"mode":"apply","targetVersion":"v1.36.3","packageVersion":"1.36.3-1.1"}`)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	joined := make([]string, 0, len(runner.commands))
	for _, command := range runner.commands {
		joined = append(joined, command.name+" "+strings.Join(command.args, " "))
	}
	all := strings.Join(joined, "\n")
	for _, expected := range []string{
		"kubeadm upgrade node",
		"kubelet 1.36.3-1.1 36",
		"kubectl 1.36.3-1.1 36",
		"systemctl restart kubelet",
	} {
		if !strings.Contains(all, expected) {
			t.Fatalf("commands do not contain %q:\n%s", expected, all)
		}
	}
	if strings.Contains(all, "kubeadm upgrade apply") {
		t.Fatal("worker attempted the primary-control-plane apply command")
	}
	if runner.kubeletReads != 2 {
		t.Fatalf("kubelet version reads = %d, want 2", runner.kubeletReads)
	}
}
