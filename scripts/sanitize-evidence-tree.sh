#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
evidence_dir=${1:?usage: sanitize-evidence-tree.sh EVIDENCE_DIRECTORY}
[[ -d "$evidence_dir" ]] || exit 0

while IFS= read -r -d '' evidence; do
  if [[ -s "$evidence" ]] && ! grep -Iq . "$evidence"; then
    printf '[zerops-k8s] ERROR: refusing to upload binary evidence: %s\n' "$evidence" >&2
    exit 1
  fi
  sanitized=$(mktemp)
  "$ROOT_DIR/scripts/redact-evidence.sh" <"$evidence" >"$sanitized"
  chmod --reference="$evidence" "$sanitized"
  mv "$sanitized" "$evidence"
done < <(find "$evidence_dir" -type f -print0)

printf '[zerops-k8s] sanitized every text evidence file before upload\n'
