#!/usr/bin/env bash
# TechTrade-Labor PLAN-200, Lektion 11 (DHCP + Reverse Proxy)
# Aufruf auf der jeweiligen VM:
#   wget -q https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-testing/main/setup-l11.sh
#   sudo bash setup-l11.sh <rolle>
# Rollen: srv-infra | srv-proxy | srv-web | pc2 | faults (zuletzt, auf SRV-INFRA)
set -euo pipefail

ROLE=${1:-}
KIT_URL=${KIT_URL:-https://raw.githubusercontent.com/ramazanimeissam/techtrade-lab-testing/main}
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausfuehren."; exit 1; }
export DEBIAN_FRONTEND=noninteractive

netcfg() {   # netcfg <host> <ip/prefix> <gw> <dns>
  hostnamectl set-hostname "$1"
  sed -i "/^127\.0\.1\.1/d" /etc/hosts && echo "127.0.1.1 $1" >> /etc/hosts
  rm -f /etc/netplan/*.yaml
  cat > /etc/netplan/01-techtrade.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses: [$2]
      routes: [{to: default, via: $3}]
      nameservers: {addresses: [$4]}
EOF
  chmod 600 /etc/netplan/01-techtrade.yaml
}

no_autoupdate() {
  systemctl disable --now unattended-upgrades 2>/dev/null || true
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
}

kea_conf() {   # kea_conf <netz-praefix> <dns>
  cat > /etc/kea/kea-dhcp4.conf <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "ens3" ],
      "dhcp-socket-type": "udp"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv",
      "lfc-interval": 3600
    },
    "valid-lifetime": 600,
    "renew-timer": 300,
    "rebind-timer": 525,
    "option-data": [
      { "name": "domain-name-servers", "data": "$2" },
      { "name": "domain-name", "data": "techtrade.lab" }
    ],
    "subnet4": [
      {
        "id": 50,
        "subnet": "$1.0/24",
        "pools": [ { "pool": "$1.100 - $1.199" } ],
        "option-data": [ { "name": "routers", "data": "10.10.50.1" } ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [ { "output": "stdout" } ],
        "severity": "DEBUG",
        "debuglevel": 40
      }
    ]
  }
}
EOF
  kea-dhcp4 -t /etc/kea/kea-dhcp4.conf >/dev/null
}

case "$ROLE" in
  srv-infra)
    echo "== SRV-INFRA: Netz, Kea, Werkzeuge"
    netcfg SRV-INFRA 10.10.30.12/24 10.10.30.1 10.10.30.1
    no_autoupdate
    apt-get update -qq
    apt-get install -y -qq kea-dhcp4-server tcpdump nmap curl >/dev/null
    kea_conf 10.10.50 10.10.50.1
    systemctl enable kea-dhcp4-server >/dev/null 2>&1
    systemctl restart kea-dhcp4-server
    ;;
  srv-proxy)
    echo "== SRV-PROXY: Netz, nginx, Zertifikat"
    netcfg SRV-PROXY 10.10.40.10/24 10.10.40.1 10.10.40.1
    no_autoupdate
    apt-get update -qq
    apt-get install -y -qq nginx curl tcpdump >/dev/null
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
      -keyout /etc/nginx/ssl/shop.key -out /etc/nginx/ssl/shop.crt \
      -subj "/CN=shop.techtrade.lab" -addext "subjectAltName=DNS:shop.techtrade.lab" 2>/dev/null
    chmod 600 /etc/nginx/ssl/shop.key
    cat > /etc/nginx/sites-available/shop <<'EOF'
# Reverse Proxy fuer den TechTrade-Shop (Ausgangszustand Lektion 11)
server {
    listen 80;
    server_name shop.techtrade.lab;

    location / {
        proxy_pass http://10.10.40.14:8080;
    }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/shop /etc/nginx/sites-enabled/shop
    nginx -t
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    ;;
  srv-web)
    echo "== SRV-WEB: neue Shop-Version, zweite Instanz shop-b"
    no_autoupdate
    wget -qO /opt/techtrade/techtrade.py "$KIT_URL/techtrade.py"
    chmod 755 /opt/techtrade/techtrade.py
    apt-get update -qq
    apt-get install -y -qq curl >/dev/null
    for i in a b; do
      [[ $i == a ]] && { UNIT=techtrade-shop; PORT=8080; } || { UNIT=techtrade-shop-b; PORT=8081; }
      cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=TechTrade shop-$i (Port $PORT)
After=network-online.target
Wants=network-online.target

[Service]
Environment=ERP_URL=http://10.10.30.13:9000
Environment=PORT=$PORT
Environment=INSTANCE=shop-$i
ExecStart=/usr/bin/python3 /opt/techtrade/techtrade.py serve shop
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    done
    systemctl daemon-reload
    systemctl enable techtrade-shop techtrade-shop-b >/dev/null 2>&1
    systemctl restart techtrade-shop techtrade-shop-b
    ;;
  pc2)
    echo "== PC2: Werkzeuge"
    hostnamectl set-hostname PC2
    sed -i "/^127\.0\.1\.1/d" /etc/hosts && echo "127.0.1.1 PC2" >> /etc/hosts
    no_autoupdate
    apt-get update -qq
    apt-get install -y -qq curl nmap tcpdump dnsutils >/dev/null
    ;;
  faults)
    echo "== SRV-INFRA: Ausgangszustand fuer die Studierenden herstellen"
    systemctl stop kea-dhcp4-server
    kea_conf 10.10.5 10.10.30.53
    rm -f /var/lib/kea/kea-leases4.csv*
    systemctl start kea-dhcp4-server
    rm -f -- "$(readlink -f "$0")"
    echo "== Fertig. Dieses Skript wurde geloescht."
    exit 0
    ;;
  *) echo "Rolle fehlt: srv-infra | srv-proxy | srv-web | pc2 | faults"; exit 1 ;;
esac

[[ $ROLE == pc2 || $ROLE == srv-web ]] || netplan apply
sleep 2
echo "== Fertig: $(hostname)"
ip -br -4 addr | grep -v '^lo' || true
systemctl --no-pager --type=service --state=running | grep -E 'kea|nginx|techtrade' || true
