#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates curl jq shellcheck
elif command -v apk >/dev/null 2>&1; then
  missing=()
  command -v bash >/dev/null 2>&1 || missing+=(bash)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  ((${#missing[@]} == 0)) || sudo apk add --no-cache ca-certificates "${missing[@]}"
else
  printf 'unsupported package manager: install curl, jq, and tar first\n' >&2
  exit 1
fi

tmp=$(mktemp -d)

if ! command -v jq >/dev/null 2>&1; then
  curl -fsSLo "$tmp/jq" "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
  curl -fsSLo "$tmp/jq.sha256" "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/sha256sum.txt"
  (cd "$tmp" && grep ' jq-linux-amd64$' jq.sha256 | sha256sum -c -)
  sudo install -m 0755 "$tmp/jq" /usr/local/bin/jq
fi

curl -fsSLo "$tmp/zcli" "https://github.com/zeropsio/zcli/releases/download/v${ZCLI_VERSION}/zcli-linux-amd64"
printf '%s  %s\n' '5844f303aa339943518bf48ece58340cdefb75125646c4cc7e85979a8109e95c' "$tmp/zcli" | sha256sum -c -
sudo install -m 0755 "$tmp/zcli" /usr/local/bin/zcli

curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLo "$tmp/kubectl.sha256" "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl.sha256"
printf '%s  %s\n' "$(<"$tmp/kubectl.sha256")" "$tmp/kubectl" | sha256sum -c -
sudo install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl

helm_archive="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp/$helm_archive" "https://get.helm.sh/$helm_archive"
curl -fsSLo "$tmp/helm.sha256" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
(cd "$tmp" && sha256sum -c helm.sha256)
tar -xzf "$tmp/$helm_archive" -C "$tmp"
sudo install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm

istio_archive="istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp/$istio_archive" "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/$istio_archive"
curl -fsSLo "$tmp/istio.sha256" "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz.sha256"
(cd "$tmp" && sha256sum -c istio.sha256)
tar -xzf "$tmp/$istio_archive" -C "$tmp"
sudo install -m 0755 "$tmp/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl

sonobuoy_archive="sonobuoy_${SONOBUOY_VERSION}_linux_amd64.tar.gz"
curl -fsSLo "$tmp/$sonobuoy_archive" "https://github.com/vmware-tanzu/sonobuoy/releases/download/v${SONOBUOY_VERSION}/$sonobuoy_archive"
curl -fsSLo "$tmp/sonobuoy.sha256" "https://github.com/vmware-tanzu/sonobuoy/releases/download/v${SONOBUOY_VERSION}/sonobuoy_${SONOBUOY_VERSION}_checksums.txt"
(cd "$tmp" && grep "sonobuoy_${SONOBUOY_VERSION}_linux_amd64.tar.gz$" sonobuoy.sha256 | sha256sum -c -)
tar -xzf "$tmp/$sonobuoy_archive" -C "$tmp" sonobuoy
sudo install -m 0755 "$tmp/sonobuoy" /usr/local/bin/sonobuoy

curl -fsSLo "$tmp/kubescape_${KUBESCAPE_VERSION}_linux_amd64" "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/kubescape_${KUBESCAPE_VERSION}_linux_amd64"
curl -fsSLo "$tmp/kubescape.sha256" "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/checksums.sha256"
(cd "$tmp" && grep " kubescape_${KUBESCAPE_VERSION}_linux_amd64$" kubescape.sha256 | sha256sum -c -)
mv "$tmp/kubescape_${KUBESCAPE_VERSION}_linux_amd64" "$tmp/kubescape"
sudo install -m 0755 "$tmp/kubescape" /usr/local/bin/kubescape

kubeconform_archive=kubeconform-linux-amd64.tar.gz
curl -fsSLo "$tmp/$kubeconform_archive" "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/$kubeconform_archive"
curl -fsSLo "$tmp/kubeconform.sha256" "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/CHECKSUMS"
(cd "$tmp" && grep ' kubeconform-linux-amd64.tar.gz$' kubeconform.sha256 | sha256sum -c -)
tar -xzf "$tmp/$kubeconform_archive" -C "$tmp" kubeconform
sudo install -m 0755 "$tmp/kubeconform" /usr/local/bin/kubeconform

zcli version
kubectl version --client
helm version --short
istioctl version --remote=false
sonobuoy version
kubescape version
kubeconform -v
