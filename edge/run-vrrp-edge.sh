#!/bin/sh
set -eu

script_dir=$(
  unset CDPATH
  cd -- "$(dirname "$0")"
  pwd
)
haproxy_config=${HAPROXY_CONFIG_PATH:-/home/zerops/haproxy.cfg}
keepalived_config=${KEEPALIVED_CONFIG_PATH:-/home/zerops/keepalived.conf}
haproxy_pid_file=${HAPROXY_PID_FILE:-/home/zerops/haproxy.pid}
haproxy_pid=
keepalived_pid=

# shellcheck disable=SC2317 # Invoked through the signal/EXIT trap below.
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$keepalived_pid" ] && kill -0 "$keepalived_pid" 2>/dev/null; then
    sudo kill -TERM "$keepalived_pid" 2>/dev/null || true
    wait "$keepalived_pid" 2>/dev/null || true
  fi
  if [ -n "$haproxy_pid" ] && kill -0 "$haproxy_pid" 2>/dev/null; then
    kill -TERM "$haproxy_pid" 2>/dev/null || true
    wait "$haproxy_pid" 2>/dev/null || true
  fi
  rm -f "$haproxy_pid_file"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

KEEPALIVED_CONFIG_PATH=$keepalived_config "$script_dir/render-keepalived-config.sh" >/dev/null
K8S_VRRP_VIP=$(cat "${K8S_VRRP_STATE_PATH:-/home/zerops/vrrp-vip}")
export K8S_VRRP_VIP
HAPROXY_CONFIG_PATH=$haproxy_config "$script_dir/render-haproxy-config.sh" >/dev/null
haproxy -c -f "$haproxy_config"
sudo keepalived --config-test --use-file="$keepalived_config"

rm -f "$haproxy_pid_file"
haproxy -db -p "$haproxy_pid_file" -f "$haproxy_config" &
haproxy_pid=$!
for _ in 1 2 3 4 5; do
  [ -s "$haproxy_pid_file" ] && kill -0 "$haproxy_pid" 2>/dev/null && break
  sleep 0.2
done
"$script_dir/check-haproxy.sh"

printf '{"component":"vrrp-haproxy-edge","status":"starting","vip":"%s"}\n' \
  "$K8S_VRRP_VIP"
sudo keepalived --dont-fork --log-console --log-detail --dont-respawn \
  --release-vips --use-file="$keepalived_config" &
keepalived_pid=$!

while kill -0 "$haproxy_pid" 2>/dev/null && kill -0 "$keepalived_pid" 2>/dev/null; do
  sleep 1
done
printf '%s\n' '{"component":"vrrp-haproxy-edge","status":"component-exited"}' >&2
exit 1
