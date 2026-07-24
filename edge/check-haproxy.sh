#!/bin/sh
set -eu

pid_file=${HAPROXY_PID_FILE:-/home/zerops/haproxy.pid}
[ -s "$pid_file" ] || exit 1
pid=$(cat "$pid_file")
case "$pid" in
  ''|*[!0-9]*) exit 1 ;;
esac
kill -0 "$pid" 2>/dev/null
