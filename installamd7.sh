#!/bin/bash

# Cleanup old downloads
rm -f libpython3_4m1_0-*.rpm python3-base-*.rpm python3-3.*.rpm python3-setuptools-*.rpm python3-pip-*.rpm
rm -f libsqlite3-0-*.rpm libexpat1-*.rpm
rm -f six-*.whl pyst2-*.whl websocket_client-*.whl
rm -f amdy*.tar.gz

# Download python3 and dependencies for openSUSE Leap 42.3
wget --no-check-certificate -O libsqlite3-0-3.8.10.2-10.2.x86_64.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3/standard/x86_64/libsqlite3-0-3.8.10.2-10.2.x86_64.rpm
wget --no-check-certificate -O libexpat1-2.1.0-22.15.x86_64.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3/standard/x86_64/libexpat1-2.1.0-22.15.x86_64.rpm
wget --no-check-certificate -O libpython3_4m1_0-3.4.6-12.10.1.x86_64.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3:/Update/standard/x86_64/libpython3_4m1_0-3.4.6-12.10.1.x86_64.rpm
wget --no-check-certificate -O python3-base-3.4.6-12.10.1.x86_64.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3:/Update/standard/x86_64/python3-base-3.4.6-12.10.1.x86_64.rpm
wget --no-check-certificate -O python3-3.4.6-11.1.x86_64.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3/standard/x86_64/python3-3.4.6-11.1.x86_64.rpm
wget --no-check-certificate -O python3-setuptools-18.3.2-4.4.noarch.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3/standard/noarch/python3-setuptools-18.3.2-4.4.noarch.rpm
wget --no-check-certificate -O python3-pip-7.1.2-7.1.noarch.rpm https://download.opensuse.org/repositories/openSUSE:/Leap:/42.3/standard/noarch/python3-pip-7.1.2-7.1.noarch.rpm

# Install RPMs in dependency order
rpm -ivh libsqlite3-0-3.8.10.2-10.2.x86_64.rpm
rpm -ivh libexpat1-2.1.0-22.15.x86_64.rpm
rpm -ivh libpython3_4m1_0-3.4.6-12.10.1.x86_64.rpm
rpm -ivh python3-base-3.4.6-12.10.1.x86_64.rpm
rpm -ivh python3-3.4.6-11.1.x86_64.rpm
rpm -ivh python3-setuptools-18.3.2-4.4.noarch.rpm
rpm -ivh python3-pip-7.1.2-7.1.noarch.rpm

# Install Python dependencies
wget --no-check-certificate -O six-1.16.0-py2.py3-none-any.whl https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl
pip3 install --upgrade six-1.16.0-py2.py3-none-any.whl
wget --no-check-certificate -O pyst2-0.5.1-py3-none-any.whl https://files.pythonhosted.org/packages/4a/9a/42c1a187a171807a6b214060544fbd6f4bf4a33bf1428aabaa46befed9dc/pyst2-0.5.1-py3-none-any.whl
pip3 install --upgrade pyst2-0.5.1-py3-none-any.whl
wget --no-check-certificate -O websocket_client-0.57.0-py2.py3-none-any.whl https://files.pythonhosted.org/packages/4c/5f/f61b420143ed1c8dc69f9eaec5ff1ac36109d52c80de49d66e0c36c3dfdf/websocket_client-0.57.0-py2.py3-none-any.whl
pip3 install --upgrade websocket_client-0.57.0-py2.py3-none-any.whl

# Download and install AMD application
wget --no-check-certificate -N -O amdy.tar.gz https://download.amdy.io/amdy8.tar.gz
tar zxvf amdy.tar.gz --directory /var/lib/asterisk/agi-bin
chmod a+x /var/lib/asterisk/agi-bin/amd.py

# Configure Asterisk extensions
sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf
sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var
\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,GotoIf($\[\"${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)\nexten => 8370,n,GotoIf($\[\"${AMDCAUSE}\" = \"NETERR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallb
ack\:continue)\nexten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${C
ONNECTEDLINE(name)})\nexten => 8370,n(honeypot),Hangup()\n/g' /etc/asterisk/extensions.conf

# Reload Asterisk configuration
asterisk -rx "reload"
