#!/bin/sh
set -eu

printf 'br_netfilter\noverlay\n' > /etc/modules-load.d/kubernetes.conf
modprobe br_netfilter || true
modprobe overlay || true

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
EOF
sysctl --system

swapoff -a || true
mkdir -p /var/log/kubernetes/audit /var/lib/longhorn /etc/kubernetes
chmod 0700 /etc/kubernetes
systemctl start iscsid || true
