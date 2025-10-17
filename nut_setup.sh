#!/usr/bin/env bash
# full_ups_zabbix_install_native_interactive.sh
# Native NUT (no Docker) + Zabbix scripts, with multi-UPS prompts and hang-hardening.
set -euo pipefail

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}
require_root

# ---------- Defaults (override via env if desired) ----------
UPS_NAME_DEFAULT="${UPS_NAME_DEFAULT:-tt-ups-rack-1}"
UPS_IP_DEFAULT="${UPS_IP_DEFAULT:-10.193.11.66}"
COMMUNITY_DEFAULT="${COMMUNITY_DEFAULT:-corp-it}"
SNMP_VERSION_DEFAULT="${SNMP_VERSION_DEFAULT:-v2c}"
LISTEN_IP_DEFAULT="${LISTEN_IP_DEFAULT:-0.0.0.0}"

# NUT hardening defaults
SNMP_TIMEOUT="${SNMP_TIMEOUT:-3}"
SNMP_RETRIES="${SNMP_RETRIES:-1}"
POLLINTERVAL="${POLLINTERVAL:-10}"
MAXAGE="${MAXAGE:-30}"
DEADTIME="${DEADTIME:-15}"
MINSUPPLIES="${MINSUPPLIES:-1}"

CFG_DIR="/etc/nut"
SCRIPTS_DIR="/usr/lib/zabbix/externalscripts"

echo "=== APT Maintenance and Setup ==="
export DEBIAN_FRONTEND=noninteractive
apt clean all || true
apt update -y
apt -y install nut-server nut-client nut-snmp snmp curl jq || {
  echo "Failed to install required packages." >&2; exit 1; }
systemctl restart zabbix-proxy || true
echo "=== Base setup complete ==="

# ---------- Interactive: collect >=1 UPS, allow many ----------
echo
echo "=== NUT UPS configuration ==="
read -r -p "SNMP community [${COMMUNITY_DEFAULT}]: " COMMUNITY
COMMUNITY="${COMMUNITY:-$COMMUNITY_DEFAULT}"

read -r -p "SNMP version (v1|v2c|v3) [${SNMP_VERSION_DEFAULT}]: " SNMP_VERSION
SNMP_VERSION="${SNMP_VERSION:-$SNMP_VERSION_DEFAULT}"

read -r -p "upsd LISTEN IP [${LISTEN_IP_DEFAULT}]: " LISTEN_IP
LISTEN_IP="${LISTEN_IP:-$LISTEN_IP_DEFAULT}"

UPS_NAMES=()
UPS_IPS=()

add_one() {
  local n i
  read -r -p "UPS name [${UPS_NAME_DEFAULT}]: " n
  n="${n:-$UPS_NAME_DEFAULT}"
  read -r -p "UPS IP address [${UPS_IP_DEFAULT}]: " i
  i="${i:-$UPS_IP_DEFAULT}"
  UPS_NAMES+=("$n")
  UPS_IPS+=("$i")
}

# always add at least one
add_one
while true; do
  read -r -p "Add another UPS? [y/N]: " yn
  case "${yn,,}" in
    y|yes) add_one ;;
    *) break ;;
  esac
done

echo
echo "Using:"
echo "  LISTEN   = ${LISTEN_IP}:3493"
echo "  SNMP     = ${SNMP_VERSION} / community ${COMMUNITY}"
echo "  UPSes:"
for idx in "${!UPS_NAMES[@]}"; do
  printf "    - %s (%s)\n" "${UPS_NAMES[$idx]}" "${UPS_IPS[$idx]}"
done
echo

# ---------- Write NUT configs ----------
mkdir -p "$CFG_DIR"

# ups.conf
{
  for idx in "${!UPS_NAMES[@]}"; do
    u="${UPS_NAMES[$idx]}"; ip="${UPS_IPS[$idx]}"
    cat <<EOF
[${u}]
  driver = snmp-ups
  port = ${ip}
  community = ${COMMUNITY}
  mibs = auto
  snmp_version = ${SNMP_VERSION}
  pollinterval = ${POLLINTERVAL}
  snmp_timeout = ${SNMP_TIMEOUT}
  snmp_retries = ${SNMP_RETRIES}
  notransferoids = yes
  desc = "${u}"
EOF
    echo
  done
} > "$CFG_DIR/ups.conf"

# upsd.conf
cat > "$CFG_DIR/upsd.conf" <<EOF
LISTEN ${LISTEN_IP} 3493
MAXAGE ${MAXAGE}
EOF

# upsd.users
cat > "$CFG_DIR/upsd.users" <<'EOF'
[zabbix]
  password = zabbix
  upsmon master

[upsmon]
  password =
  upsmon master
EOF

# upsmon.conf
{
  for u in "${UPS_NAMES[@]}"; do
    echo "MONITOR ${u}@localhost 1 zabbix zabbix master"
  done
  cat <<EOF
RUN_AS_USER nut
MINSUPPLIES ${MINSUPPLIES}
DEADTIME ${DEADTIME}
# Optional: reduce log noise
POWERDOWNFLAG /etc/killpower
EOF
} > "$CFG_DIR/upsmon.conf"

echo "MODE=netserver" > "$CFG_DIR/nut.conf"

# ---------- Enable + Start Services ----------
# Stop any existing drivers (safe) then start all with upsdrvctl
/sbin/upsdrvctl stop all >/dev/null 2>&1 || true
/sbin/upsdrvctl -u root start || true

systemctl enable nut-server nut-client >/dev/null 2>&1 || true
systemctl restart nut-server nut-client

echo "=== NUT services status (brief) ==="
systemctl --no-pager --plain --full status nut-server | sed -n '1,10p' || true
systemctl --no-pager --plain --full status nut-client | sed -n '1,10p' || true

# ---------- Zabbix External Scripts (with timeouts) ----------
mkdir -p "$SCRIPTS_DIR"
umask 022

write() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
  chmod +x "$path"
  echo "Created $path"
}

# Generic helper: safe_upsc with timeout to prevent hangs
write "$SCRIPTS_DIR/_ups_common.sh" '#!/bin/bash
set -euo pipefail
UPS_QUERY_TIMEOUT=${UPS_QUERY_TIMEOUT:-5}
safe_upsc() { timeout -k 1 "${UPS_QUERY_TIMEOUT}" upsc "$1" 2>/dev/null; }
'

# 1) ups_discovery_filtered.sh
write "$SCRIPTS_DIR/ups_discovery_filtered.sh" '#!/bin/bash
# Usage: ups_discovery_filtered.sh UPS_NAME [UPS_HOST]
set -euo pipefail
. '"$SCRIPTS_DIR"'/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME [UPS_HOST]}"; UPS_HOST="${2:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: '"'"'
  $1 && $2 && !($1 ~ /^(battery\.charge|battery\.runtime|ups\.status|ups\.load)$/) {
    key=$1; gsub(/^[ \t]+|[ \t]+$/, "", key);
    printf "{\"{#UPS_KEY}\":\"%s\"},", key
  }'"'"' | sed '"'"'s/,$//'"'"' | awk '"'"'{print "{\"data\":["$0"]}"}'"'"''
'

# 2) ups_discovery.sh
write "$SCRIPTS_DIR/ups_discovery.sh" '#!/bin/bash
# Usage: ups_discovery.sh UPS_NAME [UPS_HOST]
set -euo pipefail
. '"$SCRIPTS_DIR"'/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME [UPS_HOST]}"; UPS_HOST="${2:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: '"'"'{k=$1; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k != "") printf "{\"{#UPS_KEY}\":\"" k "\"},"}'"'"' \
| sed '"'"'s/,$//'"'"' | awk '"'"'{print "{\"data\":["$0"]}"}'"'"''
'

# 3) ups_host_discovery.sh
write "$SCRIPTS_DIR/ups_host_discovery.sh" '#!/bin/bash
# Usage: ups_host_discovery.sh [/etc/nut/ups.conf]
set -euo pipefail
CONF="${1:-/etc/nut/ups.conf}"
awk -F"[][]" '"'"'/^\[.*\]/{printf "{\"{#UPSNAME}\":\"%s\"},", $2}'"'"' "$CONF" | \
sed '"'"'s/,$//'"'"' | awk '"'"'{print "{\"data\":["$0"]}"}'"'"''
'

# 4) ups_simple_dynamic.sh
write "$SCRIPTS_DIR/ups_simple_dynamic.sh" '#!/bin/bash
# Usage: ups_simple_dynamic.sh UPS_NAME KEY [UPS_HOST]
set -euo pipefail
. '"$SCRIPTS_DIR"'/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"; KEY="${2:?}"; UPS_HOST="${3:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: -v key="$KEY" '"'"'$1==key{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'"'"''
'

# 5) ups_value.sh
write "$SCRIPTS_DIR/ups_value.sh" '#!/bin/bash
# Usage: ups_value.sh UPS_NAME KEY [UPS_HOST]
set -euo pipefail
. '"$SCRIPTS_DIR"'/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"; KEY="${2:?}"; UPS_HOST="${3:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: -v key="$KEY" '"'"'$1==key{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'"'"''
'

# ---------- Quick checks ----------
echo
echo "=== Setup Complete ==="
echo "Configs in:   ${CFG_DIR}"
echo "Zabbix scripts: ${SCRIPTS_DIR}"
echo
echo "Quick checks:"
echo "  snmpwalk -v2c -c ${COMMUNITY} ${UPS_IPS[0]} 1.3.6.1.2.1.1.5.0"
echo "  upsc ${UPS_NAMES[0]}@localhost | head -n 20"
echo "  ${SCRIPTS_DIR}/ups_host_discovery.sh"
echo "  ${SCRIPTS_DIR}/ups_discovery.sh ${UPS_NAMES[0]} localhost"
echo
echo "Tip: set Zabbix macros or item params to pass UPS name per item; all helper scripts time out safely."
