#!/bin/sh
set -eu

config_path=${KEEPALIVED_CONFIG_PATH:-/home/zerops/keepalived.conf}
state_path=${K8S_VRRP_STATE_PATH:-/home/zerops/vrrp-vip}
vip=${K8S_VRRP_VIP:-}
host_octet=${K8S_VRRP_HOST_OCTET:-222}
expected_prefix_length=${K8S_VRRP_PREFIX_LENGTH:-22}
virtual_router_id=${K8S_VRRP_VIRTUAL_ROUTER_ID:-222}
priority=${K8S_VRRP_PRIORITY:-100}
advert_interval=${K8S_VRRP_ADVERT_INTERVAL:-1}
interface=${K8S_VRRP_INTERFACE:-}
local_cidr=${K8S_VRRP_LOCAL_CIDR:-}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

ipv4_to_int() {
  address=$1
  old_ifs=$IFS
  IFS=.
  # Intentional splitting validates the four IPv4 octets.
  # shellcheck disable=SC2086
  set -- $address
  IFS=$old_ifs
  [ "$#" -eq 4 ] || return 1
  result=0
  for octet do
    is_uint "$octet" || return 1
    case "$octet" in
      0) ;;
      0*) return 1 ;;
    esac
    [ "$octet" -le 255 ] || return 1
    result=$((result * 256 + octet))
  done
  printf '%s\n' "$result"
}

int_to_ipv4() {
  value=$1
  printf '%s.%s.%s.%s\n' \
    "$(((value >> 24) & 255))" \
    "$(((value >> 16) & 255))" \
    "$(((value >> 8) & 255))" \
    "$((value & 255))"
}

if [ -z "$interface" ]; then
  interface=$(ip -o -4 route show default | awk '{print $5; exit}')
fi
case "$interface" in
  ''|*[!A-Za-z0-9_.:-]*)
    printf 'could not discover a safe VRRP interface\n' >&2
    exit 1
    ;;
esac

if [ -z "$local_cidr" ]; then
  local_cidr=$(ip -o -4 address show dev "$interface" scope global | awk '{print $4; exit}')
fi
local_ip=${local_cidr%/*}
prefix_length=${local_cidr##*/}
if [ "$local_ip" = "$local_cidr" ] || ! is_uint "$prefix_length" \
    || [ "$prefix_length" -lt 1 ] || [ "$prefix_length" -gt 30 ]; then
  printf 'could not discover a usable IPv4 prefix on %s\n' "$interface" >&2
  exit 1
fi
if ! is_uint "$expected_prefix_length" || [ "$expected_prefix_length" -ne "$prefix_length" ]; then
  printf 'runtime prefix /%s does not match K8S_VRRP_PREFIX_LENGTH /%s\n' \
    "$prefix_length" "$expected_prefix_length" >&2
  exit 1
fi
if ! is_uint "$host_octet" || [ "$host_octet" -lt 1 ] || [ "$host_octet" -gt 254 ]; then
  printf 'K8S_VRRP_HOST_OCTET must be between 1 and 254\n' >&2
  exit 1
fi

local_int=$(ipv4_to_int "$local_ip") || {
  printf 'invalid local IPv4 address: %s\n' "$local_ip" >&2
  exit 1
}
subnet_size=$((1 << (32 - prefix_length)))
network_int=$((local_int / subnet_size * subnet_size))
broadcast_int=$((network_int + subnet_size - 1))
if [ -z "$vip" ]; then
  last_24_network=$((broadcast_int - 255))
  vip_int=$((last_24_network + host_octet))
  vip=$(int_to_ipv4 "$vip_int")
else
  vip_int=$(ipv4_to_int "$vip") || {
    printf 'K8S_VRRP_VIP must be a canonical IPv4 address\n' >&2
    exit 1
  }
fi
if [ "$vip_int" -le "$network_int" ] || [ "$vip_int" -ge "$broadcast_int" ]; then
  printf 'K8S_VRRP_VIP %s is outside the usable range of %s\n' "$vip" "$local_cidr" >&2
  exit 1
fi
if [ "$vip_int" -eq "$local_int" ]; then
  printf 'K8S_VRRP_VIP must not equal the current container address\n' >&2
  exit 1
fi

if ! is_uint "$virtual_router_id" || [ "$virtual_router_id" -lt 1 ] \
    || [ "$virtual_router_id" -gt 255 ]; then
  printf 'K8S_VRRP_VIRTUAL_ROUTER_ID must be between 1 and 255\n' >&2
  exit 1
fi
if ! is_uint "$priority" || [ "$priority" -lt 1 ] || [ "$priority" -gt 254 ]; then
  printf 'K8S_VRRP_PRIORITY must be between 1 and 254\n' >&2
  exit 1
fi
if ! is_uint "$advert_interval" || [ "$advert_interval" -lt 1 ] \
    || [ "$advert_interval" -gt 255 ]; then
  printf 'K8S_VRRP_ADVERT_INTERVAL must be between 1 and 255\n' >&2
  exit 1
fi

router_id=$(printf 'K8S_EDGE_%s' "$local_ip" | tr '.' '_')
umask 077
printf '%s\n' "$vip" >"$state_path"
cat >"$config_path" <<EOF
# Generated at container start from the current default interface and address.
# Multicast VRRP intentionally has no static unicast peer list, so replacement
# edge containers may receive new Zerops addresses without configuration drift.
global_defs {
    router_id ${router_id}
    dynamic_interfaces
    max_auto_priority
    enable_script_security
    script_user zerops
}

vrrp_script check_haproxy {
    script "/var/www/edge/check-haproxy.sh"
    interval 1
    timeout 1
    fall 2
    rise 1
}

vrrp_instance K8S_EDGE {
    state BACKUP
    interface ${interface}
    virtual_router_id ${virtual_router_id}
    priority ${priority}
    advert_int ${advert_interval}
    nopreempt
    garp_master_delay 0
    garp_master_repeat 3
    garp_master_refresh 30
    garp_master_refresh_repeat 2
    track_script {
        check_haproxy
    }
    virtual_ipaddress {
        ${vip}/32 dev ${interface}
    }
    notify_master "/var/www/edge/notify-vrrp.sh MASTER"
    notify_backup "/var/www/edge/notify-vrrp.sh BACKUP"
    notify_fault "/var/www/edge/notify-vrrp.sh FAULT"
    notify_stop "/var/www/edge/notify-vrrp.sh STOP"
}
EOF

printf '%s\n' "$config_path"
