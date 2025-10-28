#!/bin/bash
zypper in -y python3-pip
wget  --no-check-certificate https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl
pip3 install six-1.16.0-py2.py3-none-any.whl
wget --no-check-certificate  https://files.pythonhosted.org/packages/4a/9a/42c1a187a171807a6b214060544fbd6f4bf4a33bf1428aabaa46befed9dc/pyst2-0.5.1-py3-none-any.whl
pip3 install pyst2-0.5.1-py3-none-any.whl
wget --no-check-certificate https://files.pythonhosted.org/packages/4c/5f/f61b420143ed1c8dc69f9eaec5ff1ac36109d52c80de49d66e0c36c3dfdf/websocket_client-0.57.0-py2.py3-none-any.whl
wget pip3 install websocket_client-0.57.0-py2.py3-none-any.whl
wget --no-check-certificate https://download.amdy.io/amdy.tar.gz
tar zxvf amdy.tar.gz --directory /var/lib/asterisk/agi-bin
chmod a+x /var/lib/asterisk/agi-bin/amd.py
sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf
sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n,Hangup()\n/g' /etc/asterisk/extensions.conf
asterisk -rx "reload"

