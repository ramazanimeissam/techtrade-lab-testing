#!/usr/bin/env bash
# TechTrade-Labor PLAN-200: Rollenskript fuer die Linux-VMs.
# Aufruf auf der jeweiligen VM (nachdem die Netzwerkkonfiguration gesetzt ist):
#   wget -qO- "$KIT_URL/setup.sh" | sudo KIT_URL="$KIT_URL" bash -s -- pc1|srv-web|srv-erp
set -euo pipefail

ROLE=${1:-}
KIT_URL=${KIT_URL:?KIT_URL fehlt, z. B. https://raw.githubusercontent.com/<konto>/techtrade-lab/main}
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausfuehren."; exit 1; }

case "$ROLE" in
  pc1)     HOST=PC1 ;;
  srv-web) HOST=SRV-WEB ;;
  srv-erp) HOST=SRV-ERP ;;
  *) echo "Rolle fehlt: pc1 | srv-web | srv-erp"; exit 1 ;;
esac

echo "== $HOST: Hostname und Anwendung"
hostnamectl set-hostname "$HOST"
sed -i "/^127\.0\.1\.1/d" /etc/hosts && echo "127.0.1.1 $HOST" >> /etc/hosts
mkdir -p /opt/techtrade
wget -qO /opt/techtrade/techtrade.py "$KIT_URL/techtrade.py"
chmod 755 /opt/techtrade/techtrade.py
ln -sf /opt/techtrade/techtrade.py /usr/local/bin/techtrade

export DEBIAN_FRONTEND=noninteractive
unit() {   # unit <name> <rolle> [Environment-Zeile]
  cat > "/etc/systemd/system/techtrade-$1.service" <<EOF
[Unit]
Description=TechTrade $1
After=network-online.target
Wants=network-online.target

[Service]
${3:-}
ExecStart=/usr/bin/python3 /opt/techtrade/techtrade.py serve $2
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "techtrade-$1"
}

case "$ROLE" in
  pc1)
    echo "== PC1: Testwerkzeuge"
    echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
    apt-get update -qq
    apt-get install -y -qq iperf3 nmap mtr-tiny dnsutils netcat-openbsd curl tcpdump >/dev/null
    ;;
  srv-web)
    echo "== SRV-WEB: Shop und iperf3-Server"
    echo "iperf3 iperf3/start_daemon boolean true" | debconf-set-selections
    apt-get update -qq
    apt-get install -y -qq iperf3 >/dev/null
    systemctl enable --now iperf3 2>/dev/null || true
    unit shop shop "Environment=ERP_URL=http://10.10.30.13:9000"
    ;;
  srv-erp)
    echo "== SRV-ERP: ERP mit SQLite"
    unit erp erp "Environment=TECHTRADE_DB=/var/lib/techtrade/erp.sqlite"
    ;;
esac

sleep 1
echo "== Fertig: $HOST"
ip -br -4 addr | grep -v '^lo'
systemctl --no-pager --type=service --state=running | grep -E 'techtrade|iperf3' || true
