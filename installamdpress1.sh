#!/bin/bash
zypper in -y python3-pip
pip install --upgrade pip
pip3.6 install pyst2 websocket-client mysql-connector-python==8.0.29 configparser  --upgrade
wget --no-check-certificate -N -O amdy.tar.gz https://download.amdy.io/amdy.tar.gz
tar zxvf amdy.tar.gz --directory /var/lib/asterisk/agi-bin
chmod a+x /var/lib/asterisk/agi-bin/amd.py
sed -i 's/exten => 8371.*//g' /etc/asterisk/extensions.conf
sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8371,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8371,n,Playback(sip-silence)\nexten => 8371,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8371,n,GotoIf($\[\"${AMDCAUSE}\" = \"CONNECTION_ERROR\" \| \"${AMDCAUSE}\" = \"PROCESSING_ERROR\" \| \"${AMDCAUSE}\" = \"FATAL_ERROR\" \| \"${AMDCAUSE}\" = \"NETERR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallback\:continue)\nexten => 8371,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8371,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8371,n,AGI(agi-VDAD_ALL_outbound.agi,SURVEYCAMP-----LB-----${CONNECTEDLINE(name)})\n/g' /etc/asterisk/extensions.conf
asterisk -rx "reload"
