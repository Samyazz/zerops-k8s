#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
evidence_dir=${1:?usage: sanitize-evidence-tree.sh EVIDENCE_DIRECTORY}
[[ -d "$evidence_dir" ]] || exit 0

if [[ -n $(find "$evidence_dir" ! -type d ! -type f -print -quit) ]]; then
  printf '[zerops-k8s] ERROR: refusing non-regular evidence entry\n' >&2
  exit 1
fi

while IFS= read -r -d '' evidence; do
  if [[ -s "$evidence" ]] && ! grep -Iq . "$evidence"; then
    printf '[zerops-k8s] ERROR: refusing to upload binary evidence: %s\n' "$evidence" >&2
    exit 1
  fi
  if grep -Eiq "^[[:space:]]*kind:[[:space:]]*['\"]?Secret(List)?['\"]?[[:space:]]*(#.*)?$" "$evidence"; then
    printf '[zerops-k8s] ERROR: refusing Kubernetes Secret evidence: %s\n' "$evidence" >&2
    exit 1
  fi
  sanitized=$(mktemp)
  document_mode=--document
  case "$evidence" in
    *.yaml|*.yml) document_mode=--yaml-document ;;
  esac
  "$ROOT_DIR/scripts/redact-evidence.sh" "$document_mode" <"$evidence" >"$sanitized"
  chmod --reference="$evidence" "$sanitized"
  mv "$sanitized" "$evidence"
done < <(find "$evidence_dir" -type f -print0)

printf '[zerops-k8s] sanitized every text evidence file before upload\n'
