#!/bin/bash
yum install -y python3-pip
pip install --upgrade pip
pip3.6 install pyst2 websocket-client   --upgrade
wget --no-check-certificate -N -O amdy-delay.tar.gz https://download.amdy.io/amdy1.tar.gz
tar zxvf amdy-delay.tar.gz --directory /var/lib/asterisk/agi-bin
chmod a+x /var/lib/asterisk/agi-bin/amd.py
asterisk -rx "reload"
