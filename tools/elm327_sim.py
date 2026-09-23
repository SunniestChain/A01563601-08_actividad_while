#!/usr/bin/env python3
"""Emulador TCP de un ELM327 conectado a una Ranger PX 3.2 en ralentí.

Sirve para probar la app en el simulador de iOS con el transporte Wi-Fi sin la
camioneta (en la app: Conexión > Wi-Fi > IP de tu Mac, puerto 35000).

    python3 tools/elm327_sim.py [--port 35000]

Responde como un ELM327 v1.5 con ATH1/ATS1: "7E8 04 41 0C 0C 80".
Escenario: ralentí ~780 rpm con aceleradas cada 30 s y el cilindro 5 con una
corrección de inyección mucho mayor que los demás (para probar el diagnóstico).
"""
from __future__ import annotations

import argparse
import math
import socketserver
import time

START = time.time()


def rpm(t: float) -> float:
    phase = t % 30
    base = 2500.0 if 20 < phase < 26 else 780.0
    return base + 12 * math.sin(t * 3.1)


def u16(v: float) -> list[int]:
    v = max(0, min(0xFFFF, int(round(v))))
    return [v >> 8, v & 0xFF]


def s16(v: float) -> list[int]:
    v = int(round(v)) & 0xFFFF
    return [v >> 8, v & 0xFF]


def mode01(pid: int, t: float) -> list[int] | None:
    r = rpm(t)
    hi = r > 1500
    table = {
        0x04: lambda: [round((38 if hi else 19) * 255 / 100)],
        0x05: lambda: [int(min(89, 60 + t / 10)) + 40],
        0x0B: lambda: [175 if hi else 101],
        0x0C: lambda: u16(r * 4),
        0x0D: lambda: [0],
        0x0F: lambda: [31 + 40],
        0x10: lambda: u16(r / 780 * 9.5 * 100),
        0x11: lambda: [255],
        0x1F: lambda: u16(t + 120),
        0x23: lambda: u16((98000 if hi else 33000) / 10),
        0x2C: lambda: [round((5 if hi else 32) * 255 / 100)],
        0x2F: lambda: [158],
        0x31: lambda: u16(4812),
        0x33: lambda: [85],
        0x42: lambda: u16((14.1 + 0.05 * math.sin(t)) * 1000),
        0x46: lambda: [27 + 40],
        0x49: lambda: [round((28 if hi else 0) * 255 / 100)],
        0x5E: lambda: u16((6.2 if hi else 1.1) * 20),
        0x63: lambda: u16(470),
    }
    if pid % 0x20 == 0:
        mask = 0
        for p in table:
            if base_ok(p, pid):
                mask |= 1 << (0x20 - (p - pid))
        if any(p > pid + 0x20 for p in table):
            mask |= 1
        return [(mask >> s) & 0xFF for s in (24, 16, 8, 0)]
    f = table.get(pid)
    return f() if f else None


def base_ok(p: int, base: int) -> bool:
    return base < p <= base + 0x20


def did(tx: str, d: int, t: float) -> list[int] | None:
    table = {
        ("7E0", 0xF45C): lambda: [int(min(88, 55 + t / 12)) + 40],
        ("7E0", 0xF42F): lambda: [158],
        ("7E0", 0xF40C): lambda: u16(rpm(t) * 4),
        ("7E0", 0x057B): lambda: [0, 27],
        ("7E0", 0x060E): lambda: [0],
        ("7E0", 0x6043): lambda: s16((0.5 + 0.5 * math.sin(t)) * 2),
        ("7E0", 0x6063): lambda: s16((-1.0 + 0.5 * math.sin(t * 1.3)) * 2),
        ("7E0", 0x6049): lambda: s16((1.0 + 0.5 * math.sin(t * 0.7)) * 2),
        ("7E0", 0x6069): lambda: s16((-0.5 + 0.5 * math.sin(t * 1.1)) * 2),
        ("7E0", 0x3037): lambda: s16((6.5 + 0.5 * math.sin(t * 0.9)) * 2),
        ("7E1", 0x1E1C): lambda: s16(min(71, 40 + t / 20) * 16),
        ("7E1", 0x1E12): lambda: [1],
        ("7E1", 0x1E23): lambda: [0x46],
    }
    f = table.get((tx, d))
    return f() if f else None


RX = {"7DF": "7E8", "7E0": "7E8", "7E1": "7E9", "726": "72E", "760": "768", "720": "728"}


class ELM:
    def __init__(self) -> None:
        self.header = "7DF"
        self.headers = True
        self.echo = True

    def frames(self, rx: str, payload: list[int]) -> str:
        h = rx + " " if self.headers else ""
        hx = lambda b: " ".join(f"{x:02X}" for x in b)  # noqa: E731
        if len(payload) <= 7:
            return h + hx([len(payload)] + payload)
        out = [h + hx([0x10 | (len(payload) >> 8), len(payload) & 0xFF] + payload[:6])]
        rest, seq = payload[6:], 1
        while rest:
            chunk, rest = rest[:7], rest[7:]
            out.append(h + hx([0x20 | seq] + chunk + [0] * (7 - len(chunk))))
            seq = (seq + 1) & 0x0F
        return "\r".join(out)

    def handle(self, line: str) -> str:
        c = line.strip().upper().replace(" ", "")
        if not c:
            return ""
        if c.startswith("AT"):
            a = c[2:]
            if a == "Z":
                self.header = "7DF"
                return "\r\rELM327 v1.5"
            if a == "I":
                return "ELM327 v1.5"
            if a == "RV":
                return "14.1V"
            if a == "DP":
                return "ISO 15765-4 (CAN 11/500)"
            if a in ("E0", "E1"):
                self.echo = a == "E1"
                return "OK"
            if a in ("H0", "H1"):
                self.headers = a == "H1"
                return "OK"
            if a.startswith("SH"):
                self.header = a[2:]
                return "OK"
            return "OK"
        try:
            req = list(bytes.fromhex(c))
        except ValueError:
            return "?"
        rx = RX.get(self.header)
        if rx is None:
            return "NO DATA"
        t = time.time() - START
        sid = req[0]
        payload = None
        if sid == 0x01 and len(req) == 2 and rx == "7E8":
            data = mode01(req[1], t)
            payload = [0x41, req[1]] + data if data is not None else None
        elif sid == 0x03:
            payload = [0x43, 0x01, 0x04, 0x01] if rx == "7E8" else [0x43, 0x00]
        elif sid in (0x07, 0x0A):
            payload = [sid + 0x40, 0x00]
        elif sid == 0x09 and req[1:] == [0x02]:
            payload = [0x49, 0x02, 0x01] + list(b"MNCUMFF80DW000000")
        elif sid == 0x19 and len(req) >= 2 and req[1] == 0x02:
            payload = [0x59, 0x02, 0xFF] + ([0x04, 0x01, 0x00, 0x2F] if rx == "7E8" else [])
        elif sid == 0x22 and len(req) == 3:
            data = did(self.header, req[1] << 8 | req[2], t)
            payload = [0x62, req[1], req[2]] + data if data is not None else [0x7F, 0x22, 0x31]
        else:
            payload = [0x7F, sid, 0x11]
        if payload is None:
            return "NO DATA"
        return self.frames(rx, payload)


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        elm = ELM()
        buf = b""
        print(f"cliente conectado {self.client_address}")
        while True:
            chunk = self.request.recv(1024)
            if not chunk:
                break
            buf += chunk
            while b"\r" in buf:
                line, buf = buf.split(b"\r", 1)
                cmd = line.decode(errors="ignore").strip()
                out = elm.handle(cmd)
                echo = cmd + "\r" if elm.echo else ""
                time.sleep(0.02)
                self.request.sendall((echo + out + "\r\r>").encode())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=35000)
    args = ap.parse_args()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("0.0.0.0", args.port), Handler) as srv:
        print(f"ELM327 simulado escuchando en :{args.port}")
        srv.serve_forever()


if __name__ == "__main__":
    main()
