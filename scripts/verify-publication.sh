#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/release.env"

[[ "$RECIPE_RELEASE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  printf '[zerops-k8s] ERROR: RECIPE_RELEASE_REF must be a full commit SHA\n' >&2
  exit 1
}

repository=${RECIPE_REPOSITORY:-Samyazz/zerops-k8s}
files=(import.yaml import.production.yaml import.staging.yaml)
download=$(mktemp)
cleanup() {
  rm -f "$download"
}
trap cleanup EXIT

for file in "${files[@]}"; do
  url="https://raw.githubusercontent.com/$repository/$RECIPE_RELEASE_REF/$file"
  curl -q --proto '=https' --tlsv1.2 -fsSL "$url" -o "$download"
  cmp -s "$ROOT_DIR/$file" "$download" || {
    printf '[zerops-k8s] ERROR: published %s differs from the tested tree\n' "$file" >&2
    exit 1
  }
  printf '%s  %s\n' "$(sha256sum "$download" | awk '{print $1}')" "$file"
done

printf '[zerops-k8s] all immutable unauthenticated recipe imports verified\n'
