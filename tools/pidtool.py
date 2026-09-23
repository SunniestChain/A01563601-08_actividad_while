#!/usr/bin/env python3
"""Validador y evaluador de la base de PIDs (pids/*.json).

Implementa la misma gramática de fórmulas que ios/Sources/OBDCore/Formula.swift,
así que sirve de implementación de referencia: si un vector de prueba pasa aquí
debe pasar también en Swift (los tests de Swift leen los mismos JSON).

Uso:
    python3 tools/pidtool.py validate            # valida todos los pids/*.json
    python3 tools/pidtool.py decode OBD.01.0C "41 0C 0C 80"
    python3 tools/pidtool.py list [texto]
"""
from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PID_DIR = ROOT / "pids"

HEX_RE = re.compile(r"^[0-9A-F]+$")
HEADER_RE = re.compile(r"^[0-7][0-9A-F]{2}$")
SERVICE_PID_LEN = {"01": 1, "02": 1, "09": 1, "22": 2}
VALID_CONFIDENCE = {
    "sae-standard",
    "confirmed-ranger",
    "ford-diesel-sibling",
    "ford-generic",
}
REQUIRED = [
    "id", "module", "tx", "rx", "service", "pid", "name_en", "name_es",
    "category", "bytes", "formula", "unit", "confidence",
]


# --------------------------------------------------------------------------
# Fórmulas
# --------------------------------------------------------------------------
class FormulaError(Exception):
    pass


def _tokenize(src: str):
    tokens = []
    i = 0
    while i < len(src):
        c = src[i]
        if c.isspace():
            i += 1
        elif c in "+-*/(),":
            tokens.append(("op", c))
            i += 1
        elif src.startswith("0x", i) or src.startswith("0X", i):
            j = i + 2
            while j < len(src) and src[j] in "0123456789abcdefABCDEF":
                j += 1
            if j == i + 2:
                raise FormulaError(f"hex vacío en {i}")
            tokens.append(("num", float(int(src[i + 2:j], 16))))
            i = j
        elif c.isdigit() or c == ".":
            j = i
            while j < len(src) and (src[j].isdigit() or src[j] == "."):
                j += 1
            tokens.append(("num", float(src[i:j])))
            i = j
        elif c.isalpha():
            j = i
            while j < len(src) and (src[j].isalnum() or src[j] == "_"):
                j += 1
            tokens.append(("id", src[i:j]))
            i = j
        else:
            raise FormulaError(f"carácter inesperado {c!r} en {i}")
    return tokens


def _u(vals):
    out = 0
    for v in vals:
        out = out * 256 + int(v)
    return out


def _s(vals):
    bits = 8 * len(vals)
    v = _u(vals)
    return v - (1 << bits) if v >= 1 << (bits - 1) else v


FUNCS = {
    "s8": (1, lambda a: _s(a)),
    "u16": (2, lambda a: _u(a)),
    "s16": (2, lambda a: _s(a)),
    "u24": (3, lambda a: _u(a)),
    "u32": (4, lambda a: _u(a)),
    "s32": (4, lambda a: _s(a)),
    "bit": (2, lambda a: (int(a[0]) >> int(a[1])) & 1),
    "min": (2, lambda a: min(a)),
    "max": (2, lambda a: max(a)),
    "abs": (1, lambda a: abs(a[0])),
}


class _Parser:
    def __init__(self, src: str, data: list[int]):
        self.t = _tokenize(src)
        self.p = 0
        self.data = data

    def peek(self):
        return self.t[self.p] if self.p < len(self.t) else (None, None)

    def eat(self, kind, val=None):
        k, v = self.peek()
        if k != kind or (val is not None and v != val):
            raise FormulaError(f"se esperaba {val or kind}, llegó {v!r}")
        self.p += 1
        return v

    def parse(self) -> float:
        v = self.expr()
        if self.p != len(self.t):
            raise FormulaError(f"sobra texto: {self.t[self.p:]}")
        return v

    def expr(self):
        v = self.term()
        while self.peek() in (("op", "+"), ("op", "-")):
            op = self.eat("op")
            r = self.term()
            v = v + r if op == "+" else v - r
        return v

    def term(self):
        v = self.unary()
        while self.peek() in (("op", "*"), ("op", "/")):
            op = self.eat("op")
            r = self.unary()
            if op == "*":
                v = v * r
            else:
                if r == 0:
                    raise FormulaError("división entre cero")
                v = v / r
        return v

    def unary(self):
        if self.peek() == ("op", "-"):
            self.eat("op", "-")
            return -self.unary()
        return self.primary()

    def primary(self):
        k, v = self.peek()
        if k == "num":
            self.p += 1
            return v
        if k == "op" and v == "(":
            self.eat("op", "(")
            r = self.expr()
            self.eat("op", ")")
            return r
        if k == "id":
            self.p += 1
            if self.peek() == ("op", "("):
                self.eat("op", "(")
                args = [self.expr()]
                while self.peek() == ("op", ","):
                    self.eat("op", ",")
                    args.append(self.expr())
                self.eat("op", ")")
                if v not in FUNCS:
                    raise FormulaError(f"función desconocida {v}")
                arity, fn = FUNCS[v]
                if len(args) != arity:
                    raise FormulaError(f"{v} espera {arity} args")
                return float(fn(args))
            if len(v) == 1 and "A" <= v <= "Z":
                idx = ord(v) - ord("A")
                if idx >= len(self.data):
                    raise FormulaError(f"falta el byte {v} (hay {len(self.data)})")
                return float(self.data[idx])
            raise FormulaError(f"identificador desconocido {v}")
        raise FormulaError(f"token inesperado {v!r}")


def evaluate(formula: str, data: list[int]) -> float:
    return _Parser(formula, data).parse()


def max_byte_index(formula: str) -> int:
    idx = -1
    for k, v in _tokenize(formula):
        if k == "id" and len(v) == 1 and "A" <= v <= "Z":
            idx = max(idx, ord(v) - ord("A"))
    return idx


# --------------------------------------------------------------------------
# Respuestas
# --------------------------------------------------------------------------
def parse_hex(s: str) -> list[int]:
    s = s.replace(" ", "").upper()
    if len(s) % 2 or not HEX_RE.match(s or "00"):
        raise ValueError(f"hex inválido: {s}")
    return [int(s[i:i + 2], 16) for i in range(0, len(s), 2)]


def data_bytes(pid: dict, payload: list[int]) -> list[int]:
    """Quita el eco del servicio (+0x40) y del PID/DID del payload UDS."""
    svc = int(pid["service"], 16)
    pid_bytes = parse_hex(pid["pid"])
    head = [svc + 0x40] + pid_bytes
    if payload[: len(head)] != head:
        raise ValueError(f"la respuesta no corresponde: {payload[:len(head)]} vs {head}")
    return payload[len(head):]


def load_all() -> list[dict]:
    pids = []
    for f in sorted(PID_DIR.glob("*.json")):
        doc = json.loads(f.read_text(encoding="utf-8"))
        for p in doc["pids"]:
            p["_file"] = f.name
            pids.append(p)
    return pids


def validate() -> int:
    errors = []
    seen = set()
    pids = load_all()
    for p in pids:
        where = f"{p.get('_file')}:{p.get('id')}"
        for k in REQUIRED:
            if k not in p:
                errors.append(f"{where}: falta {k}")
        if errors and errors[-1].startswith(where):
            continue
        if p["id"] in seen:
            errors.append(f"{where}: id duplicado")
        seen.add(p["id"])
        if not HEADER_RE.match(p["tx"]) or not HEADER_RE.match(p["rx"]):
            errors.append(f"{where}: tx/rx deben ser cabeceras CAN de 11 bits")
        if p["service"] not in SERVICE_PID_LEN:
            errors.append(f"{where}: servicio {p['service']} no soportado")
        elif len(p["pid"]) != 2 * SERVICE_PID_LEN[p["service"]] or not HEX_RE.match(p["pid"]):
            errors.append(f"{where}: pid {p['pid']} con longitud incorrecta")
        if p["confidence"] not in VALID_CONFIDENCE:
            errors.append(f"{where}: confidence inválido {p['confidence']}")
        try:
            need = max_byte_index(p["formula"]) + 1
            if need > p["bytes"]:
                errors.append(f"{where}: la fórmula usa {need} bytes pero bytes={p['bytes']}")
            evaluate(p["formula"], [0] * max(need, 1))
        except FormulaError as e:
            errors.append(f"{where}: fórmula inválida: {e}")
            continue
        t = p.get("test")
        if t:
            try:
                got = evaluate(p["formula"], data_bytes(p, parse_hex(t["response"])))
                if not math.isclose(got, t["expect"], rel_tol=1e-6, abs_tol=1e-3):
                    errors.append(f"{where}: test esperaba {t['expect']} y dio {got}")
            except (ValueError, FormulaError) as e:
                errors.append(f"{where}: test falló: {e}")
    for e in errors:
        print("ERROR", e)
    tested = sum(1 for p in pids if p.get("test"))
    print(f"{len(pids)} PIDs, {tested} con vector de prueba, {len(errors)} errores")
    return 1 if errors else 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] == "validate":
        return validate()
    if argv[1] == "decode" and len(argv) == 4:
        pid = next((p for p in load_all() if p["id"] == argv[2]), None)
        if not pid:
            print("PID no encontrado")
            return 1
        val = evaluate(pid["formula"], data_bytes(pid, parse_hex(argv[3])))
        print(f"{pid['name_es']}: {val:g} {pid['unit']}")
        return 0
    if argv[1] == "list":
        q = argv[2].lower() if len(argv) > 2 else ""
        for p in load_all():
            line = f"{p['id']:<22} {p['module']:<4} {p['name_es']} [{p['unit']}] ({p['confidence']})"
            if q in line.lower():
                print(line)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
