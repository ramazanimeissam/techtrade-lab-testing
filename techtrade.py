#!/usr/bin/env python3
"""TechTrade Mini-Shop fuer das PLAN-200-Labor (nur Python-Standardbibliothek).

Rollen:
  shop   Webshop auf SRV-WEB, Port 8080. Leitet Bestellungen an das ERP weiter.
  erp    ERP auf SRV-ERP, Port 9000. Bucht Lager, Bestellung und Rechnung in SQLite.
  probe  Messreihe vom Client aus (Verfuegbarkeit, Antwortzeit, laengster Ausfall).
  inspect / reset   Datenbank auf SRV-ERP anzeigen bzw. zuruecksetzen.

Nur fuer isolierte Lehrumgebungen. Kein Produktiveinsatz.
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error, request

DB = os.environ.get("TECHTRADE_DB", "/var/lib/techtrade/erp.sqlite")
ERP_URL = os.environ.get("ERP_URL", "http://10.10.30.13:9000")
ERP_TIMEOUT = float(os.environ.get("ERP_TIMEOUT", "2"))
PRODUCTS = [("KB-01", "Tastatur CH", 25, 79), ("MS-01", "Maus", 40, 49), ("MO-27", "Monitor 27 Zoll", 8, 349)]
STATE = {"delay_ms": 0}
INSTANCE = os.environ.get("INSTANCE", "")


# ---------------------------------------------------------------- ERP-Datenhaltung
def db():
    return sqlite3.connect(DB, timeout=10)


def init_db(reset=False):
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    if reset and os.path.exists(DB):
        os.remove(DB)
    with db() as c:
        c.executescript("""
            CREATE TABLE IF NOT EXISTS products(sku TEXT PRIMARY KEY, name TEXT, stock INTEGER, price_chf INTEGER);
            CREATE TABLE IF NOT EXISTS orders(order_id TEXT PRIMARY KEY, sku TEXT, qty INTEGER, customer TEXT,
                                              request_id TEXT, created TEXT);
            CREATE TABLE IF NOT EXISTS invoices(order_id TEXT PRIMARY KEY, total_chf INTEGER);
        """)
        c.executemany("INSERT OR IGNORE INTO products VALUES (?,?,?,?)", PRODUCTS)


def erp_order(data, rid):
    sku, qty, customer = data.get("sku"), data.get("qty"), str(data.get("customer", "")).strip()
    if not isinstance(sku, str) or type(qty) is not int or not customer:
        return 400, {"error": "sku (Text), qty (Zahl) und customer sind Pflicht"}
    if not 1 <= qty <= 99:
        return 400, {"error": "qty muss zwischen 1 und 99 liegen"}
    if STATE["delay_ms"]:
        time.sleep(STATE["delay_ms"] / 1000)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        row = c.execute("SELECT stock, price_chf FROM products WHERE sku=?", (sku,)).fetchone()
        if row is None:
            return 404, {"error": "unbekanntes Produkt"}
        if row[0] < qty:
            return 409, {"error": "Lagerbestand reicht nicht", "stock": row[0]}
        oid = "B-" + uuid.uuid4().hex[:8].upper()
        c.execute("UPDATE products SET stock = stock - ? WHERE sku=?", (qty, sku))
        c.execute("INSERT INTO orders VALUES (?,?,?,?,?,?)",
                  (oid, sku, qty, customer, rid, datetime.datetime.now().isoformat(timespec="seconds")))
        c.execute("INSERT INTO invoices VALUES (?,?)", (oid, qty * row[1]))
    return 201, {"order_id": oid, "sku": sku, "qty": qty, "total_chf": qty * row[1]}


def erp_get(path):
    with db() as c:
        if path == "/products":
            rows = c.execute("SELECT sku, name, stock, price_chf FROM products ORDER BY sku").fetchall()
            return 200, [dict(zip(["sku", "name", "stock", "price_chf"], r)) for r in rows]
        if path.startswith("/orders/"):
            r = c.execute("SELECT o.order_id, o.sku, o.qty, o.customer, i.total_chf FROM orders o "
                          "JOIN invoices i ON i.order_id = o.order_id WHERE o.order_id=?",
                          (path.split("/")[-1],)).fetchone()
            if r:
                return 200, dict(zip(["order_id", "sku", "qty", "customer", "total_chf"], r))
            return 404, {"error": "Bestellung nicht gefunden"}
    return 404, {"error": "nicht gefunden"}


# ---------------------------------------------------------------- HTTP
def call(url, payload=None, rid=None, timeout=ERP_TIMEOUT):
    body = None if payload is None else json.dumps(payload).encode()
    hdr = {"Content-Type": "application/json"}
    if rid:
        hdr["X-Request-ID"] = rid
    req = request.Request(url, data=body, headers=hdr)
    try:
        with request.urlopen(req, timeout=timeout) as r:
            return r.status, json.load(r)
    except error.HTTPError as e:
        return e.code, json.load(e)


PAGE = """<!doctype html><meta charset="utf-8"><title>TechTrade Shop</title>
<h1>TechTrade Online-Shop</h1>
<p>Produkte und Lagerbestand: <a href="/products">/products</a></p>
<p>Bestellung per API: <code>POST /orders</code> mit JSON <code>{"sku":"KB-01","qty":1,"customer":"Muster"}</code></p>
"""


def make_handler(role):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, status, data, ctype="application/json"):
            body = data.encode() if isinstance(data, str) else json.dumps(data, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype + "; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Request-ID", self.rid)
            self.send_header("X-Served-By", INSTANCE or role)
            self.end_headers()
            self.wfile.write(body)
            print(json.dumps({"ts": datetime.datetime.now().isoformat(timespec="seconds"), "svc": INSTANCE or role,
                              "request_id": self.rid, "client": self.client_address[0],
                              "xff": self.headers.get("X-Forwarded-For", "-"),
                              "proto": self.headers.get("X-Forwarded-Proto", "-"),
                              "method": self.command, "path": self.path, "status": status,
                              "ms": round((time.time() - self.t0) * 1000, 1)}), flush=True)

        def begin(self):
            self.t0 = time.time()
            self.rid = self.headers.get("X-Request-ID") or uuid.uuid4().hex[:12]

        def do_GET(self):
            self.begin()
            if self.path == "/health":
                return self.send(200, {"service": role, "status": "up"})
            if role == "shop" and self.path == "/":
                return self.send(200, PAGE, "text/html")
            if self.path != "/products" and not self.path.startswith("/orders/"):
                return self.send(404, {"error": "nicht gefunden"})
            if role == "erp":
                return self.send(*erp_get(self.path))
            try:
                return self.send(*call(ERP_URL + self.path, rid=self.rid))
            except (OSError, error.URLError, ValueError):
                return self.send(503, {"error": "ERP nicht erreichbar"})

        def do_POST(self):
            self.begin()
            if role == "erp" and self.path.startswith("/admin/delay"):
                if self.client_address[0] != "127.0.0.1":
                    return self.send(403, {"error": "nur lokal auf SRV-ERP"})
                STATE["delay_ms"] = int(self.path.split("ms=")[-1]) if "ms=" in self.path else 0
                return self.send(200, {"delay_ms": STATE["delay_ms"]})
            if self.path != "/orders":
                return self.send(404, {"error": "nicht gefunden"})
            try:
                n = int(self.headers.get("Content-Length", "0"))
                data = json.loads(self.rfile.read(n)) if 0 < n <= 4096 else None
                if not isinstance(data, dict):
                    raise ValueError
            except ValueError:
                return self.send(400, {"error": "ungueltiges JSON"})
            if role == "erp":
                return self.send(*erp_order(data, self.rid))
            try:
                return self.send(*call(ERP_URL + "/orders", data, rid=self.rid))
            except (OSError, error.URLError, ValueError):
                return self.send(503, {"error": "ERP nicht erreichbar, Bestellung nicht bestaetigt"})
    return H


# ---------------------------------------------------------------- Messreihe
def probe(url, interval, count):
    ok = fail = 0
    last_ok = outage_start = None
    longest = 0.0
    print(f"Messreihe auf {url}, Intervall {interval} s. Abbruch mit Ctrl+C.", flush=True)
    try:
        i = 0
        while count == 0 or i < count:
            i += 1
            t0 = time.time()
            try:
                status, _ = call(url, timeout=1.5)
            except (OSError, error.URLError, ValueError):
                status = 0
            now = time.time()
            stamp = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
            if status == 200:
                ok += 1
                if outage_start is not None:
                    dur = now - last_ok if last_ok else now - outage_start
                    longest = max(longest, dur)
                    print(f"{stamp}  OK    wieder erreichbar nach {dur:.1f} s", flush=True)
                    outage_start = None
                else:
                    print(f"{stamp}  OK    {round((now - t0) * 1000)} ms", flush=True)
                last_ok = now
            else:
                fail += 1
                if outage_start is None:
                    outage_start = now
                print(f"{stamp}  FEHLER  status={status}", flush=True)
            time.sleep(max(0, interval - (time.time() - t0)))
    except KeyboardInterrupt:
        pass
    if outage_start is not None and last_ok:
        longest = max(longest, time.time() - last_ok)
    print(f"\nZusammenfassung: {ok} OK, {fail} Fehler, laengster Unterbruch {longest:.1f} s", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("role", choices=["shop", "erp"])
    pr = sub.add_parser("probe")
    pr.add_argument("--url", default="http://shop.techtrade.lab:8080/products")
    pr.add_argument("--interval", type=float, default=0.5)
    pr.add_argument("--count", type=int, default=0, help="0 = bis Ctrl+C")
    sub.add_parser("inspect")
    sub.add_parser("reset")
    a = p.parse_args()

    if a.cmd == "serve":
        port = int(os.environ.get("PORT", 8080 if a.role == "shop" else 9000))
        if a.role == "erp":
            init_db()
        print(f"{a.role} hoert auf 0.0.0.0:{port}", flush=True)
        ThreadingHTTPServer(("0.0.0.0", port), make_handler(a.role)).serve_forever()
    elif a.cmd == "probe":
        probe(a.url, a.interval, a.count)
    elif a.cmd == "inspect":
        with db() as c:
            for t in ("products", "orders", "invoices"):
                print(f"--- {t}")
                for r in c.execute(f"SELECT * FROM {t}"):
                    print("  ", r)
    elif a.cmd == "reset":
        init_db(reset=True)
        print("Datenbank zurueckgesetzt (Lager: KB-01=25, MS-01=40, MO-27=8). Danach: sudo systemctl restart techtrade-erp")


if __name__ == "__main__":
    sys.exit(main())
