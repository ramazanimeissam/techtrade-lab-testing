# TechTrade-Labor · HZ 691-6 · 693-8 · 691-7 · Template-Aufbau

**Für:** Kursleitung. **Ziel:** eingefrorenes GNS3-Template «TechTrade Betrieb» in ≤ 30 Minuten.
**Idee:** Das Template ist ein **laufendes Netz mit Shop**. Die Studierenden testen es (Ü1, Ü2) und bauen es im Betrieb aus (Ü3). Fehler lösen sie selbst aus.

## 1 · Topologie

```
Cloud1 ── OPNsense (Edge-FW) ── DMZ 10.10.40.0/24 ── SRV-WEB  (Shop :8080, iperf3 :5201)
              │ LAN 10.10.99.1
              │ Transit 10.10.99.0/24
              │ eth0 10.10.99.2
             R1 (VyOS: Core + interne FW)
              ├ eth1 Clients 10.10.10.0/24 ── PC1      10.10.10.11  (Testwerkzeuge, Probe)
              ├ eth2 Server  10.10.30.0/24 ── SRV-ERP  10.10.30.13  (ERP :9000 + SQLite)
              └ eth3 Neu     10.10.50.0/24 ── PC2      unkonfiguriert (Ausbau Ü3)
```

| Knoten | Abbild | RAM | Adapter | Verkabelung |
|---|---|---|---|---|
| OPNsense | bestehendes installiertes OPNsense (aus Basis-Template duplizieren) | 2 GB | 3 | vtnet0 → Cloud1 · vtnet1 → R1 eth0 · vtnet2 → SRV-WEB |
| R1 | vyos2025 | 1 GB | 4 | eth0 → OPNsense · eth1 → PC1 · eth2 → SRV-ERP · eth3 → PC2 |
| PC1, PC2 | Linux Mint (lmit) | je 2 GB | 1 | ens3 → R1 |
| SRV-WEB, SRV-ERP | xubuntu2404 | je 1 GB | 1 | ens3 → OPNsense bzw. R1 |

Total ≈ 9 GB RAM. Zugang wie gewohnt: VyOS `vyos`/`Gns3456`, Linux `gns3`/`Gns3456`, OPNsense `root`/`Gns3456`.

## 2 · Kommunikationsmatrix (Soll-Zustand im Template)

| Von | Nach | Port | R1 (interne FW) | OPNsense (Edge-FW) |
|---|---|---|---|---|
| Clients | SRV-WEB | tcp/8080, tcp/5201 | erlaubt | erlaubt |
| Clients | OPNsense-GUI | tcp/443 | erlaubt | erlaubt (Anti-Lockout) |
| SRV-WEB | SRV-ERP | tcp/9000 | erlaubt | erlaubt |
| Clients | SRV-ERP | alle ausser ICMP | **gesperrt, geloggt** | – (sieht den Verkehr nicht) |
| intern | intern | ICMP | erlaubt | erlaubt |
| Clients, SRV-ERP, DMZ | Internet | alle | erlaubt | erlaubt + NAT |
| alles andere | | | Default Drop, geloggt | Default Block, geloggt |

## 3 · Vorbereitung (einmalig, nicht in den 30 Minuten)

1. Dieses Kit in ein **öffentliches GitHub-Repository** legen (z. B. `techtrade-lab`) und die Raw-URL notieren:
   `KIT_URL=https://raw.githubusercontent.com/<konto>/techtrade-lab/main`
2. OPNsense-Knoten aus dem Basis-Template als Vorlage bereithalten.
3. Lab-Cheatsheet und Handout-Dateien bereitlegen. **Vor dem Freeze auf PC1 und PC2 kopieren.**

## 4 · Aufbau (30 Minuten)

| Min | Schritt |
|---|---|
| 0–4 | Knoten platzieren, benennen, verkabeln (Tabelle Abschnitt 1) |
| 4–8 | **R1** konfigurieren · parallel **OPNsense-Konsole** |
| 8–10 | **PC1** Netzwerk setzen |
| 10–18 | **OPNsense-GUI** von PC1 aus |
| 18–24 | **Linux-Rollenskripte** (vier Konsolen parallel) |
| 24–27 | **Abnahme** auf PC1, Datenbank zurücksetzen |
| 27–30 | `hw-id` entfernen, Cheatsheet kopieren, Snapshot, Freeze |

### 4.1 · R1 (Konsole)

```
vyos@vyos:~$ configure
vyos@vyos# <Inhalt von r1.vyos einfügen>
vyos@vyos# commit
vyos@vyos# save
```

Prüfen: `show interfaces` zeigt eth0–eth3 mit den Beschreibungen. Beginnen die Namen nicht bei eth0, zuerst die verwaisten Stanzas löschen (siehe 4.7).
Meldet `commit-confirm action rollback` einen ungültigen Pfad: Zeile weglassen. Dann rollt `commit-confirm` per Neustart zurück, was ebenfalls funktioniert.

### 4.2 · OPNsense (Konsole)

1. Option **1** Assign interfaces: VLANs `n` · WAN `vtnet0` · LAN `vtnet1` · Optional 1 `vtnet2`.
2. Option **2** Set interface IP:
   - LAN: `10.10.99.1/24`, kein Upstream-Gateway, kein DHCP-Server, kein IPv6.
   - OPT1: `10.10.40.1/24`, kein DHCP-Server, kein IPv6.
3. Option **8** Shell, temporäre Route für den GUI-Zugriff von PC1:
   ```
   root@OPNsense:~ # route add -net 10.10.0.0/16 10.10.99.2
   ```

### 4.3 · PC1 (Konsole)

```bash
gns3@pc1:~$ sudo tee /etc/netplan/01-dhcp.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3:
      addresses: [10.10.10.11/24]
      routes: [{to: default, via: 10.10.10.1}]
      nameservers: {addresses: [10.10.10.1]}
EOF
gns3@pc1:~$ sudo chmod 600 /etc/netplan/01-dhcp.yaml && sudo netplan apply
```

### 4.4 · OPNsense (GUI auf PC1: `https://10.10.99.1`)

| Menü | Einstellung |
|---|---|
| Interfaces ▸ [OPT1] | Description `DMZ` |
| System ▸ Gateways ▸ Configuration | `GW_R1`, Interface LAN, IP `10.10.99.2`, kein Default-Gateway |
| System ▸ Routes ▸ Configuration | `10.10.10.0/24` via GW_R1 · `10.10.30.0/24` via GW_R1 (Netz 50 **nicht**: Teil von Ü3) |
| Firewall ▸ Aliases | `NET_CLIENTS` Network `10.10.10.0/24` · `NET_INTERN` Network `10.10.0.0/16` · `SRV_WEB` Host `10.10.40.14` · `SRV_ERP` Host `10.10.30.13` · `PORTS_SHOP` Port `8080, 5201` · `RFC1918` Network `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16` |
| Firewall ▸ Rules ▸ LAN | Default-Allow-Regeln (IPv4/IPv6) löschen, dann: ① Pass TCP `NET_CLIENTS` → `SRV_WEB` Port `PORTS_SHOP`, Log ✓, «Clients -> Shop» ② Pass ICMP `NET_INTERN` → any, «Ping intern» ③ Pass any `NET_INTERN` → `RFC1918` **Invert** ✓, «Intern -> Internet» |
| Firewall ▸ Rules ▸ DMZ | ① Pass TCP `SRV_WEB` → `SRV_ERP` Port `9000`, Log ✓, «Shop -> ERP» ② Pass ICMP `DMZ net` → any ③ Pass any `DMZ net` → `RFC1918` **Invert** ✓, «DMZ -> Internet» |
| Firewall ▸ NAT ▸ Outbound | Modus **Hybrid**, Regel: Interface WAN, Source `NET_INTERN`, Translation Interface address |
| System ▸ Configuration ▸ Backups | `config.xml` herunterladen und als `opnsense-config.xml` im Kit ablegen |

Beim nächsten Aufbau ersetzt der Restore dieser Datei die ganze Tabelle (nach Schritt 4.2 und 4.3).

### 4.5 · Linux-Rollenskripte

Auf **SRV-WEB** und **SRV-ERP** zuerst das Netzwerk setzen wie in 4.3, mit diesen Werten:

| VM | Adresse | Gateway | DNS |
|---|---|---|---|
| SRV-WEB | `10.10.40.14/24` | `10.10.40.1` | `10.10.40.1` |
| SRV-ERP | `10.10.30.13/24` | `10.10.30.1` | `10.10.30.1` |

Dann auf jeder VM (Rolle anpassen):

```bash
gns3@srv-erp:~$ KIT_URL=https://raw.githubusercontent.com/<konto>/techtrade-lab/main
gns3@srv-erp:~$ wget -qO- "$KIT_URL/setup.sh" | sudo KIT_URL="$KIT_URL" bash -s -- srv-erp
gns3@srv-web:~$ wget -qO- "$KIT_URL/setup.sh" | sudo KIT_URL="$KIT_URL" bash -s -- srv-web
gns3@pc1:~$     wget -qO- "$KIT_URL/setup.sh" | sudo KIT_URL="$KIT_URL" bash -s -- pc1
```

**PC2** bleibt ohne Adresse, bekommt nur den Hostnamen:

```bash
gns3@pc2:~$ sudo hostnamectl set-hostname PC2
gns3@pc2:~$ sudo tee /etc/netplan/01-dhcp.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens3: {dhcp4: false}
EOF
gns3@pc2:~$ sudo chmod 600 /etc/netplan/01-dhcp.yaml && sudo netplan apply
```

### 4.6 · Abnahme

```bash
gns3@pc1:~$ wget -qO- "$KIT_URL/verify-template.sh" | bash
```

Alle Zeilen `OK`. Danach die Testbestellung entfernen:

```bash
gns3@srv-erp:~$ sudo systemctl stop techtrade-erp && sudo techtrade reset && sudo systemctl start techtrade-erp
```

Auf OPNsense die temporäre Route aus 4.2 ist nach dem nächsten Neustart weg; die statischen Routen aus 4.4 ersetzen sie.

### 4.7 · Freeze

1. **Cheatsheet und Handout-Dateien auf PC1 und PC2 kopieren.**
2. Auf **R1** als letzte Aktion (danach kein `save` mehr):
   ```
   configure
   ... alle Änderungen ...
   commit
   save
   exit
   sudo sed -i '/hw-id/d' /config/config.boot
   grep -c hw-id /config/config.boot     # 0
   ```
3. Alle Knoten herunterfahren, Snapshot `TechTrade-start`, Template einfrieren.
4. Einmal klonen und auf dem Klon `show interfaces` (R1) sowie `verify-template.sh` (PC1) laufen lassen.

## 5 · Was im Template läuft

| VM | Dienst | Befehle für Studierende |
|---|---|---|
| SRV-WEB | `techtrade-shop` (Port 8080), `iperf3` (5201) | `journalctl -u techtrade-shop -f` |
| SRV-ERP | `techtrade-erp` (Port 9000, SQLite `/var/lib/techtrade/erp.sqlite`) | `journalctl -u techtrade-erp -f` · `sudo techtrade inspect` · `sudo systemctl stop techtrade-erp` |
| PC1 | Testwerkzeuge: `curl`, `dig`, `nmap`, `nc`, `mtr`, `iperf3`, `tcpdump`, `techtrade probe` | `techtrade probe` misst Verfügbarkeit und längsten Unterbruch |

**Shop-API** (über `http://shop.techtrade.lab:8080`): `GET /health` · `GET /products` · `POST /orders` mit `{"sku":"KB-01","qty":1,"customer":"Name"}` · `GET /orders/<id>`. Jede Antwort trägt eine `X-Request-ID`, die in den Logs von Shop und ERP erscheint.

**Fehlerschalter** (lösen die Studierenden selbst aus):

| Szenario | Befehl |
|---|---|
| ERP ausgefallen | `sudo systemctl stop techtrade-erp` (SRV-ERP) |
| ERP langsam (Timeout des Shops: 2 s) | `curl -X POST "localhost:9000/admin/delay?ms=5000"` (SRV-ERP), zurück mit `ms=0` |
| Firewallregel falsch | eigene Regel auf R1 oder OPNsense einfügen |
| Netzstörung | `sudo tc qdisc add dev ens3 root netem delay 200ms loss 5%` (PC1), entfernen mit `sudo tc qdisc del dev ens3 root` |

## 6 · Dozentennotiz: eingebaute Befunde

Nicht an Studierende weitergeben. Diese Befunde sollen sie mit ihren eigenen Tests finden.

| Befund | Wie er sichtbar wird | HZ |
|---|---|---|
| **Keine Idempotenz:** dieselbe Bestellung zweimal senden erzeugt zwei Bestellungen, zwei Rechnungen, doppelten Lagerabgang | horizontaler Test mit Wiederholung, `techtrade inspect` | 693-8 |
| **Timeout-Inkonsistenz:** ERP langsam (> 2 s) → Shop meldet «nicht bestätigt», das ERP bucht trotzdem. Wer erneut bestellt, bucht doppelt | Fehlerszenario «ERP langsam», danach `inspect` | 693-8 |
| **Ping ≠ Dienst:** Ping PC1 → SRV-ERP geht, tcp/9000 nicht | Negativtest mit Positivkontrolle | 691-6 |
| **Zwei Firewalls, zwei Sichten:** Client → ERP erscheint nur im R1-Log, nie in OPNsense | Log beider Firewalls vergleichen | 691-6 |
| **Ausbau braucht beide Firewalls und die Rückroute:** Netz 50 nur auf R1 aktiv → PC2 erreicht den Shop nicht (OPNsense kennt weder Route noch Alias) | Ü3 | 691-7 |

## 7 · Lösungsskizze Ü3 (Netz 50 in Betrieb nehmen)

| Wann | Gerät | Schritt |
|---|---|---|
| vor dem Fenster | OPNsense | Alias `NET_CLIENTS` um `10.10.50.0/24` ergänzen · Route `10.10.50.0/24` via `GW_R1` |
| im Fenster | R1 | `set interfaces ethernet eth3 address 10.10.50.1/24` · `set firewall group network-group NET-CLIENTS network 10.10.50.0/24` · `set service dns forwarding listen-address 10.10.50.1` · `commit-confirm 5` · prüfen · `confirm` · `save` |
| im Fenster | PC2 | netplan: `10.10.50.11/24`, Gateway und DNS `10.10.50.1` |
| während allem | PC1 | `techtrade probe` läuft; Abbruchkriterium z. B. Unterbruch > 5 s |
| Rückfall | R1, OPNsense | R1: `commit-confirm` nicht bestätigen (automatischer Rückfall) oder Änderungen mit `delete` zurücknehmen · OPNsense: System ▸ Configuration ▸ History · danach PC2 |
