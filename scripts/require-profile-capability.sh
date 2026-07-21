#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"

capability=${1:?usage: require-profile-capability.sh <capability>}
profile_capability "$capability" \
  || die "operation is not supported by Kubernetes profile '$K8S_PROFILE': $capability"
log "profile capability is enabled: $K8S_PROFILE/$capability"
