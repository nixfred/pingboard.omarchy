#!/usr/bin/env python3
"""Pingboard backend: light, continuous reachability probes for the Omarchy bar.

One ICMP echo per target per cycle (default every 5 s), all targets in
parallel, plus one DNS lookup through the system resolver and one raw DNS
query straight to 1.1.1.1. Prints one JSON line per cycle on stdout; the
QML service keeps nothing but the latest line.

Usage: pingboard.py [--interval 5] [--tailnet vic,fnix,blu] [--once]
"""
import argparse
import json
import os
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque

HISTORY = 60          # samples kept per target (5 minutes at 5 s)
RECENT = 6            # samples the verdict looks at (30 s at 5 s)
PING = shutil.which("ping") or "/usr/bin/ping"
FPING = shutil.which("fping")
TS = shutil.which("tailscale")


def default_route():
    """Return (gateway, device) of the lowest-metric default route."""
    try:
        out = subprocess.run(["ip", "-4", "route", "show", "default"],
                             capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return None, None
    best = None
    for line in out.splitlines():
        m = re.search(r"via (\S+) dev (\S+)", line)
        if not m:
            continue
        mm = re.search(r"metric (\d+)", line)
        metric = int(mm.group(1)) if mm else 0
        if best is None or metric < best[0]:
            best = (metric, m.group(1), m.group(2))
    return (best[1], best[2]) if best else (None, None)


def link_kind(dev):
    if not dev:
        return "none"
    if os.path.isdir(f"/sys/class/net/{dev}/wireless") or dev.startswith("wl"):
        return "wifi"
    return "eth"


def ping_once(host, timeout=1.0):
    """Round-trip ms for one echo, or None on loss."""
    if not host:
        return None
    if FPING:
        cmd = [FPING, "-c1", "-t", str(int(timeout * 1000)), "-q", host]
    else:
        cmd = [PING, "-n", "-c", "1", "-W", str(max(1, int(timeout))), host]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 2)
    except Exception:
        return None
    text = r.stdout + r.stderr
    m = re.search(r"time[=<]([\d.]+)\s*ms", text) or re.search(r"min/avg/max = [\d.]+/([\d.]+)/", text)
    if r.returncode == 0 and m:
        return round(float(m.group(1)), 1)
    return None


def raw_dns(server="1.1.1.1", name="one.one.one.one", timeout=1.5):
    """Send one A query over UDP; return ms if any well-formed reply arrives."""
    qid = random.randint(0, 0xFFFF)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    for part in name.split("."):
        q += bytes([len(part)]) + part.encode()
    q += b"\x00" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        t0 = time.monotonic()
        s.sendto(q, (server, 53))
        data, _ = s.recvfrom(512)
        if len(data) >= 2 and struct.unpack(">H", data[:2])[0] == qid:
            return round((time.monotonic() - t0) * 1000, 1)
    except Exception:
        return None
    finally:
        s.close()
    return None


def sys_dns(name="google.com", timeout=2.0):
    """Resolve through the system resolver (what apps actually use)."""
    box = {}

    def work():
        t0 = time.monotonic()
        try:
            socket.getaddrinfo(name, 443, proto=socket.IPPROTO_TCP)
            box["ms"] = round((time.monotonic() - t0) * 1000, 1)
        except Exception:
            box["ms"] = None

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(timeout)
    return box.get("ms")


def tailnet_ip(name):
    """Resolve a tailnet host once through tailscale, so DNS faults do not look like tailnet faults."""
    if not TS:
        return name
    try:
        r = subprocess.run([TS, "ip", "-4", name], capture_output=True, text=True, timeout=3)
        ip = r.stdout.strip().splitlines()[0] if r.returncode == 0 and r.stdout.strip() else ""
        return ip or name
    except Exception:
        return name


class Target:
    def __init__(self, tid, label, kind, host, probe="ping"):
        self.id, self.label, self.kind, self.host, self.probe = tid, label, kind, host, probe
        self.hist = deque(maxlen=HISTORY)

    def stats(self):
        h = list(self.hist)
        ok = [x for x in h if x is not None]
        rec = h[-RECENT:]
        rec_ok = [x for x in rec if x is not None]
        loss = round(100.0 * (len(h) - len(ok)) / len(h), 1) if h else 0.0
        rloss = round(100.0 * (len(rec) - len(rec_ok)) / len(rec), 1) if rec else 0.0
        jit = 0.0
        if len(ok) > 1:
            jit = round(sum(abs(ok[i] - ok[i - 1]) for i in range(1, len(ok))) / (len(ok) - 1), 1)
        return {
            "id": self.id, "label": self.label, "kind": self.kind, "host": self.host,
            "last": h[-1] if h else None,
            "avg": round(sum(ok) / len(ok), 1) if ok else None,
            "min": min(ok) if ok else None,
            "max": max(ok) if ok else None,
            "jitter": jit, "loss": loss, "recentLoss": rloss,
            "samples": len(h), "history": h,
        }


def verdict(by):
    """Where is the problem? Looks only at the last RECENT samples."""
    def down(t):
        return t and t["samples"] and t["recentLoss"] >= 99
    def lossy(t):
        return t and t["samples"] and t["recentLoss"] > 15
    gw, cf, gg = by.get("gateway"), by.get("cloudflare"), by.get("google")
    dns, raw = by.get("dns"), by.get("dnsraw")
    tails = [t for k, t in by.items() if k.startswith("ts:")]
    if gw is None or not gw["host"]:
        return "down", "LAN", "No default route. Not connected to any network."
    if down(gw):
        return "down", "LAN", "Gateway not answering. Local link or router."
    if down(cf) and down(gg):
        return "down", "ISP", "Gateway fine, internet unreachable. ISP or modem."
    if down(dns) and not (down(cf) and down(gg)):
        extra = " 1.1.1.1 answers direct." if raw and not down(raw) else ""
        return "down", "DNS", "Internet reachable but name lookups fail." + extra
    if lossy(gw):
        return "warn", "LAN", f"Gateway losing {gw['recentLoss']:.0f}% of pings. Wifi or cable."
    if lossy(cf) or lossy(gg):
        worst = max((cf or {}).get("recentLoss", 0), (gg or {}).get("recentLoss", 0))
        return "warn", "ISP", f"Internet losing {worst:.0f}%, gateway clean. Upstream."
    if gw["avg"] and gw["avg"] > 30:
        return "warn", "LAN", f"Gateway slow ({gw['avg']:.0f} ms avg). Local congestion."
    ga = (gg or {}).get("avg") or (cf or {}).get("avg")
    if ga and ga > 120:
        return "warn", "ISP", f"Internet slow ({ga:.0f} ms avg), gateway fast. Upstream."
    if dns and dns["avg"] and dns["avg"] > 250:
        return "warn", "DNS", f"Lookups slow ({dns['avg']:.0f} ms avg)."
    dead = [t["label"] for t in tails if down(t)]
    if dead:
        return "warn", "TAILNET", "Unreachable on tailnet: " + ", ".join(dead) + "."
    lt = [t["label"] for t in tails if lossy(t)]
    if lt:
        return "warn", "TAILNET", "Tailnet loss to " + ", ".join(lt) + "."
    return "ok", "ALL CLEAR", "LAN, ISP, DNS and tailnet all healthy."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--tailnet", default="vic,fnix,blu")
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    interval = max(2.0, min(60.0, a.interval))

    tails = [h.strip() for h in a.tailnet.split(",") if h.strip()][:8]
    targets = [
        Target("gateway", "Gateway", "lan", None),
        Target("cloudflare", "1.1.1.1", "isp", "1.1.1.1"),
        Target("google", "Google", "isp", "8.8.8.8"),
        Target("dns", "DNS lookup", "dns", "system", probe="sysdns"),
        Target("dnsraw", "DNS 1.1.1.1", "dns", "1.1.1.1:53", probe="rawdns"),
    ]
    for h in tails:
        targets.append(Target("ts:" + h, h, "tailnet", tailnet_ip(h)))

    resolve_at = 0.0
    while True:
        t0 = time.monotonic()
        gw, dev = default_route()
        targets[0].host = gw
        if time.monotonic() - resolve_at > 600:   # re-resolve tailnet IPs every 10 min
            for t in targets:
                if t.kind == "tailnet":
                    t.host = tailnet_ip(t.label)
            resolve_at = time.monotonic()

        results = {}

        def run(t):
            if t.probe == "sysdns":
                results[t.id] = sys_dns()
            elif t.probe == "rawdns":
                results[t.id] = raw_dns()
            else:
                results[t.id] = ping_once(t.host)

        threads = [threading.Thread(target=run, args=(t,), daemon=True) for t in targets]
        for th in threads:
            th.start()
        for th in threads:
            th.join(4)
        for t in targets:
            t.hist.append(results.get(t.id))

        st = [t.stats() for t in targets]
        by = {s["id"]: s for s in st}
        level, where, why = verdict(by)
        out = {
            "ts": int(time.time()), "interval": interval,
            "device": dev or "", "link": link_kind(dev), "gateway": gw or "",
            "prober": "fping" if FPING else "ping",
            "verdict": {"level": level, "where": where, "why": why},
            "targets": st,
        }
        sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        if a.once:
            return
        time.sleep(max(0.5, interval - (time.monotonic() - t0)))


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
