#!/usr/bin/env python3
"""shape_ctrl.py — программирование BPF-карт шейпера через bpftool.

ABI карт (см. nd-shaper.bpf.c):
  config_map[rule_id] = <I I 32I Q Q Q Q Q Q>
      mode, num_ports, ports[32], down_bps, up_bps, penalty_bps,
      burst_bytes, window_ns, penalty_ns
  port_rule_map[port(u32 native)] = rule_id(u32)
  whitelist_map[ip_key{addr[4]}] = u8(1)

Порт из Reshala (MIT), урезан до нужного тулкиту. Вызывается shape.sh.
"""
import argparse
import ipaddress
import socket
import struct
import subprocess
import sys

MAX_PORTS = 32
RULE_FMT = "<II" + f"{MAX_PORTS}I" + "QQQQQQ"


def _hex(b: bytes) -> str:
    return " ".join(f"{x:02x}" for x in b)


def _u32_key(n: int) -> str:
    return _hex(struct.pack("<I", n))


def _ip_key(ip: str) -> str:
    """16-байтный ip_key{addr[4]} в сетевом порядке (как читает BPF)."""
    a = ipaddress.ip_address(ip)
    if a.version == 4:
        return _hex(socket.inet_aton(ip) + b"\x00" * 12)
    return _hex(socket.inet_pton(socket.AF_INET6, ip))


def _pinned(pin_dir: str, name: str) -> str:
    return f"{pin_dir.rstrip('/')}/{name}"


def _bpftool(args: list, check: bool = True) -> tuple:
    r = subprocess.run(["bpftool", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write(f"bpftool {' '.join(args)} → {r.stderr.strip()}\n")
        sys.exit(1)
    return r.stdout, r.returncode


def _map_update(pin_dir, m, key_hex, val_hex):
    _bpftool(["map", "update", "pinned", _pinned(pin_dir, m),
              "key", "hex", *key_hex.split(), "value", "hex", *val_hex.split()])


def _map_delete(pin_dir, m, key_hex):
    _bpftool(["map", "delete", "pinned", _pinned(pin_dir, m),
              "key", "hex", *key_hex.split()], check=False)


def _pack_rule(mode, ports, down, up, penalty, burst, window, penalty_t) -> str:
    p = (ports + [0] * MAX_PORTS)[:MAX_PORTS]
    return _hex(struct.pack(RULE_FMT, mode, len([x for x in ports if x]),
                            *p, down, up, penalty, burst, window, penalty_t))


def cmd_set_rule(a):
    ports = [int(x) for x in a.ports.split(",") if x.strip() != ""] if a.ports else [0]
    val = _pack_rule(a.mode, ports, a.down, a.up, a.penalty, a.burst,
                     a.window, a.penalty_time)
    _map_update(a.pin_dir, "config_map", _u32_key(a.id), val)
    for port in ports:
        _map_update(a.pin_dir, "port_rule_map", _u32_key(port), _u32_key(a.id))
    print(f"rule {a.id}: mode={a.mode} down={a.down}bps up={a.up}bps ports={ports}")


def cmd_del_rule(a):
    ports = [int(x) for x in a.ports.split(",") if x.strip() != ""] if a.ports else [0]
    for port in ports:
        _map_delete(a.pin_dir, "port_rule_map", _u32_key(port))
    # обнуляем config (mode=0 = off)
    _map_update(a.pin_dir, "config_map", _u32_key(a.id),
                _pack_rule(0, [], 0, 0, 0, 0, 0, 0))
    print(f"rule {a.id} удалено")


def cmd_wl_add(a):
    _map_update(a.pin_dir, "whitelist_map", _ip_key(a.ip), "01")
    print(f"whitelist + {a.ip}")


def cmd_wl_del(a):
    _map_delete(a.pin_dir, "whitelist_map", _ip_key(a.ip))
    print(f"whitelist - {a.ip}")


def cmd_list(a):
    for m in ("config_map", "port_rule_map", "whitelist_map"):
        out, _ = _bpftool(["map", "dump", "pinned", _pinned(a.pin_dir, m)], check=False)
        print(f"── {m} ──")
        print(out.strip() or "  (пусто)")


def main():
    ap = argparse.ArgumentParser(prog="shape_ctrl.py")
    ap.add_argument("--pin-dir", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("set-rule")
    s.add_argument("--id", type=int, required=True)
    s.add_argument("--mode", type=int, default=1)  # 1=static 2=dynamic 3=aggregate
    s.add_argument("--down", type=int, required=True)  # bytes/s
    s.add_argument("--up", type=int, required=True)
    s.add_argument("--ports", default="0")             # csv; 0 = все порты
    s.add_argument("--penalty", type=int, default=0)
    s.add_argument("--burst", type=int, default=0)
    s.add_argument("--window", type=int, default=0)
    s.add_argument("--penalty-time", type=int, default=0, dest="penalty_time")
    s.set_defaults(func=cmd_set_rule)

    d = sub.add_parser("del-rule")
    d.add_argument("--id", type=int, required=True)
    d.add_argument("--ports", default="0")
    d.set_defaults(func=cmd_del_rule)

    w = sub.add_parser("wl-add"); w.add_argument("ip"); w.set_defaults(func=cmd_wl_add)
    x = sub.add_parser("wl-del"); x.add_argument("ip"); x.set_defaults(func=cmd_wl_del)
    sub.add_parser("list").set_defaults(func=cmd_list)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
