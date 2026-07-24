package nodeagent

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type config struct {
	Listen               string
	Token                string
	Role                 string
	NodeName             string
	NodeImage            string
	ContainerName        string
	StateDir             string
	ControlPlaneEndpoint string
	PodCIDR              string
	ServiceCIDR          string
	KubernetesVersion    string
	BootstrapToken       string
	CertificateKey       string
	EncryptionKey        string
}

func loadConfig() (config, error) {
	controlPlaneEndpoint := os.Getenv("K8S_CONTROL_PLANE_ENDPOINT")
	cfg := config{
		Listen:               env("K8S_AGENT_LISTEN", ":18080"),
		Token:                os.Getenv("K8S_AGENT_TOKEN"),
		Role:                 env("K8S_NODE_ROLE", "worker"),
		NodeName:             strings.ToLower(env("K8S_NODE_NAME", hostname())),
		NodeImage:            env("K8S_NODE_IMAGE", "zerops-k8s-node:v1.36.2"),
		ContainerName:        "zerops-k8s-node",
		StateDir:             filepath.Clean(env("K8S_STATE_DIR", "/var/lib/zerops-k8s")),
		ControlPlaneEndpoint: controlPlaneEndpoint,
		PodCIDR:              env("K8S_POD_CIDR", "10.244.0.0/16"),
		ServiceCIDR:          env("K8S_SERVICE_CIDR", "10.96.0.0/16"),
		KubernetesVersion:    env("K8S_VERSION", "v1.36.2"),
		BootstrapToken:       os.Getenv("K8S_BOOTSTRAP_TOKEN"),
		CertificateKey:       os.Getenv("K8S_CERTIFICATE_KEY"),
		EncryptionKey:        os.Getenv("K8S_ENCRYPTION_KEY"),
	}
	if cfg.Token == "" {
		return cfg, fmt.Errorf("K8S_AGENT_TOKEN is required")
	}
	if cfg.ControlPlaneEndpoint == "" {
		return cfg, fmt.Errorf("K8S_CONTROL_PLANE_ENDPOINT is required")
	}
	if cfg.Role != "control-plane" && cfg.Role != "worker" {
		return cfg, fmt.Errorf("K8S_NODE_ROLE must be control-plane or worker")
	}
	if cfg.NodeName == "" {
		return cfg, fmt.Errorf("K8S_NODE_NAME is required")
	}
	if !strings.HasPrefix(cfg.StateDir, "/var/lib/") {
		return cfg, fmt.Errorf("K8S_STATE_DIR must be below /var/lib")
	}
	return cfg, nil
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func hostname() string {
	host, _ := os.Hostname()
	return strings.Split(host, ".")[0]
}
