#!/bin/bash
# Fallback, wenn der Pi nach 5 Min kein Netz hat: eigenes WLAN
# „Bambu-Setup-XXXX" aufspannen. Handy per Anleitung damit verbinden,
# dann ist der Pi unter http://192.168.44.1:8000 erreichbar (Pairing geht auch dort).
set -e
SUFFIX=$(tr -dc 'A-Z0-9' </dev/urandom | head -c4)
SSID="Bambu-Setup-$SUFFIX"
echo "Setup-AP: $SSID (Passwort: bambu-setup)" | tee /var/lib/bambu-setup-ap.txt
cat >/etc/hostapd/bambu-setup.conf <<EOF
interface=wlan0
ssid=$SSID
wpa_passphrase=bambu-setup
wpa=2
wpa_key_mgmt=WPA-PSK
hw_mode=g
channel=6
EOF
ip addr add 192.168.44.1/24 dev wlan0 2>/dev/null || true
systemctl start hostapd 2>/dev/null || hostapd -B /etc/hostapd/bambu-setup.conf
systemctl start dnsmasq 2>/dev/null || true
