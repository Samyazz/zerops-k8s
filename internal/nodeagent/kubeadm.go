package nodeagent

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"regexp"
	"strings"
)

var caHashPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

func (a *agent) writeControlPlaneFiles() error {
	auditPolicy := `apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
  - level: Metadata
`
	key := a.cfg.EncryptionKey
	if decoded, err := base64.StdEncoding.DecodeString(key); err == nil && len(decoded) == 32 {
		key = base64.StdEncoding.EncodeToString(decoded)
	} else if raw, err := hex.DecodeString(key); err == nil && len(raw) == 32 {
		key = base64.StdEncoding.EncodeToString(raw)
	} else if len(key) == 32 {
		key = base64.StdEncoding.EncodeToString([]byte(key))
	} else {
		return fmt.Errorf("K8S_ENCRYPTION_KEY must encode exactly 32 bytes")
	}
	encryptionConfig := fmt.Sprintf(`apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: zerops-project-secret
              secret: %s
      - identity: {}
`, key)
	if err := os.WriteFile(a.path("etc-kubernetes", "audit-policy.yaml"), []byte(auditPolicy), 0600); err != nil {
		return err
	}
	return os.WriteFile(a.path("etc-kubernetes", "encryption-config.yaml"), []byte(encryptionConfig), 0600)
}

func (a *agent) initConfig(ip string) string {
	return fmt.Sprintf(`apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens:
  - token: %s
    ttl: 0s
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: %s
  kubeletExtraArgs:
    - name: node-ip
      value: %s
localAPIEndpoint:
  advertiseAddress: %s
  bindPort: 6443
certificateKey: %s
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: zerops-k8s
kubernetesVersion: %s
controlPlaneEndpoint: %s
networking:
  dnsDomain: cluster.local
  podSubnet: %s
  serviceSubnet: %s
apiServer:
  certSANs:
    - k8sedge
    - k8sedge.zerops
    - %s
    - %s
  extraArgs:
    - name: audit-policy-file
      value: /etc/kubernetes/audit-policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "1"
    - name: audit-log-maxbackup
      value: "1"
    - name: audit-log-maxsize
      value: "100"
    - name: encryption-provider-config
      value: /etc/kubernetes/encryption-config.yaml
    - name: profiling
      value: "false"
    - name: request-timeout
      value: 60s
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
      pathType: File
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption-config.yaml
      mountPath: /etc/kubernetes/encryption-config.yaml
      readOnly: true
      pathType: File
    - name: audit-log
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
    - name: profiling
      value: "false"
scheduler:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
    - name: profiling
      value: "false"
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: http://0.0.0.0:2381
`, a.cfg.BootstrapToken, a.cfg.NodeName, ip, ip, a.cfg.CertificateKey, a.cfg.KubernetesVersion, a.cfg.ControlPlaneEndpoint, a.cfg.PodCIDR, a.cfg.ServiceCIDR, a.cfg.ControlPlaneEndpoint, ip)
}

func (a *agent) joinConfig(ip, caHash string) string {
	controlPlane := ""
	if a.cfg.Role == "control-plane" {
		controlPlane = fmt.Sprintf(`controlPlane:
  certificateKey: %s
  localAPIEndpoint:
    advertiseAddress: %s
    bindPort: 6443
`, a.cfg.CertificateKey, ip)
	}
	return fmt.Sprintf(`apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: %s
    token: %s
    caCertHashes:
      - %s
    unsafeSkipCAVerification: false
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: %s
  kubeletExtraArgs:
    - name: node-ip
      value: %s
%s`, a.cfg.ControlPlaneEndpoint, a.cfg.BootstrapToken, caHash, a.cfg.NodeName, ip, controlPlane)
}

func (a *agent) caHash(ctx context.Context) (string, error) {
	command := "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'"
	out, err := a.runner.run(ctx, "docker", []string{"exec", a.cfg.ContainerName, "sh", "-ec", command}, "")
	if err != nil {
		return "", err
	}
	hash := "sha256:" + strings.TrimSpace(out)
	if !validCAHash(hash) {
		return "", fmt.Errorf("computed invalid CA hash")
	}
	return hash, nil
}

func validCAHash(value string) bool {
	return caHashPattern.MatchString(value)
}

func primaryIPv4() (string, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			var ip net.IP
			switch value := address.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip == nil || ip.IsLoopback() || ip.To4() == nil {
				continue
			}
			return ip.String(), nil
		}
	}
	return "", fmt.Errorf("no non-loopback IPv4 address found")
}
