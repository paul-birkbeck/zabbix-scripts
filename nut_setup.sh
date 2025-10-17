#!/usr/bin/env bash
# nut_setup_native.sh
# Native NUT + Zabbix externalscripts with multi-UPS prompts, safe timeouts, and no config backups.
set -euo pipefail

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}
require_root

# ---------- Defaults (override via env) ----------
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
DEADTIME="${DEADTIME:-30}"
MINSUPPLIES="${MINSUPPLIES:-1}"

CFG_DIR="/etc/nut"
RUN_DIR="/run/nut"
SCRIPTS_DIR="/usr/lib/zabbix/externalscripts"

echo "=== Stop services & wipe old configs ==="
systemctl stop nut-server nut-client 2>/dev/null || true
/sbin/upsdrvctl stop all 2>/dev/null || true
rm -rf "$CFG_DIR"
mkdir -p "$CFG_DIR"

# Clean runtime (ignore scheduler subdir)
install -d -o root -g root -m 0755 "$RUN_DIR"
find "$RUN_DIR" -mindepth 1 -maxdepth 1 ! -name 'upssched' -exec rm -rf {} + 2>/dev/null || true

echo "=== Ensure users/groups ==="
getent group nut >/dev/null || groupadd --system nut
getent passwd nut >/dev/null || useradd --system -g nut -d /var/lib/nut -s /usr/sbin/nologin nut
# Add zabbix to nut group if present
if getent passwd zabbix >/dev/null; then usermod -aG nut zabbix || true; fi
install -d -o nut -g nut -m 0775 "$RUN_DIR"

echo "=== Install packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nut-server nut-client nut-snmp snmp curl jq

# Optional: AppArmor relax (temporary safety)
if command -v aa-status >/dev/null 2>&1; then
  if aa-status 2>/dev/null | grep -q "profiles are in enforce mode"; then
    if [[ "${AA_COMPLAIN:-1}" = "1" ]]; then
      echo "Putting snmp-ups AppArmor profile into complain mode."
      aa-complain /usr/lib/nut/snmp-ups 2>/dev/null || true
    fi
  fi
fi

echo
echo "=== NUT UPS configuration (interactive) ==="
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

# Always add at least one
add_one
while true; do
  read -r -p "Add another UPS? [y/N]: " yn
  case "${yn,,}" in y|yes) add_one ;; *) break ;; esac
done

echo
echo "Using:"
echo "  LISTEN   = ${LISTEN_IP}:3493"
echo "  SNMP     = ${SNMP_VERSION} / community ${COMMUNITY}"
echo "  UPSes:"
for idx in "${!UPS_NAMES[@]}"; do printf "    - %s (%s)\n" "${UPS_NAMES[$idx]}" "${UPS_IPS[$idx]}"; done
echo

echo "=== Write NUT configs ==="
# ups.conf
{
  for idx in "${!UPS_NAMES[@]}"; do
    u="${UPS_NAMES[$idx]}"; ip="${UPS_IPS[$idx]}"
    cat <<EOF
[${u}]
  user = nut
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
POWERDOWNFLAG /etc/killpower
EOF
} > "$CFG_DIR/upsmon.conf"

echo "MODE=netserver" > "$CFG_DIR/nut.conf"

echo "=== systemd override: run drivers with -u nut ==="
mkdir -p /etc/systemd/system/nut-driver@.service.d
cat > /etc/systemd/system/nut-driver@.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/sbin/upsdrvctl -u nut start %i
ExecStop=
ExecStop=/sbin/upsdrvctl -u nut stop %i
EOF

systemctl daemon-reload

echo "=== Start drivers and services ==="
# Clean stale runtime sockets
find "$RUN_DIR" -mindepth 1 -maxdepth 1 ! -name 'upssched' -exec rm -rf {} + 2>/dev/null || true

# Start each driver explicitly
for u in "${UPS_NAMES[@]}"; do
  if systemctl list-unit-files | grep -q '^nut-driver@'; then
    systemctl stop "nut-driver@${u}.service" 2>/dev/null || true
    systemctl start "nut-driver@${u}.service"
  else
    /sbin/upsdrvctl -u nut stop "${u}" 2>/dev/null || true
    /sbin/upsdrvctl -u nut start "${u}"
  fi
done

systemctl enable nut-server nut-client >/dev/null 2>&1 || true
systemctl restart nut-server nut-client

echo "=== Permissions sanity ==="
ls -l "$RUN_DIR" || true

echo "=== Zabbix External Scripts (with timeouts) ==="
mkdir -p "$SCRIPTS_DIR"
umask 022

# _ups_common.sh
cat > "$SCRIPTS_DIR/_ups_common.sh" <<'BASH'
#!/bin/bash
set -euo pipefail
UPS_QUERY_TIMEOUT=${UPS_QUERY_TIMEOUT:-5}
safe_upsc() { timeout -k 1 "${UPS_QUERY_TIMEOUT}" upsc "$1" 2>/dev/null; }
BASH
chmod +x "$SCRIPTS_DIR/_ups_common.sh"
echo "Created $SCRIPTS_DIR/_ups_common.sh"

# ups_discovery_filtered.sh
cat > "$SCRIPTS_DIR/ups_discovery_filtered.sh" <<'BASH'
#!/bin/bash
# Usage: ups_discovery_filtered.sh UPS_NAME [UPS_HOST]
set -euo pipefail
. /usr/lib/zabbix/externalscripts/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME [UPS_HOST]}"; UPS_HOST="${2:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: '
  $1 && $2 && !($1 ~ /^(battery\.charge|battery\.runtime|ups\.status|ups\.load)$/) {
    key=$1; gsub(/^[ \t]+|[ \t]+$/, "", key);
    printf "{\"{#UPS_KEY}\":\"%s\"},", key
  }' | sed 's/,$//' | awk '{print "{\"data\":["$0"]}"}'
BASH
chmod +x "$SCRIPTS_DIR/ups_discovery_filtered.sh"
echo "Created $SCRIPTS_DIR/ups_discovery_filtered.sh"

# ups_discovery.sh
cat > "$SCRIPTS_DIR/ups_discovery.sh" <<'BASH'
#!/bin/bash
# Usage: ups_discovery.sh UPS_NAME [UPS_HOST]
set -euo pipefail
. /usr/lib/zabbix/externalscripts/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME [UPS_HOST]}"; UPS_HOST="${2:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: '{k=$1; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k != "") printf "{\"{#UPS_KEY}\":\"" k "\"}," }' \
| sed 's/,$//' | awk '{print "{\"data\":["$0"]}"}'
BASH
chmod +x "$SCRIPTS_DIR/ups_discovery.sh"
echo "Created $SCRIPTS_DIR/ups_discovery.sh"

# ups_host_discovery.sh
cat > "$SCRIPTS_DIR/ups_host_discovery.sh" <<'BASH'
#!/bin/bash
# Usage: ups_host_discovery.sh [/etc/nut/ups.conf]
set -euo pipefail
CONF="${1:-/etc/nut/ups.conf}"
awk -F"[][]" '/^\[.*\]/{printf "{\"{#UPSNAME}\":\"%s\"},", $2}' "$CONF" \
| sed 's/,$//' | awk '{print "{\"data\":["$0"]}"}'
BASH
chmod +x "$SCRIPTS_DIR/ups_host_discovery.sh"
echo "Created $SCRIPTS_DIR/ups_host_discovery.sh"

# ups_simple_dynamic.sh
cat > "$SCRIPTS_DIR/ups_simple_dynamic.sh" <<'BASH'
#!/bin/bash
# Usage: ups_simple_dynamic.sh UPS_NAME KEY [UPS_HOST]
set -euo pipefail
. /usr/lib/zabbix/externalscripts/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"; KEY="${2:?}"; UPS_HOST="${3:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: -v key="$KEY" '$1==key{v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v}'
BASH
chmod +x "$SCRIPTS_DIR/ups_simple_dynamic.sh"
echo "Created $SCRIPTS_DIR/ups_simple_dynamic.sh"

# ups_value.sh
cat > "$SCRIPTS_DIR/ups_value.sh" <<'BASH'
#!/bin/bash
# Usage: ups_value.sh UPS_NAME KEY [UPS_HOST]
set -euo pipefail
. /usr/lib/zabbix/externalscripts/_ups_common.sh
UPS_NAME="${1:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"; KEY="${2:?}"; UPS_HOST="${3:-localhost}"
safe_upsc "$UPS_NAME@$UPS_HOST" | awk -F: -v key="$KEY" '$1==key{v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v}'
BASH
chmod +x "$SCRIPTS_DIR/ups_value.sh"
echo "Created $SCRIPTS_DIR/ups_value.sh"

echo
echo "=== Smoke tests ==="
echo "  upsc ${UPS_NAMES[0]}@localhost ups.status || true"
upsc "${UPS_NAMES[0]}@localhost" ups.status || true
echo
echo "=== Done. ==="
echo "If you see 'Driver not connected' briefly, that's normal while drivers attach."
echo "Zabbix tip: poll @ 30–60s; trigger on nodata(3m)=1 for clean alerts."
