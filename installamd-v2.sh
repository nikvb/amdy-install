#!/bin/bash
# AMDY.IO unified installer (v2 — API-key + auto-activation)
# Supports openSUSE/SLES, CentOS/RHEL/Fedora, Ubuntu/Debian
# Detects Vicibox 7 / 8 / 9-12 and applies the matching dial-plan.
#
# Usage:
#   curl -fsSL https://download.amdy.io/installamd-v2.sh | bash -s <API_KEY>
#   curl -fsSL https://download.amdy.io/installamd-v2.sh | bash -s -- --api-key <KEY> [--360] [-v 8]
#
# 2026-09-25: old dialers (CentOS/openSUSE/VICIbox with outdated CA bundles) cannot
# validate the current Let's Encrypt chain, so public package downloads use -k.
# Tarballs are still checked against published sha256 sums. The API-key register
# call tries full TLS verification FIRST and only falls back to -k (with a
# warning) when the failure is a certificate error.
#
# 2026-09-27: the 8370 fallback to stock AMD() fires on every error cause any
# amd.py reports: CONNECTION_ERROR / PROCESSING_ERROR / FATAL_ERROR (amdy.tar.gz,
# AMD_WS 2.x) and NETERR / INTERR (amdy8.tar.gz, amdy360.tar.gz). It checked only
# CONNECTION_ERROR, so ViciBox 8 and --360 boxes never fell back.
#
# Vicidial runs as root — we do NOT chown anything to asterisk.

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $1${NC}"; }
info()    { echo -e "${BLUE}[$(date '+%H:%M:%S')] $1${NC}"; }
die()     { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $1${NC}" >&2; exit 1; }

# ---------- Defaults / arg parsing ----------
API_KEY="${AMDY_API_KEY:-}"
PORTAL_BASE="${AMDY_PORTAL_BASE:-https://app.amdy.io}"
DOWNLOAD_BASE="${AMDY_DOWNLOAD_BASE:-https://download.amdy.io}"
# Reject downgrade to http://; this script + its tarballs must be HTTPS.
case "$DOWNLOAD_BASE" in
  https://*) ;;
  *) echo "Refusing non-HTTPS DOWNLOAD_BASE: $DOWNLOAD_BASE" >&2; exit 1 ;;
esac
VICIBOX_OVERRIDE=""
OS_OVERRIDE=""
INSTALL_360=""
SKIP_REGISTER=""

usage() {
  cat <<EOF
AMDY.IO installer v2

Usage:
  curl -fsSL https://download.amdy.io/installamd-v2.sh | bash -s <API_KEY>
  curl -fsSL https://download.amdy.io/installamd-v2.sh | bash -s -- --api-key <KEY> [options]
  AMDY_API_KEY=<KEY> bash installamd-v2.sh [options]       # via env var

Options:
  --api-key <KEY>        Your amd_live_* API key from app.amdy.io
  -v, --version <N>      Force Vicibox version (7,8,9,10,11,12)
  -o, --os <name>        Force OS (opensuse, centos, debian, ubuntu)
  -3, --360              Install the 360 package variant
  --skip-register        Skip account activation / IP register (install only)
  --portal-base <URL>    Override portal base (default: https://app.amdy.io)
  -h, --help             Show this help

The installer auto-detects OS, Vicibox version, and your public IP. After
installation succeeds, it calls the portal to register this server's IP and
activate your account. No email click required.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    -v|--version) VICIBOX_OVERRIDE="$2"; shift 2 ;;
    -o|--os) OS_OVERRIDE="$2"; shift 2 ;;
    -3|--360) INSTALL_360="1"; shift ;;
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

[ "$EUID" -eq 0 ] || die "Must run as root (try: sudo $0 ...)"
command -v asterisk >/dev/null || die "Asterisk is not installed or not in PATH"

if [ -z "$API_KEY" ] && [ -z "$SKIP_REGISTER" ]; then
  warn "No API key supplied. Get one at https://app.amdy.io/dashboard or pass --skip-register to install without activating."
  die  "Missing API key — re-run with: $0 <YOUR_API_KEY>"
fi

# ---------- OS / Vicibox detection ----------
detect_os() {
  if [ -n "$OS_OVERRIDE" ]; then
    DISTRO="$OS_OVERRIDE"
    log "OS override: $DISTRO"
    return
  fi
  [ -f /etc/os-release ] || die "Cannot detect OS (no /etc/os-release)"
  . /etc/os-release
  DISTRO="$ID"
  log "Detected OS: $NAME $VERSION_ID (id=$DISTRO)"
}

detect_vicibox() {
  if [ -n "$VICIBOX_OVERRIDE" ]; then
    VICIBOX_MAJOR="$VICIBOX_OVERRIDE"
    log "Vicibox version override: $VICIBOX_MAJOR"
    return
  fi
  local raw=""
  if [ -f /etc/vicidial/version ]; then
    raw=$(grep -oE '[0-9]+\.[0-9]+' /etc/vicidial/version | head -1)
  elif [ -f /usr/src/astguiclient/VERSION ]; then
    raw=$(grep -oE '[0-9]+\.[0-9]+' /usr/src/astguiclient/VERSION | head -1)
  fi
  if [ -n "$raw" ]; then
    VICIBOX_MAJOR="${raw%%.*}"
    log "Detected Vicibox version: $raw (major: $VICIBOX_MAJOR)"
  else
    warn "Could not detect Vicibox version, assuming 9+"
    VICIBOX_MAJOR=9
  fi
}

# ---------- Python / pip ----------
install_python() {
  log "Installing Python3 + pip…"
  case "$DISTRO" in
    opensuse-leap|opensuse-tumbleweed|sles|opensuse)
      info "zypper (openSUSE/SLES)"
      # Leap 15.5 and older reached EOL — repos moved to archive or broken
      if [[ "$DISTRO" == "opensuse-leap" ]] && [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$VERSION_ID" =~ ^15\.[0-5]$ ]]; then
          info "Detected EOL Leap $VERSION_ID — disabling broken repos"
          # Disable all known-broken repos on EOL Leap
          zypper mr -d repo-non-oss-updates repo-oss-updates 2>/dev/null || true
          zypper mr -d openSUSE-Leap-${VERSION_ID}-Non-OSS-Updates openSUSE-Leap-${VERSION_ID}-OSS-Updates 2>/dev/null || true
          zypper mr -d openSUSE-Leap-${VERSION_ID}-PERL 2>/dev/null || true
          zypper mr -d openSUSE-Leap-${VERSION_ID}-ViciDial openSUSE-Leap-${VERSION_ID}-ViciDial-ViciBox 2>/dev/null || true
          # Disable any other repos with "15.5" in the name that might be broken
          for repo in $(zypper lr | grep -oE "openSUSE-Leap-${VERSION_ID}-[^ ]+" | sort -u); do
            zypper mr -d "$repo" 2>/dev/null || true
          done
        fi
      fi
      if [ "$VICIBOX_MAJOR" -eq 8 ]; then
        zypper remove -y python3-pip python3-setuptools 2>/dev/null || true
        # Check if already installed to avoid zypper exit codes on broken repos
        if ! rpm -q python3-pip >/dev/null 2>&1; then
          zypper in -y python3-pip || zypper in -y --allow-downgrade python3-pip || true
        else
          info "python3-pip already installed"
        fi
        pip3 install --upgrade pip==19.0.0
      else
        # Check if already installed to avoid zypper exit codes on broken repos
        if ! rpm -q python3-pip >/dev/null 2>&1; then
          zypper in -y python3-pip || zypper in -y --allow-downgrade python3-pip || true
        else
          info "python3-pip already installed"
        fi
        pip3 install --upgrade pip
      fi
      ;;
    centos|rhel|fedora|rocky|almalinux)
      info "yum/dnf (RHEL family)"
      local pm=yum
      command -v dnf >/dev/null && pm=dnf
      $pm -y install curl wget python3 python3-pip
      pip3 install --upgrade pip
      ;;
    ubuntu|debian)
      info "apt (Debian/Ubuntu)"
      apt-get update -y
      apt-get install -y python3-pip curl
      pip3 install --upgrade pip
      ;;
    *)
      die "Unsupported distro: $DISTRO (override with -o opensuse|centos|ubuntu|debian)"
      ;;
  esac
}

install_python_packages() {
  log "Installing Python packages for Vicibox $VICIBOX_MAJOR…"
  case "$VICIBOX_MAJOR" in
    7)
      local base="https://files.pythonhosted.org/packages"
      wget --no-check-certificate -q -O six.whl \
        "$base/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl"
      pip3 install six.whl
      wget --no-check-certificate -q -O pyst2.whl \
        "$base/4a/9a/42c1a187a171807a6b214060544fbd6f4bf4a33bf1428aabaa46befed9dc/pyst2-0.5.1-py3-none-any.whl"
      pip3 install pyst2.whl
      wget --no-check-certificate -q -O wsclient.whl \
        "$base/4c/5f/f61b420143ed1c8dc69f9eaec5ff1ac36109d52c80de49d66e0c36c3dfdf/websocket_client-0.57.0-py2.py3-none-any.whl"
      pip3 install wsclient.whl
      rm -f six.whl pyst2.whl wsclient.whl
      ;;
    8)
      pip3 --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org install \
        pyst2 websocket-client==0.52.0 mysql-connector-python==8.0.5 configparser --upgrade
      ;;
    *)
      pip3 install pyst2 websocket-client mysql-connector-python==8.0.29 configparser --upgrade
      ;;
  esac
}

# ---------- AMD package ----------
download_amd_package() {
  log "Downloading AMD package…"
  rm -f /tmp/amdy*.tar.gz /tmp/amdy*.sha256
  local url sha_url
  if [ -n "$INSTALL_360" ]; then
    url="$DOWNLOAD_BASE/amdy360.tar.gz"
  elif [ "$VICIBOX_MAJOR" = "8" ]; then
    url="$DOWNLOAD_BASE/amdy8.tar.gz"
  else
    url="$DOWNLOAD_BASE/amdy.tar.gz"
  fi
  sha_url="${url}.sha256"

  # HTTPS only; -k so dialers with outdated CA bundles can still fetch (sha256 below).
  curl -fsSLk --proto '=https' --tlsv1.2 -o /tmp/amdy.tar.gz "$url" \
    || die "Failed to download $url"
  curl -fsSLk --proto '=https' --tlsv1.2 -o /tmp/amdy.tar.gz.sha256 "$sha_url" \
    || die "Failed to download sha256 sum from $sha_url"

  # Expected line format: <hex>  <filename>
  local expected actual
  expected=$(awk '{print $1}' /tmp/amdy.tar.gz.sha256 | head -n1)
  [ -n "$expected" ] || die "Empty sha256 file"
  actual=$(sha256sum /tmp/amdy.tar.gz | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then
    die "sha256 mismatch for $url. Expected $expected, got $actual. ABORT — possible tampering."
  fi
  log "sha256 verified: $actual"

  mkdir -p /var/lib/asterisk/agi-bin
  tar -zxf /tmp/amdy.tar.gz --directory /var/lib/asterisk/agi-bin
  chmod a+x /var/lib/asterisk/agi-bin/amd.py
  log "AMD package extracted to /var/lib/asterisk/agi-bin/"
}

# ---------- Local config ----------
write_local_config() {
  log "Writing /etc/amdy/amdy.conf…"
  mkdir -p /etc/amdy
  cat > /etc/amdy/amdy.conf <<EOF
# AMDY.IO config — generated by installamd-v2.sh on $(date -Is)
api_key=${API_KEY}
portal_base=${PORTAL_BASE}
ws_endpoint=ws://api.amdy.io:2700
EOF
  chmod 600 /etc/amdy/amdy.conf
}

# ---------- Asterisk dial-plan ----------
configure_asterisk() {
  log "Configuring Asterisk extensions (Vicibox $VICIBOX_MAJOR)…"
  sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf

  if [ "$VICIBOX_MAJOR" = "7" ]; then
    sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,GotoIf($\[\"${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)\nexten => 8370,n,GotoIf($\[\"${AMDCAUSE}\" = \"CONNECTION_ERROR\" \| \"${AMDCAUSE}\" = \"PROCESSING_ERROR\" \| \"${AMDCAUSE}\" = \"FATAL_ERROR\" \| \"${AMDCAUSE}\" = \"NETERR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallback\:continue)\nexten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n(honeypot),Hangup()\n/g' /etc/asterisk/extensions.conf
  else
    sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,GotoIf($\[\"${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)\nexten => 8370,n,GotoIf($\[\"${AMDCAUSE}\" = \"CONNECTION_ERROR\" \| \"${AMDCAUSE}\" = \"PROCESSING_ERROR\" \| \"${AMDCAUSE}\" = \"FATAL_ERROR\" \| \"${AMDCAUSE}\" = \"NETERR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallback\:continue)\nexten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n(honeypot),Hangup()\n/g' /etc/asterisk/extensions.conf
  fi
  asterisk -rx "reload" >/dev/null || die "asterisk reload failed"
  log "Asterisk reloaded."
}

# ---------- IP register / account activation ----------
detect_public_ip() {
  local ip=""
  ip=$(curl -sk --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(curl -sk --max-time 5 https://ifconfig.me 2>/dev/null || true)
  fi
  if [ -z "$ip" ]; then
    ip=$(curl -sk --max-time 5 https://icanhazip.com 2>/dev/null || true)
  fi
  echo "$ip" | tr -d '\r\n'
}

register_and_activate() {
  [ -n "$SKIP_REGISTER" ] && { warn "Skipping account activation (--skip-register)"; return; }
  log "Detecting public IP…"
  local ip; ip=$(detect_public_ip)
  [ -n "$ip" ] || die "Could not detect public IP. Re-run with --skip-register and add the IP manually in the portal."
  log "Public IP: $ip"

  log "Registering this server with your AMDY.IO account…"
  local resp http body
  local rc tls_opt=""
  for attempt in verified insecure; do
    resp=$(curl -fsS $tls_opt --proto '=https' --tlsv1.2 -w '\n%{http_code}' \
      -X POST "$PORTAL_BASE/api/v1/ips/register" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      --data "{\"ip\":\"$ip\",\"description\":\"$(hostname)\"}"); rc=$?
    # curl 35/51/53/54/58/59/60/77/83 = TLS/certificate problems -> retry once with -k
    case "$rc" in 35|51|53|54|58|59|60|77|83)
      if [ "$attempt" = verified ]; then
        warn "TLS certificate could not be verified (curl rc=$rc) — outdated CA bundle? Retrying register without verification."
        tls_opt="-k"; continue
      fi ;;
    esac
    break
  done
  http=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')

  if [ "$http" = "200" ]; then
    log "Account activated ✓ — IP $ip is bound to your account."
    echo "$body" | head -c 400
    echo
  else
    warn "Register API returned HTTP $http"
    echo "$body" | head -c 400
    echo
    warn "Install is complete but account is NOT activated. Verify your API key at https://app.amdy.io/dashboard and re-run register manually."
  fi
}

# ---------- Verification ----------
verify() {
  log "Verifying install…"
  [ -x /var/lib/asterisk/agi-bin/amd.py ] || die "amd.py missing or not executable"
  grep -q "exten => 8370" /etc/asterisk/extensions.conf || die "8370 extension missing"
  [ -f /etc/amdy/amdy.conf ] || warn "/etc/amdy/amdy.conf was not written"
  log "All checks passed."
}

# ---------- Main ----------
main() {
  log "Starting AMDY.IO install v2"
  detect_os
  detect_vicibox
  install_python
  install_python_packages
  download_amd_package
  write_local_config
  configure_asterisk
  verify
  register_and_activate
  log "Done. Calls through extension 8370 are now routed through AMDY.IO."
  log "Dashboard: $PORTAL_BASE/dashboard"
}

main "$@"
