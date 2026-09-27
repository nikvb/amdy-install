#!/bin/bash
# ============================================================================
# AMDY.IO EAGI AMD Installer for Asterisk-Based Dialers
# ============================================================================
# For custom Asterisk dialers (NOT ViciDial/Vicibox).
# Installs the Python EAGI script, required dependencies, and registers
# this server's IP with your AMDY.IO account.
#
# Usage:
#   curl -sL https://download.amdy.io/installamd-asterisk.sh | bash -s -- YOUR_API_KEY
#   # or
#   bash installamd-asterisk.sh --api-key YOUR_API_KEY
#
# Options:
#   --api-key KEY        AMDY.IO API key (from https://app.amdy.io/settings)
#   --portal-base URL    Override portal base URL (default: https://app.amdy.io)
#   --skip-register      Skip account activation / IP register (install only)
#   -h, --help           Show this help
# ============================================================================

set -euo pipefail

API_KEY=""
SKIP_REGISTER="0"
PORTAL_BASE="https://app.amdy.io"

AMD_SCRIPT_URL="https://download.amdy.io/amd.py"
AGI_DIR="/var/lib/asterisk/agi-bin"
AMD_SCRIPT_PATH="${AGI_DIR}/amdy-amd.py"
API_KEY_DIR="/etc/amdy"
API_KEY_FILE="${API_KEY_DIR}/api-key"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[AMDY]${NC} $*"; }
warn() { echo -e "${YELLOW}[AMDY]${NC} $*"; }
err()  { echo -e "${RED}[AMDY]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
AMDY.IO EAGI AMD Installer — Asterisk-Based Dialers

Usage:
  bash $0 --api-key YOUR_API_KEY
  curl -sL https://download.amdy.io/installamd-asterisk.sh | bash -s -- YOUR_API_KEY

Options:
  --api-key KEY          AMDY.IO API key (from https://app.amdy.io/settings)
  --portal-base URL      Override portal base (default: https://app.amdy.io)
  --skip-register        Skip account activation / IP register (install only)
  -h, --help             Show this help

The installer auto-detects your public IP. After installation succeeds, it
calls the portal to register this server's IP and activate your account.
EOF
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --skip-register) SKIP_REGISTER="1"; shift ;;
    --portal-base) PORTAL_BASE="$2"; shift 2 ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [ -z "$API_KEY" ]; then
        API_KEY="$1"; shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

# --- Preflight ---
if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root."
fi

if ! command -v asterisk &>/dev/null; then
  die "Asterisk not found in PATH. Is this an Asterisk server?"
fi

ASTERISK_VERSION=$(asterisk -V 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
log "Detected Asterisk version: ${ASTERISK_VERSION}"

# --- API Key ---
if [ -z "${API_KEY}" ]; then
  echo ""
  echo -e "${BLUE}Enter your AMDY.IO API key (from https://app.amdy.io/settings):${NC}"
  read -r API_KEY
  if [ -z "${API_KEY}" ]; then
    die "API key is required."
  fi
fi

# --- Get public IP ---
get_public_ip() {
  local ip=""
  for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return
    fi
  done
  # Fallback: hostname -I
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-unknown}"
}

PUBLIC_IP=$(get_public_ip)
log "Public IP: ${PUBLIC_IP}"

# --- Install Python3 + pip ---
install_python() {
  log "Installing Python3 + pip..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y python3 python3-pip curl wget
  elif command -v yum &>/dev/null; then
    yum install -y python3 python3-pip curl wget
  elif command -v zypper &>/dev/null; then
    zypper refresh
    zypper install -y python3 python3-pip curl wget
  elif command -v dnf &>/dev/null; then
    dnf install -y python3 python3-pip curl wget
  else
    die "Unsupported package manager. Install python3 and pip3 manually."
  fi
  pip3 install --upgrade pip 2>/dev/null || true
}

# --- Install Python packages ---
install_python_packages() {
  log "Installing Python dependencies..."
  pip3 install --quiet \
    pyst2 \
    websocket-client \
    2>&1 | tail -3

  # Verify imports
  if ! python3 -c "from asterisk.agi import AGI; from websocket import create_connection; print('OK')" 2>/dev/null; then
    err "Python package installation failed."
    err "Try manually: pip3 install pyst2 websocket-client"
    exit 1
  fi
  log "Python dependencies installed successfully."
}

# --- Install the EAGI script ---
install_amd_script() {
  log "Installing AMDY EAGI script..."

  mkdir -p "${AGI_DIR}"

  curl -sL "${AMD_SCRIPT_URL}" -o "${AMD_SCRIPT_PATH}"
  if [ ! -s "${AMD_SCRIPT_PATH}" ]; then
    die "Failed to download amd.py from ${AMD_SCRIPT_URL}"
  fi

  chmod 755 "${AMD_SCRIPT_PATH}"
  chown asterisk:asterisk "${AMD_SCRIPT_PATH}" 2>/dev/null || true

  log "EAGI script installed at: ${AMD_SCRIPT_PATH}"
}

# --- Store API key ---
store_api_key() {
  log "Storing API key in ${API_KEY_FILE}..."

  mkdir -p "${API_KEY_DIR}"
  echo -n "${API_KEY}" > "${API_KEY_FILE}"
  chmod 600 "${API_KEY_FILE}"
  chown root:root "${API_KEY_FILE}"
  # Allow asterisk user to read the key
  chown asterisk:asterisk "${API_KEY_FILE}" 2>/dev/null || true

  log "API key stored (mode 600, asterisk-owned)."
}

# --- Register IP with portal ---
register_ip() {
  if [ "${SKIP_REGISTER}" = "1" ]; then
    warn "Skipping IP registration (--skip-register)."
    return
  fi

  log "Registering IP ${PUBLIC_IP} with your AMDY.IO account..."

  local resp
  resp=$(curl -s -w "\n%{http_code}" \
    -X POST "${PORTAL_BASE}/api/v1/ips/register" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    --data "{\"ip\":\"${PUBLIC_IP}\",\"description\":\"$(hostname)\"}")
  local http
  http=$(echo "$resp" | tail -n1)
  local body
  body=$(echo "$resp" | sed '$d')

  if [ "$http" = "200" ]; then
    log "Account activated ✓ — IP ${PUBLIC_IP} is bound to your account."
    echo "$body" | head -c 400
    echo
  else
    warn "Register API returned HTTP ${http}"
    echo "$body" | head -c 400
    echo
    warn "Install is complete but account may NOT be activated."
    warn "Verify your API key at https://app.amdy.io/settings and re-run:"
    warn "  curl -sL ${PORTAL_BASE}/api/v1/ips/register -H 'Authorization: Bearer YOUR_KEY' -d '{\"ip\":\"${PUBLIC_IP}\"}'"
  fi
}

# --- Verify EAGI is enabled ---
check_eagi() {
  log "Checking EAGI configuration..."

  local ASTERISK_CONF="/etc/asterisk/asterisk.conf"
  if [ -f "${ASTERISK_CONF}" ]; then
    if grep -q "^\[directories\]" "${ASTERISK_CONF}" && grep -q "astagidir" "${ASTERISK_CONF}"; then
      log "EAGI directory configured: $(grep 'astagidir' "${ASTERISK_CONF}" | head -1)"
    else
      warn "EAGI directory not explicitly configured in asterisk.conf."
      warn "Default AGI directory: ${AGI_DIR}"
    fi
  fi
}

# --- Print dialplan instructions ---
print_instructions() {
  echo ""
  echo -e "${GREEN}============================================================================${NC}"
  echo -e "${GREEN} AMDY.IO EAGI AMD — Installed Successfully${NC}"
  echo -e "${GREEN}============================================================================${NC}"
  echo ""
  echo "  Script location: ${AMD_SCRIPT_PATH}"
  echo "  API key file:    ${API_KEY_FILE}"
  echo "  Server IP:       ${PUBLIC_IP}"
  echo "  Python deps:     pyst2, websocket-client"
  echo ""
  echo -e "${YELLOW}Next step — add to your dialplan:${NC}"
  echo ""
  echo "  In /etc/asterisk/extensions.conf (or your dialplan file), add:"
  echo ""
  echo "    exten => s,1,Answer()"
  echo "    exten => s,n,EAGI(amdy-amd.py)"
  echo "    exten => s,n,GotoIf(\$[\"\${AMDSTATUS}\" = \"HUMAN\"]?human:machine)"
  echo "    exten => s,n(machine),NoOp(Machine detected: \${AMDCAUSE})"
  echo "    exten => s,n,Hangup()"
  echo "    exten => s,n(human),NoOp(Human detected — routing to agent)"
  echo "    ; ... route to your agent queue ..."
  echo ""
  echo -e "${YELLOW}Available channel variables after EAGI:${NC}"
  echo "  AMDSTATUS  — HUMAN or AMD (machine)"
  echo "  AMDCAUSE   — Reason code (e.g., HUMAN, MACHINE, CONNECTION_ERROR)"
  echo "  AMDSTATS   — Raw response from AMDY API"
  echo ""
  echo -e "${BLUE}Docs:${NC} ${PORTAL_BASE}/docs/api"
  echo -e "${BLUE}Asterisk guide:${NC} ${PORTAL_BASE}/docs/asterisk-install"
  echo -e "${BLUE}Support:${NC} support@amdy.io"
  echo ""
}

# --- Main ---
main() {
  echo ""
  echo -e "${BLUE}============================================================================${NC}"
  echo -e "${BLUE} AMDY.IO EAGI AMD Installer — Asterisk-Based Dialers${NC}"
  echo -e "${BLUE}============================================================================${NC}"
  echo ""

  install_python
  install_python_packages
  install_amd_script
  store_api_key
  register_ip
  check_eagi
  print_instructions
}

main "$@"
