#!/bin/bash

# installamd-audio.sh
#
# Installs amd_playback.py (v2.3) as /var/lib/asterisk/agi-bin/amd.py — the
# AGI variant that plays an insert audio file to the caller at the 2-second
# mark via agi.stream_file(), while continuing to read EAGI FD 3 for AMD
# detection. The audio source is fetched from http://download.amdy.io/<name>
# and installed as /var/lib/asterisk/sounds/amdy/insert.wav (filename is
# hardcoded by amd_playback.py as PLAYBACK_FILE = "insert").
#
# Defaults:
#   - dialplan is NOT modified — the server's existing 8370 block is the
#     source of truth. Pass --dialplan to write a fresh block.
#   - audio is copied verbatim (RIFF/WAV magic-checked). Pass --normalize
#     to re-encode to 8 kHz mono 16-bit PCM, or --strip-silence to also
#     trim silence (implies --normalize). Those flags pull in ffmpeg+sox
#     on demand; without them the installer has no ffmpeg/sox dependency.
#
# Usage:
#   installamd-audio.sh --audio ambiguous.wav
#   installamd-audio.sh --audio insert.wav --strip-silence
#   installamd-audio.sh --audio https://example.com/foo.mp3 --normalize
#   installamd-audio.sh --audio raw.mp3 --strip-silence --dialplan
#
# Based on the conventions in installamd-unified.sh.

set -euo pipefail

# ---- defaults ----
AUDIO_ARG=""
DOWNLOAD_HOST="download.amdy.io"
# amd_playback.py (v2.3) tarball: ships amd_playback.py + install_amd_playback.sh.
# This is the variant with in-AGI insert.wav playback at the 2-second mark.
AMDY_TARBALL_URL="http://${DOWNLOAD_HOST}/amd_playback.tar.gz"
AMDY_TARBALL_URL_8="http://${DOWNLOAD_HOST}/amdy8.tar.gz"
AMDY_TARBALL_URL_360="http://${DOWNLOAD_HOST}/amdy360.tar.gz"

AGI_DIR="/var/lib/asterisk/agi-bin"
# amd_playback.py reads insert.wav from /var/lib/asterisk/sounds/amdy (hardcoded).
SOUNDS_DIR="/var/lib/asterisk/sounds/amdy"
EXT_CONF="/etc/asterisk/extensions.conf"

DO_NORMALIZE=0
DO_STRIP=0
# Default OFF: do NOT touch /etc/asterisk/extensions.conf. The server's existing
# 8370 block is the source of truth. Pass --dialplan to opt in to a fresh write.
DO_DIALPLAN=0
DO_RELOAD=1
INSTALL_360=""
VICIBOX_MAJOR_OVERRIDE=""
OS_OVERRIDE=""

# Silence filter: trim leading + all subsequent silence ≥0.1s below −45 dBFS.
SILENCE_FILTER=(silence 1 0.1 -45d -1 0.1 -45d)

# ---- output ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*${NC}"; }
info() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 --audio <file-or-url> [OPTIONS]

Required:
  --audio FILE_OR_URL    Audio prompt to install.
                         Bare filename (e.g. "ambiguous.wav", "insert.wav") is
                         fetched from http://${DOWNLOAD_HOST}/<filename>.
                         URL is fetched as-is.

Options:
  --normalize            Force re-encode to 8 kHz mono 16-bit PCM WAV
                         (installs ffmpeg + sox if missing).
  --strip-silence        Strip all silence (≥0.1s below −45 dBFS). Implies
                         --normalize.
  --dialplan             Opt in to writing a fresh 8370 block in ${EXT_CONF}.
                         OFF by default — the server's existing dialplan is
                         the source of truth.
  --no-dialplan          (no-op; kept for backwards-compat)
  --no-reload            Do not run 'asterisk -rx reload' at the end.
  -v, --version VER      Override Vicibox major version (7,8,9,10,11,12).
  -o, --os DISTRO        Override OS detection (opensuse,centos,debian,ubuntu,
                         almalinux,rocky,ol).
  -3, --360              Install 360 variant tarball (${AMDY_TARBALL_URL_360}).
  -h, --help             Show this help.

Default behavior:
  - amd_playback.py installed as /var/lib/asterisk/agi-bin/amd.py
  - audio installed as /var/lib/asterisk/sounds/amdy/insert.wav (verbatim
    copy unless --normalize / --strip-silence is set)
  - dialplan untouched

Examples:
  $0 --audio ambiguous.wav
  $0 --audio ambiguous.wav --strip-silence
  $0 --audio https://example.com/foo.mp3 --normalize
  $0 --audio raw.mp3 --strip-silence --dialplan
EOF
}

# ---- parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --audio)            AUDIO_ARG="$2"; shift 2 ;;
        --normalize)        DO_NORMALIZE=1; shift ;;
        --strip-silence)    DO_NORMALIZE=1; DO_STRIP=1; shift ;;
        --dialplan)         DO_DIALPLAN=1; shift ;;
        --no-dialplan)      DO_DIALPLAN=0; shift ;;
        --no-reload)        DO_RELOAD=0; shift ;;
        -v|--version)       VICIBOX_MAJOR_OVERRIDE="$2"; shift 2 ;;
        -o|--os)            OS_OVERRIDE="$2"; shift 2 ;;
        -3|--360)           INSTALL_360="true"; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  die "Unknown option: $1" ;;
    esac
done

[[ -z "$AUDIO_ARG"  ]] && { usage; die "--audio is required"; }
[[ "$EUID" -ne 0    ]] && die "Must run as root"
command -v asterisk >/dev/null || die "asterisk not in PATH"
command -v wget     >/dev/null || die "wget not installed"
# ffmpeg/sox are only required when --normalize or --strip-silence is set;
# checked + installed on demand by ensure_audio_tools().

# ---- OS / Vicibox detection (same logic as installamd-unified.sh) ----
detect_os() {
    [[ -f /etc/os-release ]] || die "cannot detect OS (/etc/os-release missing)"
    . /etc/os-release
    DISTRO="${OS_OVERRIDE:-$ID}"
    log "OS: ${PRETTY_NAME:-$NAME $VERSION_ID} (distro=$DISTRO)"
}

detect_vicibox_version() {
    if [[ -n "$VICIBOX_MAJOR_OVERRIDE" ]]; then
        VICIBOX_MAJOR="$VICIBOX_MAJOR_OVERRIDE"
        warn "Vicibox major overridden: $VICIBOX_MAJOR"
        return
    fi
    if   [[ -f /etc/vicidial/version ]];        then V=$(grep -o '[0-9]\+\.[0-9]\+' /etc/vicidial/version | head -1)
    elif [[ -f /usr/src/astguiclient/VERSION ]]; then V=$(grep -o '[0-9]\+\.[0-9]\+' /usr/src/astguiclient/VERSION | head -1)
    else V=""; fi
    if [[ -n "$V" ]]; then
        VICIBOX_MAJOR="${V%%.*}"
        log "Vicibox: $V (major=$VICIBOX_MAJOR)"
    else
        warn "cannot detect Vicibox version, assuming 9+"
        VICIBOX_MAJOR=9
    fi
}

# ---- Python deps ----
install_python_stack() {
    log "Installing Python3 + pip..."
    case "$DISTRO" in
        opensuse-leap|opensuse-tumbleweed|sles)
            if [[ "$VICIBOX_MAJOR" -eq 8 ]]; then
                zypper remove -y python3-pip python3-setuptools 2>/dev/null || true
                zypper -n in -y python3-pip
                pip3 install --upgrade pip==19.0.0
            else
                zypper -n in -y python3-pip
                pip3 install --upgrade pip
            fi
            ;;
        centos|rhel|fedora|almalinux|rocky|ol)
            local pm; pm=$(command -v dnf || command -v yum)
            "$pm" -y install python3 python3-pip
            pip3 install --upgrade pip
            ;;
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y python3-pip
            pip3 install --upgrade pip
            ;;
        *) die "Unsupported distro: $DISTRO" ;;
    esac

    log "Installing Python AMD packages (Vicibox $VICIBOX_MAJOR)..."
    case "$VICIBOX_MAJOR" in
        7)
            TMP_WHL=$(mktemp -d)
            ( cd "$TMP_WHL"
              wget --no-check-certificate -q https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl
              pip3 install six-1.16.0-py2.py3-none-any.whl
              wget --no-check-certificate -q https://files.pythonhosted.org/packages/4a/9a/42c1a187a171807a6b214060544fbd6f4bf4a33bf1428aabaa46befed9dc/pyst2-0.5.1-py3-none-any.whl
              pip3 install pyst2-0.5.1-py3-none-any.whl
              wget --no-check-certificate -q https://files.pythonhosted.org/packages/4c/5f/f61b420143ed1c8dc69f9eaec5ff1ac36109d52c80de49d66e0c36c3dfdf/websocket_client-0.57.0-py2.py3-none-any.whl
              pip3 install websocket_client-0.57.0-py2.py3-none-any.whl )
            rm -rf "$TMP_WHL"
            ;;
        8)
            pip3 --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org \
                install --upgrade pyst2 websocket-client==0.52.0 mysql-connector-python==8.0.5 configparser
            ;;
        *)
            pip3 install --upgrade pyst2 websocket-client mysql-connector-python==8.0.29 configparser
            ;;
    esac
}

# Install ffmpeg + sox only when we actually need to transcode/strip.
ensure_audio_tools() {
    if command -v ffmpeg >/dev/null && command -v sox >/dev/null; then
        return
    fi
    log "Installing ffmpeg + sox (required for --normalize/--strip-silence)..."
    case "$DISTRO" in
        opensuse-leap|opensuse-tumbleweed|sles)
            zypper -n in -y ffmpeg sox \
                || die "failed to install ffmpeg/sox (check that an OSS repo is enabled)"
            ;;
        centos|rhel|fedora|almalinux|rocky|ol)
            local pm; pm=$(command -v dnf || command -v yum)
            "$pm" -y install epel-release || true
            # RHEL 9/10 ship ffmpeg in CRB / EPEL as 'ffmpeg-free'. Older + Fedora use 'ffmpeg'.
            "$pm" config-manager --set-enabled crb       2>/dev/null \
                || "$pm" config-manager --set-enabled powertools 2>/dev/null \
                || true
            "$pm" -y install sox || die "failed to install sox"
            "$pm" -y install ffmpeg-free \
                || "$pm" -y install ffmpeg \
                || die "failed to install ffmpeg (try enabling RPM Fusion: 'dnf install -y https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm')"
            # ffmpeg-free installs the binary as 'ffmpeg', so command -v ffmpeg still finds it.
            ;;
        ubuntu|debian)
            apt-get install -y ffmpeg sox || die "failed to install ffmpeg/sox"
            ;;
        *) die "Don't know how to install ffmpeg/sox on distro: $DISTRO" ;;
    esac
    command -v ffmpeg >/dev/null || die "ffmpeg still not on PATH after install"
    command -v sox    >/dev/null || die "sox still not on PATH after install"
}

# ---- amd.py tarball ----
install_amd_package() {
    log "Fetching AMD tarball..."
    mkdir -p "$AGI_DIR"
    local url
    if [[ -n "$INSTALL_360" ]];     then url="$AMDY_TARBALL_URL_360"
    elif [[ "$VICIBOX_MAJOR" -eq 8 ]]; then url="$AMDY_TARBALL_URL_8"
    else                                url="$AMDY_TARBALL_URL"
    fi
    log "  $url"
    wget -q -O "$TMPDIR/amdy.tar.gz" "$url" || die "download failed: $url"
    tar xzf "$TMPDIR/amdy.tar.gz" -C "$AGI_DIR"
    # amd_playback.tar.gz ships the script as amd_playback.py; rename to amd.py.
    if [[ -f "$AGI_DIR/amd_playback.py" && ! -f "$AGI_DIR/amd.py" ]]; then
        mv "$AGI_DIR/amd_playback.py" "$AGI_DIR/amd.py"
    elif [[ -f "$AGI_DIR/amd_playback.py" && -f "$AGI_DIR/amd.py" ]]; then
        # Both present: backup existing amd.py, then activate amd_playback.py as amd.py.
        cp -a "$AGI_DIR/amd.py" "$AGI_DIR/amd.py.bak.$(date +%Y%m%d%H%M%S)"
        mv -f "$AGI_DIR/amd_playback.py" "$AGI_DIR/amd.py"
    fi
    chmod a+x "$AGI_DIR/amd.py"
    chown -R asterisk:asterisk "$AGI_DIR" 2>/dev/null || true
    [[ -f "$AGI_DIR/amd.py" ]] || die "amd.py missing after extract"
    grep -q 'PLAYBACK_ENABLED' "$AGI_DIR/amd.py" \
        || warn "installed amd.py has no PLAYBACK_ENABLED constant — wrong tarball?"
    log "amd.py installed: $AGI_DIR/amd.py"
}

# ---- audio fetch + normalize ----
resolve_audio_url() {
    if [[ "$AUDIO_ARG" =~ ^https?:// ]]; then
        AUDIO_URL="$AUDIO_ARG"
        AUDIO_FILE="$(basename "${AUDIO_URL%%\?*}")"
    else
        AUDIO_FILE="$AUDIO_ARG"
        AUDIO_URL="http://${DOWNLOAD_HOST}/${AUDIO_FILE}"
    fi
    # amd_playback.py hardcodes PLAYBACK_FILE = "insert", so whatever source
    # the user passes gets installed as /var/lib/asterisk/sounds/amdy/insert.wav.
    AUDIO_BASE="insert"
    log "Audio source: $AUDIO_URL"
    log "Install path: ${SOUNDS_DIR}/${AUDIO_BASE}.wav"
    log "Played by:    amd.py at PLAYBACK_TIME=2.0s (no dialplan Playback)"
}

install_audio() {
    mkdir -p "$SOUNDS_DIR"
    local src="$TMPDIR/audio.in"
    local dest="${SOUNDS_DIR}/${AUDIO_BASE}.wav"

    log "Downloading audio: $AUDIO_URL"
    wget -q -O "$src" "$AUDIO_URL" || die "audio download failed: $AUDIO_URL"
    [[ -s "$src" ]] || die "downloaded audio is empty"

    if [[ "$DO_NORMALIZE" -eq 1 ]]; then
        ensure_audio_tools
        if [[ "$DO_STRIP" -eq 1 ]]; then
            log "Normalizing to 8 kHz mono 16-bit PCM + stripping silence..."
            ffmpeg -y -hide_banner -loglevel error -i "$src" -f wav - \
                | sox -t wav - -r 8000 -c 1 -b 16 -e signed-integer "$dest" "${SILENCE_FILTER[@]}"
        else
            log "Normalizing to 8 kHz mono 16-bit PCM (silence kept)..."
            ffmpeg -y -hide_banner -loglevel error -i "$src" \
                -vn -ac 1 -ar 8000 -acodec pcm_s16le "$dest"
        fi
    else
        # Verbatim copy. Verify it's at least a RIFF/WAV so we don't drop an
        # MP3 (or HTML error page) into the sounds dir under a .wav name.
        local magic
        magic=$(head -c 4 "$src" 2>/dev/null || true)
        if [[ "$magic" != "RIFF" ]]; then
            die "downloaded file is not a WAV (magic=${magic@Q}). Re-run with --normalize to convert, or upload a WAV-formatted source."
        fi
        log "Installing audio verbatim (no transcoding)..."
        cp "$src" "$dest"
    fi
    chown asterisk:asterisk "$dest" 2>/dev/null || true
    chmod 0644 "$dest"

    log "Installed: $dest"
    if command -v soxi >/dev/null; then
        soxi "$dest" 2>/dev/null | grep -E 'Sample Rate|Channels|Duration|Precision' | sed 's/^/    /' || true
    fi
}

# ---- dialplan ----
configure_dialplan() {
    [[ "$DO_DIALPLAN" -eq 1 ]] || { info "Dialplan untouched (default; pass --dialplan to overwrite 8370)"; return; }
    [[ -f "$EXT_CONF" ]] || die "$EXT_CONF not found"

    log "Wiring extension 8370 for amd_playback (AGI plays insert.wav at 2s)..."
    cp -a "$EXT_CONF" "${EXT_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # Remove any existing 8370 lines, then insert a fresh block after the 8369 hangup.
    sed -i '/^exten => 8370,/d' "$EXT_CONF"

    # Use Playback(sip-silence) before EAGI to keep the channel open;
    # the AGI itself plays /var/lib/asterisk/sounds/amdy/insert.wav at PLAYBACK_TIME.
    local block_v7 block_default
    block_v7="
;AI AMD extension (installamd-audio.sh, amd_playback v2.3 — insert.wav played in-AGI)
exten => 8370,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8370,n,Playback(sip-silence)
exten => 8370,n,EAGI(/var/lib/asterisk/agi-bin/amd.py)
exten => 8370,n,AGI(VD_amd.agi,\${EXTEN})
exten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----\${CONNECTEDLINE(name)})
exten => 8370,n,Hangup()
"
    block_default="
;AI AMD extension (installamd-audio.sh, amd_playback v2.3 — insert.wav played in-AGI)
exten => 8370,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8370,n,Playback(sip-silence)
exten => 8370,n,EAGI(/var/lib/asterisk/agi-bin/amd.py)
exten => 8370,n,GotoIf(\$[\"\${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)
exten => 8370,n,GotoIf(\$[\"\${AMDCAUSE}\" = \"NETERR\" | \"\${AMDCAUSE}\" = \"INTERR\"]?amd_fallback:continue)
exten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)
exten => 8370,n(continue),AGI(VD_amd.agi,\${EXTEN})
exten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----\${CONNECTEDLINE(name)})
exten => 8370,n(honeypot),Hangup()
"
    local block
    if [[ "$VICIBOX_MAJOR" -eq 7 ]]; then block="$block_v7"; else block="$block_default"; fi

    # Insert block right after the first 'exten => 8369,n,Hangup()' line.
    awk -v block="$block" '
        /^exten => 8369,n,Hangup\(\)/ && !done { print; print block; done=1; next }
        { print }
    ' "$EXT_CONF" > "$EXT_CONF.new"

    if ! grep -q "^exten => 8370," "$EXT_CONF.new"; then
        rm -f "$EXT_CONF.new"
        die "could not find anchor 'exten => 8369,n,Hangup()' in $EXT_CONF; dialplan unchanged"
    fi
    mv "$EXT_CONF.new" "$EXT_CONF"
    log "Dialplan updated (backup left at ${EXT_CONF}.bak.*)"
}

reload_asterisk() {
    [[ "$DO_RELOAD" -eq 1 ]] || { info "Skipping reload (--no-reload)"; return; }
    log "Reloading Asterisk dialplan..."
    asterisk -rx 'dialplan reload' >/dev/null || warn "dialplan reload failed"
}

verify() {
    [[ -x "$AGI_DIR/amd.py" ]] || die "amd.py not executable at $AGI_DIR/amd.py"
    [[ -s "${SOUNDS_DIR}/${AUDIO_BASE}.wav" ]] || die "audio file missing"
    if [[ "$DO_DIALPLAN" -eq 1 ]]; then
        grep -q "^exten => 8370," "$EXT_CONF" || die "8370 not present in $EXT_CONF"
        grep -q "EAGI(/var/lib/asterisk/agi-bin/amd.py)" "$EXT_CONF" \
            || die "EAGI(amd.py) line not present in $EXT_CONF"
    fi
    log "Verified."
}

main() {
    log "installamd-audio.sh starting (audio=$AUDIO_ARG)"
    TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT

    detect_os
    detect_vicibox_version
    resolve_audio_url

    install_python_stack
    install_amd_package
    install_audio
    configure_dialplan
    reload_asterisk
    verify

    log "Done."
    log "  AGI:   $AGI_DIR/amd.py  (amd_playback v2.3, PLAYBACK_ENABLED=True, PLAYBACK_TIME=2.0s)"
    log "  Audio: ${SOUNDS_DIR}/${AUDIO_BASE}.wav  (played in-AGI at 2s)"
    if [[ "$DO_DIALPLAN" -eq 1 ]]; then
        log "  Dial : 8370 rewritten — Playback(sip-silence) -> EAGI(amd.py)"
    else
        log "  Dial : untouched (existing 8370 block preserved)"
    fi
}

main "$@"
