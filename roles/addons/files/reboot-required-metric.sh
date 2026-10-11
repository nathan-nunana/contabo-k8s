#!/bin/sh
# Writes node_reboot_required for node-exporter's textfile collector.
set -eu

out=/var/lib/node-exporter/textfile/reboot_required.prom
value=0
[ -f /var/run/reboot-required ] && value=1

printf '# HELP node_reboot_required 1 if a package update needs a reboot.\n# TYPE node_reboot_required gauge\nnode_reboot_required %s\n' \
  "$value" > "$out.tmp"
mv "$out.tmp" "$out"
