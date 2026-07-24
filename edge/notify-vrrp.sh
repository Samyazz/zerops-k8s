#!/bin/sh
set -eu

state=${1:-UNKNOWN}
vip=${K8S_VRRP_VIP:-}
if [ -z "$vip" ]; then
  vip=$(cat "${K8S_VRRP_STATE_PATH:-/home/zerops/vrrp-vip}")
fi
interface=${K8S_VRRP_INTERFACE:-$(ip -o -4 route show default | awk '{print $5; exit}')}
address=$(ip -o -4 address show dev "$interface" scope global | awk '$4 != "'"$vip"'/32" {print $4; exit}')
printf '{"component":"keepalived-edge","state":"%s","interface":"%s","address":"%s","vip":"%s"}\n' \
  "$state" "$interface" "${address%/*}" "$vip"
