#!/bin/sh
set -eu

script_dir=$(
  unset CDPATH
  cd -- "$(dirname "$0")"
  pwd
)
config_path=${HAPROXY_CONFIG_PATH:-/home/zerops/haproxy.cfg}
HAPROXY_CONFIG_PATH=$config_path "$script_dir/render-haproxy-config.sh" >/dev/null
haproxy -c -f "$config_path"
printf '%s\n' '{"component":"haproxy-edge","status":"starting","dsr":"_dsr.k8sedge.zerops:6443"}'
exec haproxy -db -f "$config_path"
