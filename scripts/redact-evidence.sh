#!/usr/bin/env bash
set -Eeuo pipefail

# Evidence may contain application log lines rather than valid JSON, so redact as
# a byte stream before parsing or archiving it. The patterns intentionally favor
# false positives over leaking credentials or personal data.
sed -E \
  -e "s/(Authorization[\"':= ]+)(Bearer[[:space:]]+)?[^,\"'[:space:]]+/\1[REDACTED]/Ig" \
  -e "s/(Cookie[\"':= ]+)[^,\"'[:space:]]+/\1[REDACTED]/Ig" \
  -e "s/(Set-Cookie[\"':= ]+)[^,\"'[:space:]]+/\1[REDACTED]/Ig" \
  -e "s/(token|password|secret)([\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^,\"'[:space:]]+/\1\2[REDACTED]/Ig" \
  -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[REDACTED_EMAIL]/g' \
  -e 's/(^|[^[:digit:]])(([0-9]{1,3}\.){3}[0-9]{1,3})([^[:digit:]]|$)/\1[REDACTED_IP]\4/g'
