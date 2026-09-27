#!/bin/bash
# AMD install with lightweight Python venv
# Supports: openSUSE 15, Ubuntu/Debian
# Usage: bash installamd-opensuse15-venv.sh

VENV_DIR="/opt/amdvenv"
AMD_BIN="/var/lib/asterisk/agi-bin/amd.py"

# ── Detect OS and install minimal Python ─────────────────────────────────────
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID}"
else
    echo "ERROR: Cannot detect OS"; exit 1
fi

echo ">>> Detected OS: $PRETTY_NAME"

case "$OS_ID" in
    opensuse*|sles)
        echo ">>> Installing minimal Python3 (openSUSE)..."
        zypper in -y --no-recommends python3-base python3-pip python3-venv
        ;;
    ubuntu|debian)
        echo ">>> Installing minimal Python3 (Ubuntu/Debian)..."
        apt-get update -qq
        apt-get install -y --no-install-recommends python3-minimal python3-venv python3-pip curl wget
        ;;
    *)
        echo "ERROR: Unsupported OS: $OS_ID"; exit 1
        ;;
esac

# ── Create venv ───────────────────────────────────────────────────────────────
echo ">>> Creating lightweight venv at $VENV_DIR..."
python3 -m venv --without-pip --copies "$VENV_DIR"

echo ">>> Bootstrapping pip into venv (minimal — no setuptools, no wheel)..."
curl -sS https://bootstrap.pypa.io/get-pip.py | "$VENV_DIR/bin/python3" - --no-setuptools --no-wheel

# ── Install only required packages ───────────────────────────────────────────
echo ">>> Installing required packages into venv..."
"$VENV_DIR/bin/pip" install --no-cache-dir \
    pyst2 \
    websocket-client \
    "mysql-connector-python==8.0.29" \
    configparser

# ── Download and install AMD ──────────────────────────────────────────────────
echo ">>> Downloading amdy.tar.gz..."
wget --no-check-certificate -q -N -O /tmp/amdy.tar.gz https://download.amdy.io/amdy.tar.gz
tar zxf /tmp/amdy.tar.gz --directory /var/lib/asterisk/agi-bin
chmod a+x "$AMD_BIN"

# ── Patch amd.py to use venv Python ──────────────────────────────────────────
echo ">>> Patching amd.py shebang to use venv Python..."
sed -i "1s|^#!.*|#!$VENV_DIR/bin/python3 -O|" "$AMD_BIN"
echo "    Shebang is now: $(head -1 $AMD_BIN)"

# ── Asterisk dialplan ─────────────────────────────────────────────────────────
echo ">>> Patching Asterisk dialplan..."
sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf
sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,GotoIf($\[\"${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)\nexten => 8370,n,GotoIf($\[\"${AMDCAUSE}\" = \"CONNECTION_ERROR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallback\:continue)\nexten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n(honeypot),Hangup()\n/g' /etc/asterisk/extensions.conf

echo ">>> Reloading Asterisk..."
asterisk -rx "reload"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo " AMD Install Complete"
echo "========================================="
echo " Venv:    $VENV_DIR"
echo " Python:  $($VENV_DIR/bin/python3 --version)"
echo " amd.py:  $(head -1 $AMD_BIN)"
echo " Packages installed:"
"$VENV_DIR/bin/pip" list --format=columns
