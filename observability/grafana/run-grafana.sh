#!/bin/sh
set -eu
exec /var/www/bin/grafana server --homepath /var/www
