#!/bin/bash
# AMDY.IO Press-1 installer (thin wrapper).
# Delegates to installamd-v2.sh, which installs both extensions:
#   8370 — standard campaigns
#   8371 — Press-1 survey campaigns (SURVEYCAMP routing, stock-8373 style)
#
# Usage:
#   curl -fsSL https://download.amdy.io/installamdpress1.sh | bash -s <API_KEY>
#   curl -fsSL https://download.amdy.io/installamdpress1.sh | bash -s -- --skip-register

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2="$DIR/installamd-v2.sh"

if [ ! -f "$V2" ]; then
  echo "installamd-v2.sh not found next to this script; downloading it…" >&2
  V2="$(mktemp /tmp/installamd-v2.XXXXXX.sh)"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$V2" https://download.amdy.io/installamd-v2.sh \
    || { echo "Failed to download installamd-v2.sh" >&2; exit 1; }
  chmod +x "$V2"
fi

bash "$V2" "$@"
rc=$?

cat <<'EOF'

Press-1 campaign setup (after install):
1. Campaign > modify: set Routing Extension to 8371.
2. Campaign > Survey Settings: enable Press 1 and select your press-1 audio.
3. AMD Agent Route Options: leave only HUMAN,HUMAN.
4. Admin > Servers: rebuild telephony servers config, then reload Asterisk.

Machines are filtered by AMDY before the press-1 prompt plays, so they do not
burn your balance. Extension 8370 stays available for normal campaigns.
EOF
exit $rc
