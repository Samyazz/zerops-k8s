#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

# Operation output stays streaming and bounded in memory. Evidence files pass
# --document so pretty-printed JSON is parsed as one structure before the same
# fallback stream filter handles NDJSON or text.
exec python3 "$ROOT_DIR/scripts/redact_stream.py" "$@"
