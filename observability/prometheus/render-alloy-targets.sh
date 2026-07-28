#!/bin/sh
set -eu

targets_dir=/var/www/targets
targets_file=$targets_dir/alloy.json
list=${K8S_ALLOY_SCRAPE_TARGETS:-}

mkdir -p "$targets_dir"
if [ -z "$list" ]; then
  printf '[{"targets":[],"labels":{}}]\n' >"$targets_file"
  exit 0
fi

old_ifs=$IFS
IFS=,
# Intentional word splitting turns the reviewed comma-separated project
# variable into individual Prometheus file_sd targets.
# shellcheck disable=SC2086
set -- $list
IFS=$old_ifs

printf '[{"targets":[' >"$targets_file"
first=true
for target do
  case "$target" in
    ''|*[!A-Za-z0-9.:]*)
      printf 'invalid Alloy scrape target: %s\n' "$target" >&2
      exit 1
      ;;
  esac
  if [ "$first" = true ]; then
    first=false
  else
    printf ',' >>"$targets_file"
  fi
  printf '"%s"' "$target" >>"$targets_file"
done
printf '],"labels":{}}]\n' >>"$targets_file"
