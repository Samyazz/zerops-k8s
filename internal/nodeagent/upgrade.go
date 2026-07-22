package nodeagent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var packageVersionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$`)

type kubernetesVersion struct {
	major int
	minor int
	patch int
}

func (v kubernetesVersion) String() string {
	return fmt.Sprintf("v%d.%d.%d", v.major, v.minor, v.patch)
}

func parseKubernetesVersion(value string) (kubernetesVersion, error) {
	value = strings.TrimSpace(strings.TrimPrefix(value, "Kubernetes "))
	value = strings.TrimPrefix(value, "v")
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return kubernetesVersion{}, fmt.Errorf("Kubernetes version must contain major, minor, and patch")
	}
	values := make([]int, 3)
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return kubernetesVersion{}, fmt.Errorf("Kubernetes version component is not canonical")
		}
		parsed, err := strconv.Atoi(part)
		if err != nil || parsed < 0 {
			return kubernetesVersion{}, fmt.Errorf("Kubernetes version contains a non-numeric component")
		}
		values[index] = parsed
	}
	return kubernetesVersion{major: values[0], minor: values[1], patch: values[2]}, nil
}

func validateUpgradePath(current, target kubernetesVersion) error {
	if target.major != current.major {
		return fmt.Errorf("Kubernetes major-version changes are not supported")
	}
	if target.minor < current.minor || target.minor > current.minor+1 {
		return fmt.Errorf("Kubernetes upgrades must stay within the current minor or advance exactly one minor")
	}
	if target.minor == current.minor && target.patch < current.patch {
		return fmt.Errorf("Kubernetes downgrades are not supported")
	}
	return nil
}

type upgradeRequest struct {
	Mode           string `json:"mode"`
	TargetVersion  string `json:"targetVersion"`
	PackageVersion string `json:"packageVersion"`
}

func (a *agent) nestedKubeletVersion(ctx context.Context) (kubernetesVersion, error) {
	output, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "kubelet", "--version",
	}, "")
	if err != nil {
		return kubernetesVersion{}, fmt.Errorf("read nested kubelet version: %w", err)
	}
	return parseKubernetesVersion(output)
}

func (a *agent) installKubernetesPackage(ctx context.Context, packageName, packageVersion string, minor int) error {
	if packageName != "kubeadm" && packageName != "kubelet" && packageName != "kubectl" {
		return fmt.Errorf("unsupported Kubernetes package")
	}
	script := `
set -eu
package_name=$1
package_version=$2
minor=$3
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' "$minor" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update >/dev/null
apt-mark unhold "$package_name" >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-change-held-packages \
  "${package_name}=${package_version}" >/dev/null
apt-mark hold "$package_name" >/dev/null
`
	_, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "sh", "-ec", script, "--",
		packageName, packageVersion, strconv.Itoa(minor),
	}, "")
	if err != nil {
		return fmt.Errorf("install nested %s package: %w", packageName, err)
	}
	return nil
}

func (a *agent) upgradeCluster(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()

	var request upgradeRequest
	decoder := json.NewDecoder(io.LimitReader(r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if request.Mode != "preflight" && request.Mode != "plan" && request.Mode != "apply" {
		http.Error(w, "mode must be preflight, plan, or apply", http.StatusBadRequest)
		return
	}
	target, err := parseKubernetesVersion(request.TargetVersion)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if !packageVersionPattern.MatchString(request.PackageVersion) ||
		!strings.HasPrefix(request.PackageVersion, strings.TrimPrefix(target.String(), "v")+"-") {
		http.Error(w, "packageVersion must be the pinned Debian package for targetVersion", http.StatusBadRequest)
		return
	}
	if err := a.startNodeLocked(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	current, err := a.nestedKubeletVersion(r.Context())
	if err != nil {
		writeError(w, err)
		return
	}
	if err := validateUpgradePath(current, target); err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	if current == target {
		writeJSON(w, http.StatusOK, response{
			Status: "already-current", CurrentVersion: current.String(), TargetVersion: target.String(),
		})
		return
	}
	if request.Mode == "preflight" {
		writeJSON(w, http.StatusOK, response{
			Status: "upgrade-path-valid", CurrentVersion: current.String(), TargetVersion: target.String(),
		})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()
	if request.Mode == "plan" && (a.cfg.Role != "control-plane" || a.cfg.NodeName != "k8scp1") {
		http.Error(w, "kubeadm upgrade plan is restricted to k8scp1", http.StatusForbidden)
		return
	}
	if err := a.installKubernetesPackage(ctx, "kubeadm", request.PackageVersion, target.minor); err != nil {
		writeError(w, err)
		return
	}
	if request.Mode == "plan" {
		if _, err := a.runner.run(ctx, "docker", []string{
			"exec", a.cfg.ContainerName, "kubeadm", "upgrade", "plan", target.String(),
			"--ignore-preflight-errors=SystemVerification",
		}, ""); err != nil {
			writeError(w, fmt.Errorf("run kubeadm upgrade plan: %w", err))
			return
		}
		writeJSON(w, http.StatusOK, response{
			Status: "upgrade-plan-valid", CurrentVersion: current.String(), TargetVersion: target.String(),
		})
		return
	}
	if a.cfg.Role == "control-plane" && a.cfg.NodeName == "k8scp1" {
		_, err = a.runner.run(ctx, "docker", []string{
			"exec", a.cfg.ContainerName, "kubeadm", "upgrade", "apply", target.String(),
			"--yes", "--ignore-preflight-errors=SystemVerification",
		}, "")
	} else {
		_, err = a.runner.run(ctx, "docker", []string{
			"exec", a.cfg.ContainerName, "kubeadm", "upgrade", "node",
			"--ignore-preflight-errors=SystemVerification",
		}, "")
	}
	if err != nil {
		writeError(w, fmt.Errorf("run kubeadm upgrade on %s: %w", a.cfg.NodeName, err))
		return
	}
	if a.cfg.Role == "control-plane" {
		if _, err := a.ensureAPIServerDSRSAN(ctx); err != nil {
			writeError(w, fmt.Errorf("restore DSR API certificate SAN after upgrade: %w", err))
			return
		}
	}
	for _, packageName := range []string{"kubelet", "kubectl"} {
		if err := a.installKubernetesPackage(ctx, packageName, request.PackageVersion, target.minor); err != nil {
			writeError(w, err)
			return
		}
	}
	if _, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "systemctl", "daemon-reload",
	}, ""); err != nil {
		writeError(w, fmt.Errorf("reload nested systemd: %w", err))
		return
	}
	if _, err := a.runner.run(ctx, "docker", []string{
		"exec", a.cfg.ContainerName, "systemctl", "restart", "kubelet",
	}, ""); err != nil {
		writeError(w, fmt.Errorf("restart upgraded kubelet: %w", err))
		return
	}
	updated, err := a.nestedKubeletVersion(ctx)
	if err != nil || updated != target {
		writeError(w, fmt.Errorf("nested kubelet did not report the target version after upgrade"))
		return
	}
	writeJSON(w, http.StatusOK, response{
		Status: "upgraded", CurrentVersion: updated.String(), TargetVersion: target.String(),
	})
}
