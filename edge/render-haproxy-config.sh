#!/bin/sh
set -eu

config_path=${HAPROXY_CONFIG_PATH:-/home/zerops/haproxy.cfg}
dsr_hostname=${K8S_DSR_HOSTNAME:-_dsr.k8sedge.zerops}
dns_server=${K8S_EDGE_DNS_SERVER:-$(awk '$1 == "nameserver" {print $2; exit}' /etc/resolv.conf)}

case "$dns_server" in
  ''|*[!0-9.]*)
    printf 'K8S_EDGE_DNS_SERVER must be an IPv4 address\n' >&2
    exit 1
    ;;
esac

bool_value() {
  key=$1
  fallback=$2
  eval "value=\${$key:-}"
  # shellcheck disable=SC2154 # Assigned through the reviewed indirect expansion above.
  case "$value" in
    '') printf '%s\n' "$fallback" ;;
    1|true|TRUE|yes|YES|on|ON) printf 'true\n' ;;
    0|false|FALSE|no|NO|off|OFF) printf 'false\n' ;;
    *) printf '%s must be a boolean\n' "$key" >&2; exit 1 ;;
  esac
}

write_servers() {
  prefix=$1
  backends=$2
  check_options=$3
  old_ifs=$IFS
  IFS=,
  # Intentional word splitting turns the reviewed comma-separated value into
  # individual HAProxy server declarations.
  # shellcheck disable=SC2086
  set -- $backends
  IFS=$old_ifs
  [ "$#" -gt 0 ] || {
    printf '%s backend list must not be empty\n' "$prefix" >&2
    exit 1
  }

  index=1
  for backend do
    host=${backend%:*}
    port=${backend##*:}
    case "$host" in
      ''|*[!A-Za-z0-9.-]*)
        printf 'invalid backend hostname: %s\n' "$host" >&2
        exit 1
        ;;
    esac
    case "$port" in
      ''|*[!0-9]*)
        printf 'invalid backend port: %s\n' "$port" >&2
        exit 1
        ;;
    esac
    if ! { [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null; }; then
      printf 'backend port is outside 1-65535: %s\n' "$port" >&2
      exit 1
    fi
    printf '    server %s%d %s:%s check %s resolvers zerops_dns resolve-prefer ipv4 init-addr libc,none\n' \
      "$prefix" "$index" "$host" "$port" "$check_options"
    index=$((index + 1))
  done
}

api_enabled=$(bool_value K8S_EDGE_API_ENABLED true)
ingress_enabled=$(bool_value K8S_EDGE_INGRESS_ENABLED true)
headlamp_enabled=$(bool_value K8S_EDGE_HEADLAMP_ENABLED true)

[ "$api_enabled" = true ] || {
  printf 'K8S_EDGE_API_ENABLED must remain true for the DSR control-plane endpoint\n' >&2
  exit 1
}

umask 077
{
  cat <<EOF
# Generated at container start. The stable client endpoint is
# https://${dsr_hostname}:6443 and is owned by the Zerops service DSR layer.
global
    log stdout format raw local0 info
    maxconn 4096
    stats socket /home/zerops/haproxy-runtime.sock mode 600 level admin

resolvers zerops_dns
    nameserver zerops ${dns_server}:53
    resolve_retries 3
    timeout resolve 1s
    timeout retry 1s
    hold valid 5s
    hold obsolete 5s

defaults
    log global
    option dontlognull
    timeout connect 3s
    timeout client 1h
    timeout server 1h
    timeout check 3s
    retries 3

frontend kubernetes_api
    bind 0.0.0.0:6443
    mode tcp
    option tcplog
    default_backend kubernetes_api_backends

backend kubernetes_api_backends
    mode tcp
    balance roundrobin
    option httpchk GET /readyz HTTP/1.1
    http-check send hdr Host k8sedge.zerops
    http-check expect status 200
EOF
  write_servers cp "${K8S_EDGE_API_BACKENDS:-k8scp1.zerops:6443,k8scp2.zerops:6443,k8scp3.zerops:6443}" \
    'check-ssl verify none inter 2s fastinter 1s downinter 1s fall 3 rise 2'

  if [ "$ingress_enabled" = true ]; then
    cat <<'EOF'

frontend application_ingress
    bind 0.0.0.0:8080
    mode http
    option httplog
    default_backend application_ingress_backends

backend application_ingress_backends
    mode http
    balance roundrobin
    option httpchk GET /healthz HTTP/1.1
    http-check send hdr Host k8sedge.zerops
    http-check expect status 200
EOF
    write_servers worker "${K8S_EDGE_INGRESS_BACKENDS:-k8sworker1.zerops:32080,k8sworker2.zerops:32080,k8sworker3.zerops:32080}" \
      'inter 2s fastinter 1s downinter 1s fall 3 rise 2'
  fi

  if [ "$headlamp_enabled" = true ]; then
    cat <<'EOF'

frontend headlamp
    bind 0.0.0.0:18081
    mode tcp
    option tcplog
    default_backend headlamp_backends

backend headlamp_backends
    mode tcp
    balance roundrobin
EOF
    write_servers headlamp "${K8S_EDGE_HEADLAMP_BACKENDS:-k8sworker1.zerops:32081,k8sworker2.zerops:32081,k8sworker3.zerops:32081}" \
      'inter 2s fastinter 1s downinter 1s fall 3 rise 2'
  fi

  cat <<'EOF'

frontend edge_health
    bind 0.0.0.0:18082
    mode http
    monitor-uri /healthz
EOF
} >"$config_path"

printf '%s\n' "$config_path"
