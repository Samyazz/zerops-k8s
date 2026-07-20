#!/usr/bin/env bash

# Shared builder for the exact committed node-agent artifact. Callers must
# source scripts/lib.sh first; this file deliberately exposes the three
# NODE_AGENT_* variables after prepare_node_agent_artifact succeeds.
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

# shellcheck disable=SC2034 # Public outputs consumed by sourcing scripts.
NODE_AGENT_SOURCE_REVISION=
NODE_AGENT_VERSION_NAME=
NODE_AGENT_ARTIFACT_DIR=

prepare_node_agent_artifact() {
  local tool_root archive tmp go_bin current_version artifact_parent

  require curl
  require sha256sum
  require tar
  require_env GO_VERSION GO_LINUX_AMD64_SHA256

  if [[ -d "$ROOT_DIR/.git" ]]; then
    NODE_AGENT_SOURCE_REVISION=${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}
  else
    die 'a committed Git checkout is required to assemble the reviewed node-agent artifact'
  fi
  # shellcheck disable=SC2034 # Public output consumed by sourcing scripts.
  NODE_AGENT_VERSION_NAME="github-${GITHUB_RUN_ID:-local}-${NODE_AGENT_SOURCE_REVISION:0:12}-node-agent"

  tool_root="${RUNNER_TEMP:-/tmp}/zerops-k8s-go-${GO_VERSION}"
  go_bin="$tool_root/bin/go"
  if [[ ! -x "$go_bin" ]]; then
    tmp=$(mktemp -d)
    archive="$tmp/go${GO_VERSION}.linux-amd64.tar.gz"
    log "installing the pinned Go ${GO_VERSION} toolchain for the reviewed node-agent artifact"
    curl -fsSLo "$archive" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    printf '%s  %s\n' "$GO_LINUX_AMD64_SHA256" "$archive" | sha256sum -c -
    mkdir -p "$tool_root"
    tar -xzf "$archive" -C "$tool_root" --strip-components=1
    rm -rf "$tmp"
  fi
  current_version=$($go_bin version | awk '{print $3}')
  [[ "$current_version" == "go${GO_VERSION}" ]] \
    || die "pinned Go toolchain mismatch: expected go${GO_VERSION}, got $current_version"

  artifact_parent="${RUNNER_TEMP:-/tmp}/zerops-k8s-agent-${NODE_AGENT_SOURCE_REVISION:0:12}"
  NODE_AGENT_ARTIFACT_DIR="$artifact_parent/runtime"
  if [[ ! -x "$NODE_AGENT_ARTIFACT_DIR/dist/zerops-k8s" || ! -x "$NODE_AGENT_ARTIFACT_DIR/s3-fetch" ]]; then
    mkdir -p "$NODE_AGENT_ARTIFACT_DIR"
    git -C "$ROOT_DIR" archive --format=tar "$NODE_AGENT_SOURCE_REVISION" \
      | tar -xf - -C "$NODE_AGENT_ARTIFACT_DIR"
    mkdir -p "$NODE_AGENT_ARTIFACT_DIR/dist"
    (
      cd "$NODE_AGENT_ARTIFACT_DIR" || exit
      CGO_ENABLED=0 "$go_bin" test ./...
      CGO_ENABLED=0 "$go_bin" build -trimpath -ldflags='-s -w' -o dist/zerops-k8s ./cmd/zerops-k8s
      CGO_ENABLED=0 "$go_bin" build -trimpath -ldflags='-s -w' -o s3-fetch ./cmd/s3-fetch
    )
  fi

  mkdir -p "${RUNNER_TEMP:-/tmp}/evidence"
  (
    cd "$NODE_AGENT_ARTIFACT_DIR" || exit
    sha256sum dist/zerops-k8s s3-fetch
  ) >"${RUNNER_TEMP:-/tmp}/evidence/node-agent-artifact.sha256"
}
