#!/bin/sh
set -eu

mkdir -p /var/www/data
exec /var/www/prometheus \
  --config.file=/var/www/prometheus.yml \
  --storage.tsdb.path=/var/www/data \
  --storage.tsdb.retention.time="${RETENTION_TIME:-4h}" \
  --web.enable-lifecycle \
  --web.enable-admin-api \
  --web.enable-remote-write-receiver
