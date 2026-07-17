#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

sudo apt-get update
sudo apt-get install -y --no-install-recommends ca-certificates curl jq ripgrep wireguard-tools awscli

tmp=$(mktemp -d)

curl -fsSLo "$tmp/zcli" "https://github.com/zeropsio/zcli/releases/download/v${ZCLI_VERSION}/zcli-linux-amd64"
printf '%s  %s\n' '5844f303aa339943518bf48ece58340cdefb75125646c4cc7e85979a8109e95c' "$tmp/zcli" | sha256sum -c -
sudo install -m 0755 "$tmp/zcli" /usr/local/bin/zcli

curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLo "$tmp/kubectl.sha256" "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl.sha256"
printf '%s  %s\n' "$(<"$tmp/kubectl.sha256")" "$tmp/kubectl" | sha256sum -c -
sudo install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl

curl -fsSLo "$tmp/helm.tar.gz" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp/helm.sha256" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
(cd "$tmp" && sha256sum -c helm.sha256)
tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
sudo install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm

curl -fsSLo "$tmp/istio.tar.gz" "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp/istio.sha256" "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz.sha256"
printf '%s  %s\n' "$(<"$tmp/istio.sha256")" "$tmp/istio.tar.gz" | sha256sum -c -
tar -xzf "$tmp/istio.tar.gz" -C "$tmp"
sudo install -m 0755 "$tmp/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl

curl -fsSLo "$tmp/sonobuoy.tar.gz" "https://github.com/vmware-tanzu/sonobuoy/releases/download/v${SONOBUOY_VERSION}/sonobuoy_${SONOBUOY_VERSION}_linux_amd64.tar.gz"
curl -fsSLo "$tmp/sonobuoy.sha256" "https://github.com/vmware-tanzu/sonobuoy/releases/download/v${SONOBUOY_VERSION}/sonobuoy_${SONOBUOY_VERSION}_checksums.txt"
(cd "$tmp" && rg "sonobuoy_${SONOBUOY_VERSION}_linux_amd64.tar.gz$" sonobuoy.sha256 | sha256sum -c -)
tar -xzf "$tmp/sonobuoy.tar.gz" -C "$tmp" sonobuoy
sudo install -m 0755 "$tmp/sonobuoy" /usr/local/bin/sonobuoy

curl -fsSLo "$tmp/kubescape_${KUBESCAPE_VERSION}_linux_amd64" "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/kubescape_${KUBESCAPE_VERSION}_linux_amd64"
curl -fsSLo "$tmp/kubescape.sha256" "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/checksums.sha256"
(cd "$tmp" && rg " kubescape_${KUBESCAPE_VERSION}_linux_amd64$" kubescape.sha256 | sha256sum -c -)
mv "$tmp/kubescape_${KUBESCAPE_VERSION}_linux_amd64" "$tmp/kubescape"
sudo install -m 0755 "$tmp/kubescape" /usr/local/bin/kubescape

curl -fsSLo "$tmp/kubeconform.tar.gz" "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz"
curl -fsSLo "$tmp/kubeconform.sha256" "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/CHECKSUMS"
(cd "$tmp" && rg ' kubeconform-linux-amd64.tar.gz$' kubeconform.sha256 | sha256sum -c -)
tar -xzf "$tmp/kubeconform.tar.gz" -C "$tmp" kubeconform
sudo install -m 0755 "$tmp/kubeconform" /usr/local/bin/kubeconform

zcli version
kubectl version --client
helm version --short
istioctl version --remote=false
sonobuoy version
kubescape version
kubeconform -v
