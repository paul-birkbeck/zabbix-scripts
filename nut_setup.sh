#!/usr/bin/env bash
# full_ups_zabbix_install_native_interactive.sh
# Native NUT (no Docker) + Zabbix scripts, with UPS prompts.
set -euo pipefail

# ---------- APT + Packages ----------
echo "=== APT Maintenance and Setup ==="
apt clean all
apt update -y
apt -y upgrade
apt install -y nut-server nut-client nut-snmp snmp
systemctl restart zabbix-proxy || true
echo "=== Base setup complete ==="

# ---------- Interactive Inputs (env overrides allowed) ----------
UPS_NAME_DEFAULT="tt-ups-rack-1"
UPS_IP_DEFAULT="10.193.11.66"
COMMUNITY="corp-it"
LISTEN_IP_DEFAULT="0.0.0.0"
SNMP_VERSION="v2c"

UPS_NAME="${UPS_NAME:-}"
UPS_IP="${UPS_IP:-}"
LISTEN_IP="${LISTEN_IP:-}"

if [[ -z "${UPS_NAME}" ]]; then
  read -r -p "UPS name [${UPS_NAME_DEFAULT}]: " UPS_NAME
  UPS_NAME="${UPS_NAME:-$UPS_NAME_DEFAULT}"
fi
if [[ -z "${UPS_IP}" ]]; then
  read -r -p "UPS IP address [${UPS_IP_DEFAULT}]: " UPS_IP
  UPS_IP="${UPS_IP:-$UPS_IP_DEFAULT}"
fi
if [[ -z "${LISTEN_IP}" ]]; then
  read -r -p "upsd LISTEN IP [${LISTEN_IP_DEFAULT}]: " LISTEN_IP
  LISTEN_IP="${LISTEN_IP:-$LISTEN_IP_DEFAULT}"
fi

echo "Using:"
echo "  UPS_NAME = ${UPS_NAME}"
echo "  UPS_IP   = ${UPS_IP}"
echo "  SNMP     = ${SNMP_VERSION} / community ${COMMUNITY}"
echo "  LISTEN   = ${LISTEN_IP}:3493"
echo

# ---------- NUT Config ----------
CFG_DIR="/etc/nut"
mkdir -p "$CFG_DIR"

cat > "$CFG_DIR/ups.conf" <<EOF
[${UPS_NAME}]
    driver = snmp-ups
    port = ${UPS_IP}
    community = ${COMMUNITY}
    mibs = auto
    snmp_version = ${SNMP_VERSION}
    desc = "${UPS_NAME}"
EOF

cat > "$CFG_DIR/upsd.conf" <<EOF
LISTEN ${LISTEN_IP} 3493
EOF

cat > "$CFG_DIR/upsd.users" <<'EOF'
[zabbix]
    password = zabbix
    upsmon master
[upsmon]
        password =
        upsmon master
EOF

cat > "$CFG_DIR/upsmon.conf" <<EOF
MONITOR ${UPS_NAME}@localhost 1 zabbix zabbix master
RUN_AS_USER nut
EOF

echo "MODE=netserver" > "$CFG_DIR/nut.conf"

# ---------- Enable + Start Services ----------
systemctl enable nut-driver@"${UPS_NAME}".service nut-server nut-client >/dev/null 2>&1 || true
# Kick the driver first (helpful in containers)
/sbin/upsdrvctl stop "${UPS_NAME}" >/dev/null 2>&1 || true
/sbin/upsdrvctl -u root start "${UPS_NAME}" || true
systemctl restart nut-driver@"${UPS_NAME}".service || true
systemctl restart nut-server nut-client

echo "=== NUT services status (brief) ==="
systemctl --no-pager --plain --full status nut-driver@"${UPS_NAME}".service | sed -n '1,6p' || true
systemctl --no-pager --plain --full status nut-server | sed -n '1,6p' || true

# ---------- Zabbix External Scripts ----------
SCRIPTS_DIR="/usr/lib/zabbix/externalscripts"
mkdir -p "$SCRIPTS_DIR"
umask 022

write() {
  local path="$1"
  local content="$2"
  printf '%s\n' "$content" > "$path"
  chmod +x "$path"
  echo "Created $path"
}

# 1) ups_discovery_filtered.sh
write "$SCRIPTS_DIR/ups_discovery_filtered.sh" "$(cat <<'BASH'
#!/bin/bash
# Usage: ups_discovery_filtered.sh UPS_NAME [UPS_HOST]
set -euo pipefail
UPS_NAME="${1:?Usage: $0 UPS_NAME [UPS_HOST]}"
UPS_HOST="${2:-localhost}"
upsc "$UPS_NAME@$UPS_HOST" 2>/dev/null | \
awk -F':' '
  $1 && $2 && !($1 ~ /^(battery\.charge|battery\.runtime|ups\.status|ups\.load)$/) {
    key=$1; gsub(/^[ \t]+|[ \t]+$/, "", key);
    printf "{\"{#UPS_KEY}\":\"%s\"},", key
  }' | sed 's/,$//' | awk '{print "{\"data\":["$0"]}"}'
BASH
)"

# 2) ups_discovery.sh
write "$SCRIPTS_DIR/ups_discovery.sh" "$(cat <<'BASH'
#!/bin/bash
# Usage: ups_discovery.sh UPS_NAME [UPS_HOST]
set -euo pipefail
UPS_NAME="${1:?Usage: $0 UPS_NAME [UPS_HOST]}"
UPS_HOST="${2:-localhost}"
upsc "$UPS_NAME@$UPS_HOST" 2>/dev/null | \
awk -F':' '{k=$1; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k != "") printf "{\"{#UPS_KEY}\":\"" k "\"}," }' \
| sed 's/,$//' | awk '{print "{\"data\":["$0"]}"}'
BASH
)"

# 3) ups_host_discovery.sh
write "$SCRIPTS_DIR/ups_host_discovery.sh" "$(cat <<'BASH'
#!/bin/bash
# Usage: ups_host_discovery.sh [/etc/nut/ups.conf]
set -euo pipefail
CONF="${1:-/etc/nut/ups.conf}"
awk -F'[][]' '/^\[.*\]/{printf "{\"{#UPSNAME}\":\"%s\"},", $2}' "$CONF" \
| sed 's/,$//' | awk '{print "{\"data\":["$0"]}"}'
BASH
)"

# 4) ups_simple_dynamic.sh
write "$SCRIPTS_DIR/ups_simple_dynamic.sh" "$(cat <<'BASH'
#!/bin/bash
# Usage: ups_simple_dynamic.sh UPS_NAME KEY [UPS_HOST]
set -euo pipefail
UPS_NAME="${1:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"
KEY="${2:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"
UPS_HOST="${3:-localhost}"
upsc "$UPS_NAME@$UPS_HOST" 2>/dev/null | awk -F':' -v key="$KEY" '$1==key{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'
BASH
)"

# 5) ups_value.sh
write "$SCRIPTS_DIR/ups_value.sh" "$(cat <<'BASH'
#!/bin/bash
# Usage: ups_value.sh UPS_NAME KEY [UPS_HOST]
set -euo pipefail
UPS_NAME="${1:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"
KEY="${2:?Usage: $0 UPS_NAME KEY [UPS_HOST]}"
UPS_HOST="${3:-localhost}"
upsc "$UPS_NAME@$UPS_HOST" 2>/dev/null | awk -F':' -v key="$KEY" '$1==key{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'
BASH
)"

echo
echo "=== Setup Complete ==="
echo "UPS config:       ${CFG_DIR}"
echo "Zabbix scripts:   ${SCRIPTS_DIR}"
echo
echo "Quick checks:"
echo "  snmpwalk -v2c -c ${COMMUNITY} ${UPS_IP} 1.3.6.1.2.1.1.5.0"
echo "  upsc ${UPS_NAME}@localhost | head -n 20"
echo "  ${SCRIPTS_DIR}/ups_host_discovery.sh"
echo "  ${SCRIPTS_DIR}/ups_discovery.sh ${UPS_NAME} localhost"