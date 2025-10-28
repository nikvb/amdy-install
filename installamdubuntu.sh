#!/bin/bash
apt install python3-pip -y
pip3 install pyst2 websocket_client --upgrade
wget -N -O amdy.tar.gz http://download.amdy.io/amdy.tar.gz
tar zxvf amdy.tar.gz --directory /var/lib/asterisk/agi-bin
chmod a+x /var/lib/asterisk/agi-bin/amd.py
sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf
sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n,Hangup()\n/g' /etc/asterisk/extensions.conf
asterisk -rx "reload"

