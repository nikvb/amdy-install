#!/bin/bash
# ============================================================================
# AMDY.IO AMD Installer for FreeSWITCH (mod_audio_fork)
# ============================================================================
# Streams call audio from FreeSWITCH to ws://api.amdy.io:2700 using the
# mod_audio_fork module (drachtio). Same audio protocol as the Asterisk
# EAGI client (amd.py):
#   - config frame {"config":{"sample_rate":8000,"VID":<caller id name>}}
#   - raw 8kHz 16-bit mono PCM binary frames
#
# Authentication: mod_audio_fork cannot send custom HTTP headers, so no
# X-API-Key goes on the websocket upgrade. AMDY enforces IP allowlisting
# for fork connections instead. The register_ip step below uses the API
# key to bind this host's public IP to your account. The key is also
# stored in /etc/amdy/api-key for re-runs and tooling.
#
# MODULE SOURCE (read this): there is NO verified download URL for a
# prebuilt mod_audio_fork binary. The upstream repo
# drachtio/drachtio-freeswitch-modules has been deleted. Only community
# clones remain. This installer therefore:
#   1. installs a prebuilt module you pass with --module (recommended), or
#   2. builds from source if a configured FreeSWITCH source tree exists.
# If neither works it fails loudly with instructions. It never downloads a
# module from an unverified URL and never fails silently.
#
# Dialplan + driver: the snippet amdy-fork.xml is copied to
# <conf_dir>/dialplan/ and the driver amdy_fork.lua to the FreeSWITCH
# scripts directory. Both files are also embedded in this script and are
# written out automatically when no on-disk copy is found. FreeSWITCH
# auto-loads any file in conf/dialplan whose root element is <include>.
# See the final instructions printed by this script.
#
# FreeSWITCH runs as root here. We never chown anything to asterisk.
#
# Usage:
#   installamd-freeswitch.sh <API_KEY> [options]
#   installamd-freeswitch.sh --api-key <KEY> --module /path/mod_audio_fork.so
# ============================================================================

set -euo pipefail

API_KEY="${AMDY_API_KEY:-}"
SKIP_REGISTER="0"
PORTAL_BASE="${AMDY_PORTAL_BASE:-https://app.amdy.io}"
MODULE_PATH=""
FS_SRC=""
SNIPPET_PATH=""
SKIP_BUILD="0"
# Set to 1 when the embedded copies of amdy-fork.xml / amdy_fork.lua are
# written out instead of an on-disk copy (see resolve_snippet/resolve_lua).
EMBEDDED_SNIPPET="0"
EMBEDDED_LUA="0"
# Upstream drachtio repo is gone (404). Default below is a verified public
# clone of it. Override with --source-repo if you mirror your own copy.
SOURCE_REPO="${AMDY_SOURCE_REPO:-https://github.com/mdslaney/drachtio-freeswitch-modules.git}"
BUILD_DIR="/usr/src/drachtio-freeswitch-modules"

WS_HOST="api.amdy.io"
WS_PORT="2700"
API_KEY_DIR="/etc/amdy"
API_KEY_FILE="${API_KEY_DIR}/api-key"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[AMDY]${NC} $*"; }
warn() { echo -e "${YELLOW}[AMDY]${NC} $*" >&2; }
err()  { echo -e "${RED}[AMDY]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
AMDY.IO AMD Installer for FreeSWITCH (mod_audio_fork)

Usage:
  bash $0 <API_KEY> [options]
  bash $0 --api-key <KEY> --module /path/to/mod_audio_fork.so

Options:
  --api-key KEY          AMDY.IO API key (from https://app.amdy.io/settings)
  --module PATH          Install this prebuilt mod_audio_fork.so (recommended).
                         No verified prebuilt download URL exists, so bring
                         your own binary if you have one.
  --fs-src PATH          FreeSWITCH source tree (configured) used to build
                         mod_audio_fork from source. Auto-detected at
                         /usr/src/freeswitch or /usr/local/src/freeswitch.
  --source-repo URL      Git repo with mod_audio_fork source.
                         Default: $SOURCE_REPO
                         (upstream drachtio/drachtio-freeswitch-modules is
                         gone. only clones remain)
  --dialplan PATH        Path to the amdy-fork.xml dialplan snippet.
                         Default: ../freeswitch/amdy-fork.xml next to this
                         script, then the copy embedded in this script.
                         (development path: /home/na/amdy.io/freeswitch/)
  --skip-build           Do not attempt the build-from-source path.
  --skip-register        Skip IP registration with the portal.
  --portal-base URL      Override portal base (default: https://app.amdy.io)
  -h, --help             Show this help

The module build-from-source path requires a configured FreeSWITCH source
tree plus libwebsockets headers. See build_module_from_source() in this
script for the exact steps performed.
EOF
}

# ---------- Arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --module) MODULE_PATH="$2"; shift 2 ;;
    --fs-src) FS_SRC="$2"; shift 2 ;;
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --dialplan) SNIPPET_PATH="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="1"; shift ;;
    --skip-register) SKIP_REGISTER="1"; shift ;;
    --portal-base) PORTAL_BASE="$2"; shift 2 ;;
    -*) die "Unknown option: $1 (see --help)" ;;
    *)
      if [ -z "$API_KEY" ]; then
        API_KEY="$1"; shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

# ---------- Preflight ----------
[ "$(id -u)" -eq 0 ] || die "This script must be run as root."

if [ -z "$API_KEY" ] && [ "$SKIP_REGISTER" = "0" ]; then
  warn "No API key supplied. Get one at https://app.amdy.io/settings"
  die "Missing API key. Re-run with: $0 <YOUR_API_KEY> or pass --skip-register to install without activating."
fi

# ---------- FreeSWITCH detection ----------
FS_CLI=""
FS_CONF_DIR=""
FS_MOD_DIR=""
FS_SCRIPTS_DIR=""

find_fs_cli() {
  if command -v fs_cli >/dev/null 2>&1; then
    FS_CLI="fs_cli"
  elif [ -x /usr/local/freeswitch/bin/fs_cli ]; then
    FS_CLI="/usr/local/freeswitch/bin/fs_cli"
  fi
}

# Run one fs_cli command. Prints output, returns nonzero on failure.
# The ${pw_args[@]+...} form keeps set -u from aborting on bash < 4.4
# when the array is empty.
fs_cmd() {
  local pw_args=()
  [ -n "${FS_ESL_PASSWORD:-}" ] && pw_args=(-P "$FS_ESL_PASSWORD")
  timeout 10 "$FS_CLI" "${pw_args[@]+"${pw_args[@]}"}" -x "$1" 2>/dev/null
}

detect_esl_password() {
  # fs_cli needs the event socket password. Read it from event_socket.xml.
  local f="${FS_CONF_DIR:-/etc/freeswitch}/autoload_configs/event_socket.xml"
  [ -f "$f" ] || return 0
  FS_ESL_PASSWORD=$(sed -n 's/.*name="password"[^>]*value="\([^"]*\)".*/\1/p' "$f" | head -1)
  export FS_ESL_PASSWORD
}

fs_global_var() {
  # global_getvar prints the bare value, not "name=value".
  local out
  out=$(fs_cmd "global_getvar $1" 2>/dev/null || true)
  out=$(echo "$out" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$out" ] || [ "${out#-ERR}" != "$out" ]; then
    return 1
  fi
  echo "$out"
}

detect_freeswitch() {
  log "Detecting FreeSWITCH..."
  find_fs_cli

  if [ -z "$FS_CLI" ] && ! command -v freeswitch >/dev/null 2>&1; then
    die "FreeSWITCH not found (no fs_cli, no freeswitch binary). Install FreeSWITCH first."
  fi

  # Try the running server first. It knows its own directories.
  if [ -n "$FS_CLI" ]; then
    detect_esl_password
    local conf mod
    conf=$(fs_global_var conf_dir || true)
    mod=$(fs_global_var mod_dir || true)
    if [ -n "$conf" ] && [ -d "$conf" ]; then
      FS_CONF_DIR="$conf"
    fi
    if [ -n "$mod" ] && [ -d "$mod" ]; then
      FS_MOD_DIR="$mod"
    fi
  fi

  # Filesystem probes for packaged and source installs.
  if [ -z "$FS_CONF_DIR" ]; then
    for d in /etc/freeswitch /usr/local/freeswitch/conf; do
      if [ -d "$d/dialplan" ]; then FS_CONF_DIR="$d"; break; fi
    done
  fi
  if [ -z "$FS_MOD_DIR" ]; then
    for d in /usr/lib/freeswitch/mod /usr/lib64/freeswitch/mod /usr/local/freeswitch/mod; do
      if [ -d "$d" ]; then FS_MOD_DIR="$d"; break; fi
    done
  fi

  # Re-read the event socket password now that FS_CONF_DIR is resolved.
  # The pass above ran before FS_CONF_DIR was known and could only probe
  # /etc/freeswitch.
  if [ -n "$FS_CLI" ]; then
    detect_esl_password
  fi

  [ -n "$FS_CONF_DIR" ] || die "Could not locate the FreeSWITCH conf directory (looked in /etc/freeswitch, /usr/local/freeswitch/conf)."
  [ -n "$FS_MOD_DIR" ] || die "Could not locate the FreeSWITCH module directory (looked in /usr/lib/freeswitch/mod, /usr/lib64/freeswitch/mod, /usr/local/freeswitch/mod)."
  log "FreeSWITCH conf dir: $FS_CONF_DIR"
  log "FreeSWITCH mod dir:  $FS_MOD_DIR"
}

# ---------- mod_audio_fork ----------
install_module_file() {
  # $1 = path to mod_audio_fork.so
  local src="$1"
  [ -f "$src" ] || die "Module file not found: $src"
  [ -s "$src" ] || die "Module file is empty: $src"
  cp "$src" "$FS_MOD_DIR/mod_audio_fork.so"
  chmod 644 "$FS_MOD_DIR/mod_audio_fork.so"
  log "Installed $src -> $FS_MOD_DIR/mod_audio_fork.so"
}

module_fallback_help() {
  err "mod_audio_fork is not installed and could not be built automatically."
  err ""
  err "There is no verified prebuilt download URL for this module (the upstream"
  err "drachtio repo was deleted). To finish the install, do ONE of:"
  err ""
  err "  A) Provide a prebuilt module matching this FreeSWITCH version:"
  err "       $0 --api-key <KEY> --module /path/to/mod_audio_fork.so"
  err ""
  err "  B) Build from source. You need a configured FreeSWITCH source tree"
  err "     and libwebsockets headers. Steps this installer performs with --fs-src:"
  err "       1. apt-get install git build-essential libwebsockets-dev   (Debian/Ubuntu)"
  err "          dnf install git gcc gcc-c++ make libwebsockets-devel    (CentOS/Rocky/Alma)"
  err "       2. git clone $SOURCE_REPO"
  err "       3. cp -r <clone>/modules/mod_audio_fork <FS_SRC>/src/mod/applications/"
  err "       4. add 'applications/mod_audio_fork' to <FS_SRC>/modules.conf"
  err "       5. cd <FS_SRC> && make mod_audio_fork-install"
  err "     Then re-run: $0 --api-key <KEY> --fs-src <FS_SRC>"
  die "Module installation failed. See instructions above."
}

build_module_from_source() {
  log "Attempting build of mod_audio_fork from source..."

  # Locate a configured FreeSWITCH source tree.
  local src=""
  for d in "$FS_SRC" /usr/src/freeswitch /usr/local/src/freeswitch; do
    [ -n "$d" ] || continue
    if [ -d "$d/src/mod/applications" ]; then src="$d"; break; fi
  done
  if [ -z "$src" ]; then
    warn "No FreeSWITCH source tree found (checked ${FS_SRC:-unset}, /usr/src/freeswitch, /usr/local/src/freeswitch)."
    return 1
  fi
  if [ ! -f "$src/Makefile" ]; then
    warn "FreeSWITCH source tree at $src is not configured (no Makefile). Run ./configure there first."
    return 1
  fi

  # Build dependencies per distro family.
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing build dependencies (apt)..."
    apt-get update -y
    apt-get install -y git build-essential pkg-config libwebsockets-dev
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing build dependencies (dnf)..."
    dnf install -y git gcc gcc-c++ make pkgconfig libwebsockets-devel
  elif command -v yum >/dev/null 2>&1; then
    log "Installing build dependencies (yum)..."
    yum install -y git gcc gcc-c++ make pkgconfig libwebsockets-devel
  else
    warn "Unknown package manager. Install git, a C toolchain, and libwebsockets headers manually."
    return 1
  fi

  log "Cloning $SOURCE_REPO ..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$SOURCE_REPO" "$BUILD_DIR" || { warn "git clone failed."; return 1; }
  [ -d "$BUILD_DIR/modules/mod_audio_fork" ] || { warn "Clone has no modules/mod_audio_fork directory."; return 1; }

  log "Copying module into $src/src/mod/applications/ ..."
  rm -rf "$src/src/mod/applications/mod_audio_fork"
  cp -r "$BUILD_DIR/modules/mod_audio_fork" "$src/src/mod/applications/"

  if ! grep -q '^applications/mod_audio_fork$' "$src/modules.conf" 2>/dev/null; then
    echo 'applications/mod_audio_fork' >> "$src/modules.conf"
    log "Enabled applications/mod_audio_fork in modules.conf"
  fi

  log "Building (make mod_audio_fork-install). This can take several minutes..."
  if ! make -C "$src" mod_audio_fork-install; then
    warn "make mod_audio_fork-install failed. Check the compiler output above."
    return 1
  fi

  [ -f "$FS_MOD_DIR/mod_audio_fork.so" ] || { warn "Build finished but $FS_MOD_DIR/mod_audio_fork.so not found. moddir mismatch between source tree and install."; return 1; }
  log "Built and installed $FS_MOD_DIR/mod_audio_fork.so"
  return 0
}

install_module() {
  log "Installing mod_audio_fork..."

  if [ -n "$MODULE_PATH" ]; then
    install_module_file "$MODULE_PATH"
  elif [ -f "$FS_MOD_DIR/mod_audio_fork.so" ]; then
    log "mod_audio_fork.so already present in $FS_MOD_DIR, keeping it."
  elif [ "$SKIP_BUILD" = "1" ]; then
    module_fallback_help
  else
    build_module_from_source || module_fallback_help
  fi

  # Autoload on every FreeSWITCH start.
  local modxml="$FS_CONF_DIR/autoload_configs/modules.conf.xml"
  if [ -f "$modxml" ]; then
    if ! grep -q 'mod_audio_fork' "$modxml"; then
      sed -i 's|</modules>|  <load module="mod_audio_fork"/>\n  </modules>|' "$modxml"
      log "Added mod_audio_fork to $modxml"
    else
      log "mod_audio_fork already listed in $modxml"
    fi
  else
    warn "$modxml not found. Add <load module=\"mod_audio_fork\"/> to your modules config manually."
  fi
}

# ---------- API key ----------
install_api_key() {
  [ -n "$API_KEY" ] || { warn "No API key given, skipping $API_KEY_FILE (re-run with an API key later)."; return 0; }
  log "Storing API key in $API_KEY_FILE ..."
  mkdir -p "$API_KEY_DIR"
  printf '%s' "$API_KEY" > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  chown root:root "$API_KEY_FILE"
  log "API key stored (mode 600, root:root)."
}

# ---------- Embedded copies ----------
# The dialplan snippet and the Lua driver are embedded here so the
# installer also works standalone (curl | bash on a bare customer host).
# They are written out only when no on-disk copy is found.

write_embedded_dialplan() {
  cat <<'AMDY_EMBEDDED_DIALPLAN_EOF'
<include>
  <!--
    AMDY Answering Machine Detection (AMD) for FreeSWITCH.

    Streams caller audio to the AMDY WebSocket service through the drachtio
    mod_audio_fork module, waits (bounded) for a classification, then routes:

      HUMAN   bridge to amdy_bridge_target
      MACHINE transfer to amdy_voicemail_extension in amdy_voicemail_context
      FAS     hangup CALL_REJECTED
      TIMEOUT hangup RECOVERY_ON_TIMER_EXPIRE
      ERROR   hangup NETWORK_OUT_OF_ORDER

    Requirements: mod_audio_fork (drachtio) and mod_lua loaded, and
    amdy_fork.lua installed in the FreeSWITCH scripts directory. See
    README.md in this folder for install, configuration, and testing.

    Protocol notes, verified against the drachtio mod_audio_fork module
    source:
      The module interface is the uuid_audio_fork API command, not a
      dialplan application named "fork" (no such app is registered in the
      upstream source). Argument order for start is:
        uuid_audio_fork <uuid> start <ws-url> <mono|mixed|stereo> <8k|16k> [bugname] [metadata]
      amdy_fork.lua drives this API and waits for the mod_audio_fork custom
      events the module fires for text frames received from the server.

    The caller hears silence while AMDY analyzes the call. If you want a
    comfort announcement, insert a playback action between "answer" and
    "lua" below.
  -->
  <context name="amdy">

    <!--
      Entry point. Route calls here (destination_number 8370) after setting
      amdy_bridge_target, amdy_voicemail_extension and amdy_voicemail_context.
      Optional: amdy_ws_url, amdy_max_wait_ms, amdy_vid. See README.md.
    -->
    <extension name="amdy">
      <condition field="destination_number" expression="^8370$">
        <!-- 1. Answer. Media must be flowing before the fork attaches. -->
        <action application="answer"/>

        <!--
          2 and 3. Fork read-direction mono 8000 Hz audio to AMDY with the
          config frame as metadata, then wait for a classification (bounded
          by amdy_max_wait_ms, default 10000). Sets amdy_result, amdy_cause
          and amdy_stats on the channel.
        -->
        <action application="lua" data="amdy_fork.lua"/>

        <!-- 4. Branch on the classification. -->
        <action application="log" data="NOTICE amdy: uuid=${uuid} result=${amdy_result} cause=${amdy_cause} stats=${amdy_stats}"/>
        <action application="transfer" data="amdy_dispatch_${amdy_result} XML amdy"/>
      </condition>
    </extension>

    <!-- HUMAN without a bridge target: configuration error, say so. -->
    <extension name="amdy-dispatch-human-no-target">
      <condition field="destination_number" expression="^amdy_dispatch_HUMAN$"/>
      <condition field="${amdy_bridge_target}" expression="^$">
        <action application="log" data="ERR amdy: HUMAN detected but amdy_bridge_target is not set"/>
        <action application="hangup" data="INCOMPATIBLE_DESTINATION"/>
      </condition>
    </extension>

    <!-- HUMAN: bridge onward. -->
    <extension name="amdy-dispatch-human">
      <condition field="destination_number" expression="^amdy_dispatch_HUMAN$">
        <action application="log" data="NOTICE amdy: HUMAN detected, bridging to ${amdy_bridge_target}"/>
        <action application="bridge" data="${amdy_bridge_target}"/>
        <!-- Reached only if the bridge fails or the call has ended. -->
        <action application="hangup" data="NORMAL_CLEARING"/>
      </condition>
    </extension>

    <!-- MACHINE without a voicemail extension: configuration error, say so. -->
    <extension name="amdy-dispatch-machine-no-vm">
      <condition field="destination_number" expression="^amdy_dispatch_MACHINE$"/>
      <condition field="${amdy_voicemail_extension}" expression="^$">
        <action application="log" data="ERR amdy: MACHINE detected but amdy_voicemail_extension is not set"/>
        <action application="hangup" data="INCOMPATIBLE_DESTINATION"/>
      </condition>
    </extension>

    <!-- MACHINE without a voicemail context: configuration error, say so. -->
    <extension name="amdy-dispatch-machine-no-vm-context">
      <condition field="destination_number" expression="^amdy_dispatch_MACHINE$"/>
      <condition field="${amdy_voicemail_context}" expression="^$">
        <action application="log" data="ERR amdy: MACHINE detected but amdy_voicemail_context is not set"/>
        <action application="hangup" data="INCOMPATIBLE_DESTINATION"/>
      </condition>
    </extension>

    <!-- MACHINE: hand the call to the voicemail message extension. -->
    <extension name="amdy-dispatch-machine">
      <condition field="destination_number" expression="^amdy_dispatch_MACHINE$">
        <action application="log" data="NOTICE amdy: MACHINE detected, transferring to voicemail ${amdy_voicemail_extension} in context ${amdy_voicemail_context}"/>
        <action application="transfer" data="${amdy_voicemail_extension} XML ${amdy_voicemail_context}"/>
      </condition>
    </extension>

    <!-- FAS (false answer supervision): hangup with a descriptive cause. -->
    <extension name="amdy-dispatch-fas">
      <condition field="destination_number" expression="^amdy_dispatch_FAS$">
        <action application="log" data="WARNING amdy: FAS detected, hanging up"/>
        <action application="hangup" data="CALL_REJECTED"/>
      </condition>
    </extension>

    <!-- No classification within the wait window. -->
    <extension name="amdy-dispatch-timeout">
      <condition field="destination_number" expression="^amdy_dispatch_TIMEOUT$">
        <action application="log" data="WARNING amdy: no classification within the wait window, hanging up"/>
        <action application="hangup" data="RECOVERY_ON_TIMER_EXPIRE"/>
      </condition>
    </extension>

    <!-- Fork start failure, server error, or connection lost. -->
    <extension name="amdy-dispatch-error">
      <condition field="destination_number" expression="^amdy_dispatch_ERROR$">
        <action application="log" data="ERR amdy: AMD error, hanging up (see amdy_cause and amdy_stats)"/>
        <action application="hangup" data="NETWORK_OUT_OF_ORDER"/>
      </condition>
    </extension>

    <!-- Catch-all: empty or unexpected amdy_result. -->
    <extension name="amdy-dispatch-unknown">
      <condition field="destination_number" expression="^amdy_dispatch_">
        <action application="log" data="ERR amdy: unhandled classification '${amdy_result}', hanging up"/>
        <action application="hangup" data="NORMAL_TEMPORARY_FAILURE"/>
      </condition>
    </extension>

  </context>
</include>
AMDY_EMBEDDED_DIALPLAN_EOF
}

write_embedded_lua() {
  cat <<'AMDY_EMBEDDED_LUA_EOF'
--
-- amdy_fork.lua
--
-- AMDY answering machine detection driver for FreeSWITCH, called from the
-- "amdy" dialplan extension after the call is answered.
--
-- What it does:
--   1. Attaches a mod_audio_fork media bug streaming caller audio (mono,
--      8000 Hz, 16 bit linear) to the AMDY WebSocket endpoint. The AMDY
--      config frame is sent as the fork metadata text frame:
--        {"config":{"sample_rate":8000,"VID":"<caller_id_name or Unknown>"}}
--      VID maps to the Asterisk AGI field agi_calleridname; its FreeSWITCH
--      equivalent is caller_id_name.
--   2. Waits up to amdy_max_wait_ms (default 10000) for a classification
--      text frame from AMDY. Same precedence as amd.py (HUMAN, then
--      AMD/MACHINE), plus an explicit FAS branch that amd.py reaches only
--      via the AMD substring in FASAMD. Any other response means AMDY
--      wants more audio, so waiting continues.
--   3. Stops the fork, sending {"eof":1} as the final text frame (the EOF
--      frame the AMDY protocol expects).
--   4. Sets channel variables for the dialplan to branch on:
--        amdy_result  HUMAN | MACHINE | FAS | TIMEOUT | ERROR
--        amdy_cause   short marker or error label
--        amdy_stats   raw server response body, if one arrived
--
-- Wire protocol caveats (see README.md, Known seams):
--   * mod_audio_fork parses every received text frame as JSON. Non-JSON
--     frames are dropped, and in the reference build valid JSON without a
--     recognized type field is dropped too. Frames with
--     "type":"transcription" fire mod_audio_fork::transcription; some
--     builds also fire mod_audio_fork::json for valid JSON without a
--     recognized type. If the AMDY server replies with non-JSON text on
--     this connection, the module drops the frames and this script times
--     out.
--   * Upstream mod_audio_fork cannot add custom HTTP headers to the
--     WebSocket upgrade, so no X-API-Key goes out on this connection.
--     AMDY authenticates fork connections by IP allowlist; the installer
--     (installamd-freeswitch.sh) registers this host's public IP against
--     the account.
--

local log = freeswitch.consoleLog

local function set_result(session, result, cause, stats)
  session:setVariable("amdy_result", result)
  session:setVariable("amdy_cause", cause or "")
  session:setVariable("amdy_stats", stats or "")
end

local uuid = session:getVariable("uuid")
if not uuid or uuid == "" then
  log("ERR", "amdy: could not resolve channel uuid, aborting\n")
  return
end

local ws_url = session:getVariable("amdy_ws_url") or "ws://api.amdy.io:2700"
local max_wait_ms = tonumber(session:getVariable("amdy_max_wait_ms")) or 10000
if max_wait_ms < 1000 then max_wait_ms = 1000 end
if max_wait_ms > 30000 then max_wait_ms = 30000 end

-- VID identity field: caller_id_name, "Unknown" when absent or empty,
-- same fallback as the ViciDial client.
local vid = session:getVariable("amdy_vid") or session:getVariable("caller_id_name") or ""
-- uuid_audio_fork splits its command line on spaces and the metadata must
-- stay valid JSON, so strip control characters, quotes, braces and
-- backslashes from the VID first, then map whitespace to underscores.
vid = vid:gsub('[%c"{}%[%]\\]', "")
vid = vid:gsub("%s", "_")
if vid == "" then vid = "Unknown" end

local metadata = '{"config":{"sample_rate":8000,"VID":"' .. vid .. '"}}'
local api = freeswitch.API()

-- Subscribe before starting the fork so an early response is not missed.
-- Binding to CUSTOM with no subclass receives every custom event; the loop
-- below filters on Unique-ID and Event-Subclass.
local consumer = freeswitch.EventConsumer("CUSTOM")

local cmd = "uuid_audio_fork " .. uuid .. " start " .. ws_url .. " mono 8k " .. metadata
local reply = api:executeString(cmd)
log("NOTICE", "amdy: fork start uuid=" .. uuid .. " url=" .. ws_url .. " reply=" .. tostring(reply) .. "\n")
if not reply or reply:sub(1, 3) ~= "+OK" then
  set_result(session, "ERROR", "FORK_START_FAILED", reply or "")
  return
end

local result, cause, stats = nil, nil, nil

-- Track real elapsed time. The consumer receives every CUSTOM event on the
-- system, most of which are not ours, and pop can return instantly for
-- unrelated events. Charging a fixed slice per pop would either overshoot
-- the budget or burn it on noise, so budget against the clock instead.
local start_time = os.time()
local deadline = start_time + math.ceil(max_wait_ms / 1000)

while os.time() < deadline and not result do
  local remaining = deadline - os.time()
  if remaining < 1 then remaining = 1 end
  local event = consumer:pop(1, remaining)

  if event then
    local ev_uuid = event:getHeader("Unique-ID")
    local subclass = event:getHeader("Event-Subclass")
    if ev_uuid == uuid and subclass then
      if subclass == "mod_audio_fork::transcription" or subclass == "mod_audio_fork::json" then
        local body = event:getBody() or ""
        stats = body
        if body:find("HUMAN", 1, true) then
          result, cause = "HUMAN", "HUMAN"
        elseif body:find("AMD", 1, true) or body:find("MACHINE", 1, true) then
          result, cause = "MACHINE", "MACHINE"
        elseif body:find("FAS", 1, true) then
          result, cause = "FAS", "FAS"
        end
        -- No marker yet: AMDY wants more audio. Keep waiting.
      elseif subclass == "mod_audio_fork::error" then
        result, cause, stats = "ERROR", "SERVER_ERROR", event:getBody() or ""
      elseif subclass == "mod_audio_fork::connect_fail" or subclass == "mod_audio_fork::connect_failed" then
        result, cause, stats = "ERROR", "CONNECTION_REFUSED", event:getBody() or ""
      elseif subclass == "mod_audio_fork::disconnect" then
        result, cause, stats = "ERROR", "CONNECTION_LOST", event:getBody() or ""
      end
    end
  end
end

if not result then
  result, cause = "TIMEOUT", "AUDIO_TIMEOUT"
end

-- Stop streaming and send the EOF frame the AMDY protocol expects. The bug
-- may already be gone; a -ERR reply here is harmless.
api:executeString('uuid_audio_fork ' .. uuid .. ' stop {"eof":1}')

set_result(session, result, cause, stats)
local waited_ms = (os.time() - start_time) * 1000
log("NOTICE", string.format("amdy: uuid=%s result=%s cause=%s waited=%dms\n", uuid, result, tostring(cause), waited_ms))
AMDY_EMBEDDED_LUA_EOF
}

# ---------- Dialplan snippet ----------
# Sets RESOLVED_SNIPPET (and EMBEDDED_SNIPPET when the embedded copy was
# written out). Returns via globals because callers must see the flags; a
# $(...) subshell would swallow them.
resolve_snippet() {
  RESOLVED_SNIPPET=""
  if [ -n "$SNIPPET_PATH" ] && [ -f "$SNIPPET_PATH" ]; then
    RESOLVED_SNIPPET="$SNIPPET_PATH"
    return 0
  fi
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -f "$script_dir/../freeswitch/amdy-fork.xml" ]; then
    RESOLVED_SNIPPET="$script_dir/../freeswitch/amdy-fork.xml"
    return 0
  fi
  # Development path (kept last among the on-disk candidates).
  if [ -f /home/na/amdy.io/freeswitch/amdy-fork.xml ]; then
    RESOLVED_SNIPPET=/home/na/amdy.io/freeswitch/amdy-fork.xml
    return 0
  fi
  # Embedded fallback: no on-disk copy found, write the bundled copy out.
  local tmp
  tmp=$(mktemp) || return 1
  if write_embedded_dialplan > "$tmp"; then
    EMBEDDED_SNIPPET=1
    RESOLVED_SNIPPET="$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

install_dialplan() {
  log "Installing AMDY dialplan snippet..."
  if ! resolve_snippet; then
    die "amdy-fork.xml not found and the embedded copy could not be written. Pass --dialplan /path/to/amdy-fork.xml"
  fi
  local src="$RESOLVED_SNIPPET"

  cp "$src" "$FS_CONF_DIR/dialplan/amdy-fork.xml"
  chmod 644 "$FS_CONF_DIR/dialplan/amdy-fork.xml"
  log "Installed $src -> $FS_CONF_DIR/dialplan/amdy-fork.xml"

  # FreeSWITCH (mod_dialplan_xml) parses every *.xml directly under
  # conf/dialplan, provided the root element is <include>.
  if grep -q '<include>' "$FS_CONF_DIR/dialplan/amdy-fork.xml" || \
     grep -q '<include[[:space:]]' "$FS_CONF_DIR/dialplan/amdy-fork.xml"; then
    log "Snippet has an <include> root. It is auto-loaded from conf/dialplan."
  else
    warn "Snippet does not have an <include> root element, so it will NOT be auto-loaded."
    warn "Either wrap it in <include>...</include>, or add this line inside the"
    warn "matching context file (for example default.xml or public.xml):"
    warn "  <X-PRE-PROCESS cmd=\"include\" data=\"amdy-fork.xml\"/>"
  fi
}

# ---------- Lua driver script ----------
detect_scripts_dir() {
  # The running server knows its own scripts_dir.
  if [ -n "$FS_CLI" ]; then
    local sd
    sd=$(fs_global_var scripts_dir || true)
    if [ -n "$sd" ] && [ -d "$sd" ]; then
      FS_SCRIPTS_DIR="$sd"
      return 0
    fi
  fi
  local d
  for d in "$FS_CONF_DIR/../scripts" /usr/share/freeswitch/scripts /usr/local/freeswitch/scripts; do
    if [ -d "$d" ]; then
      FS_SCRIPTS_DIR="$d"
      return 0
    fi
  done
  return 1
}

resolve_lua() {
  # Same resolution order as resolve_snippet, for amdy_fork.lua. Sets
  # RESOLVED_LUA (and EMBEDDED_LUA when the embedded copy was written out).
  RESOLVED_LUA=""
  if [ -n "$SNIPPET_PATH" ]; then
    local d
    d=$(dirname "$SNIPPET_PATH")
    if [ -f "$d/amdy_fork.lua" ]; then
      RESOLVED_LUA="$d/amdy_fork.lua"
      return 0
    fi
  fi
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -f "$script_dir/../freeswitch/amdy_fork.lua" ]; then
    RESOLVED_LUA="$script_dir/../freeswitch/amdy_fork.lua"
    return 0
  fi
  # Development path (kept last among the on-disk candidates).
  if [ -f /home/na/amdy.io/freeswitch/amdy_fork.lua ]; then
    RESOLVED_LUA=/home/na/amdy.io/freeswitch/amdy_fork.lua
    return 0
  fi
  # Embedded fallback: no on-disk copy found, write the bundled copy out.
  local tmp
  tmp=$(mktemp) || return 1
  if write_embedded_lua > "$tmp"; then
    EMBEDDED_LUA=1
    RESOLVED_LUA="$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

install_lua() {
  log "Installing amdy_fork.lua..."
  if ! detect_scripts_dir; then
    die "Could not locate the FreeSWITCH scripts directory (checked scripts_dir via fs_cli, $FS_CONF_DIR/../scripts, /usr/share/freeswitch/scripts, /usr/local/freeswitch/scripts). Create it, then re-run."
  fi
  if ! resolve_lua; then
    die "amdy_fork.lua not found and the embedded copy could not be written. Place it next to amdy-fork.xml or pass --dialplan /path/to/amdy-fork.xml"
  fi
  local src="$RESOLVED_LUA"
  cp "$src" "$FS_SCRIPTS_DIR/amdy_fork.lua"
  chmod 644 "$FS_SCRIPTS_DIR/amdy_fork.lua"
  log "Installed $src -> $FS_SCRIPTS_DIR/amdy_fork.lua"
}

# ---------- IP registration ----------
get_public_ip() {
  local ip=""
  for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return
    fi
  done
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-unknown}"
}

register_ip() {
  if [ "$SKIP_REGISTER" = "1" ]; then
    warn "Skipping IP registration (--skip-register)."
    return 0
  fi
  [ -n "$API_KEY" ] || { warn "No API key, skipping IP registration."; return 0; }

  local public_ip
  public_ip=$(get_public_ip)
  log "Public IP: $public_ip"
  if [ "$public_ip" = "unknown" ]; then
    warn "Could not detect public IP. Add this server's IP manually at https://app.amdy.io/settings"
    return 0
  fi

  log "Registering IP $public_ip with your AMDY.IO account..."
  # Strip quotes and backslashes so the hostname cannot break the JSON body.
  local host_label
  host_label=$(hostname | tr -d '"\\')
  local resp http body
  resp=$(curl -s -w "\n%{http_code}" \
    -X POST "$PORTAL_BASE/api/v1/ips/register" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data "{\"ip\":\"$public_ip\",\"description\":\"$host_label freeswitch\"}")
  http=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')

  if [ "$http" = "200" ]; then
    log "Account activated. IP $public_ip is bound to your account."
  else
    warn "Register API returned HTTP $http"
    echo "$body" | head -c 400
    echo
    warn "Install is complete but the account may NOT be activated. Verify your API key at https://app.amdy.io/settings and add IP $public_ip there."
  fi
}

# ---------- Verification ----------
check_endpoint() {
  log "Verifying websocket endpoint $WS_HOST:$WS_PORT ..."
  if getent hosts "$WS_HOST" >/dev/null 2>&1; then
    log "DNS: $WS_HOST resolves."
  else
    die "DNS failure: $WS_HOST does not resolve on this host. AMDY cannot work until it does."
  fi
  if timeout 5 bash -c "exec 3<>/dev/tcp/$WS_HOST/$WS_PORT" 2>/dev/null; then
    log "TCP: $WS_HOST:$WS_PORT is reachable."
  else
    warn "TCP connect to $WS_HOST:$WS_PORT failed. Check outbound firewall rules."
  fi
}

verify_installation() {
  log "Verifying installation..."
  check_endpoint

  [ -f "$FS_MOD_DIR/mod_audio_fork.so" ] || die "$FS_MOD_DIR/mod_audio_fork.so is missing."

  if [ -z "$FS_CLI" ]; then
    warn "fs_cli not found. Cannot verify module load now."
    warn "Start FreeSWITCH, then run: check-amdy-freeswitch.sh"
    return 0
  fi

  if ! fs_cmd "status" >/dev/null 2>&1; then
    warn "FreeSWITCH is not reachable over the event socket (is it running?)."
    warn "Start FreeSWITCH, then run: check-amdy-freeswitch.sh"
    return 0
  fi

  fs_cmd "reloadxml" >/dev/null || warn "reloadxml failed"

  local exists
  exists=$(fs_cmd "module_exists mod_audio_fork" || true)
  if [ "$exists" != "true" ]; then
    log "Module not loaded yet, trying: load mod_audio_fork"
    fs_cmd "load mod_audio_fork" || true
    exists=$(fs_cmd "module_exists mod_audio_fork" || true)
  fi
  if [ "$exists" = "true" ]; then
    log "mod_audio_fork is loaded."
  else
    die "mod_audio_fork failed to load. Check 'fs_cli -x console loglevel debug' output. A version mismatch between the module and FreeSWITCH is the usual cause."
  fi

  local dp
  dp=$(fs_cmd "xml_locate dialplan context name amdy" || true)
  if echo "$dp" | grep -q '<'; then
    log "Dialplan context 'amdy' is present in the parsed XML."
  else
    warn "Dialplan context 'amdy' not found. Check that amdy-fork.xml defines it, or move the include per the instructions above."
  fi
}

# ---------- Main ----------
main() {
  echo ""
  echo -e "${BLUE}============================================================================${NC}"
  echo -e "${BLUE} AMDY.IO AMD Installer for FreeSWITCH (mod_audio_fork)${NC}"
  echo -e "${BLUE}============================================================================${NC}"
  echo ""

  detect_freeswitch
  install_module
  install_api_key
  install_dialplan
  install_lua
  register_ip
  verify_installation

  echo ""
  echo -e "${GREEN}============================================================================${NC}"
  echo -e "${GREEN} AMDY.IO FreeSWITCH integration installed${NC}"
  echo -e "${GREEN}============================================================================${NC}"
  echo ""
  echo "  Module:      $FS_MOD_DIR/mod_audio_fork.so"
  echo "  Dialplan:    $FS_CONF_DIR/dialplan/amdy-fork.xml"
  echo "  Lua script:  $FS_SCRIPTS_DIR/amdy_fork.lua"
  echo "  API key:     $API_KEY_FILE"
  echo "  WS endpoint: ws://$WS_HOST:$WS_PORT"
  if [ "$EMBEDDED_SNIPPET" = "1" ] || [ "$EMBEDDED_LUA" = "1" ]; then
    echo ""
    echo "  Note: no on-disk snippet was found, so the copies embedded in this"
    echo "  installer were written out instead."
  fi
  echo ""
  echo "Next steps:"
  echo "  1. Reload the dialplan:  fs_cli -x reloadxml"
  echo "  2. Health check:         bash \"$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/check-amdy-freeswitch.sh\""
  echo "  3. Route a test call through the 'amdy' context and watch:"
  echo "       fs_cli -x 'console loglevel debug'"
  echo ""
  echo "Docs:    $PORTAL_BASE/docs/api"
  echo "Support: support@amdy.io"
  echo ""
}

main "$@"
