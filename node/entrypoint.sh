#!/bin/sh
set -eu

if [ ! -s /etc/machine-id ]; then
  systemd-machine-id-setup
fi

exec /sbin/init
