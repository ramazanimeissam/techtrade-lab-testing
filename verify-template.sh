#!/usr/bin/env bash
# Abnahme des Templates vor dem Freeze. Auf PC1 ausfuehren:
#   wget -qO- "$KIT_URL/verify-template.sh" | bash
# Erzeugt eine Testbestellung. Danach auf SRV-ERP die Datenbank zuruecksetzen.
pass=0; fail=0
check() {  # check "<Beschreibung>" <Befehl...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "OK    $d"; pass=$((pass+1)); else echo "FEHLER $d"; fail=$((fail+1)); fi
}
not() { ! "$@"; }

S=http://shop.techtrade.lab:8080
check "DNS: shop.techtrade.lab -> 10.10.40.14"   bash -c "dig +short shop.techtrade.lab | grep -qx 10.10.40.14"
check "Shop erreichbar (/health)"                curl -sf -m 3 $S/health
check "Shop liest Lager ueber ERP (/products)"   curl -sf -m 3 $S/products
check "Bestellung moeglich (HTTP 201)"           bash -c "curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $S/orders -d '{\"sku\":\"MS-01\",\"qty\":1,\"customer\":\"Abnahme\"}' | grep -qx 201"
check "Direktzugriff PC1 -> ERP :9000 gesperrt"  not nc -z -w 3 10.10.30.13 9000
check "Ping PC1 -> SRV-ERP erlaubt"              ping -c 2 -W 2 10.10.30.13
check "iperf3 PC1 -> SRV-WEB"                    iperf3 -c 10.10.40.14 -t 2
check "OPNsense-GUI erreichbar"                  curl -sk -m 3 -o /dev/null https://10.10.99.1
check "Internet ueber NAT"                       ping -c 2 -W 2 9.9.9.9
check "Netz 50 noch NICHT aktiv"                 not ping -c 1 -W 1 10.10.50.1

echo; echo "Ergebnis: $pass OK, $fail Fehler"
echo "Danach auf SRV-ERP: sudo systemctl stop techtrade-erp && sudo techtrade reset && sudo systemctl start techtrade-erp"
