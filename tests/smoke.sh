#!/usr/bin/env bash
# tests/smoke.sh — быстрые неразрушающие проверки тулкита (для CI и локально).
# Ничего не применяет к системе: только bash -n, dry-run, генерация во временный каталог,
# статусы и валидность JSON. Ненулевой код выхода = провал.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
fail=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; fail=1; }

echo "== bash -n =="
for f in node-diagnostic.sh install.sh lib/common.sh modules/*.sh tests/smoke.sh; do
    bash -n "$f" && ok "$f" || bad "syntax $f"
done

echo "== help / version =="
bash node-diagnostic.sh --version 2>/dev/null | grep -q 'node-diagnostic' && ok "version" || bad "version"
bash node-diagnostic.sh help 2>/dev/null | grep -q 'diagnose' && ok "help" || bad "help"

echo "== optimize --all --dry-run =="
bash modules/optimize.sh --all --dry-run >/dev/null 2>&1 && ok "optimize dry-run" || bad "optimize dry-run"

echo "== protect (генерация) =="
out=$(mktemp -d)
bash modules/protect.sh --panel-ip 203.0.113.5 --node-port 2222 --out "$out" >/dev/null 2>&1
if [ -s "$out/firewall.nft" ] && [ -s "$out/firewall-ufw.sh" ] && [ -s "$out/APPLY.txt" ]; then
    ok "protect artifacts"
else
    bad "protect artifacts"
fi
# синтаксис nft (если есть nft) — подставляем плейсхолдеры реальными значениями
if command -v nft >/dev/null 2>&1; then
    sed -e 's/<PANEL_IP>/198.51.100.1/g' -e 's/<YOUR_SSH_IP>/198.51.100.2/g' \
        -e 's/<NODE_PORT>/2222/g' "$out/firewall.nft" > "$out/fw.checked.nft"
    if nft -c -f "$out/fw.checked.nft" >/dev/null 2>&1; then
        ok "nft -c (синтаксис ruleset)"
    elif [ "$(id -u)" -eq 0 ]; then
        # под root nft -c обязан работать — фейл значит битый ruleset
        bad "nft -c (синтаксис ruleset)"
    else
        echo "  ~ nft -c не прошёл (без root netlink недоступен) — не блокирую"
    fi
fi

echo "== rollback --dry-run =="
bash modules/rollback.sh --dry-run >/dev/null 2>&1 && ok "rollback dry-run" || bad "rollback dry-run"

echo "== bbr3 --status =="
# статус возвращает 0 (BBRv3 активен) или 1 (нет) — оба валидны; 2+/127 = падение
bash modules/bbr3.sh --status >/dev/null 2>&1; rc=$?
[ "$rc" -le 1 ] && ok "bbr3 status (rc=$rc)" || bad "bbr3 status crash (rc=$rc)"

echo "== bbr3 --install --dry-run (без установки) =="
# на контейнере bbr3 должен КОРРЕКТНО отказаться (не x86 kernel-capable) либо показать план
bash modules/bbr3.sh --install --dry-run >/dev/null 2>&1
rc=$?
if [ "$rc" = "0" ] || [ "$rc" = "1" ]; then
    ok "bbr3 install dry-run (rc=$rc)"
else
    bad "bbr3 install dry-run упал (rc=$rc)"
fi

echo "== diagnose --no-net --json → валидный JSON =="
if command -v python3 >/dev/null 2>&1; then
    js=$(bash modules/diagnose.sh --no-net --json 2>/dev/null | tail -n1)
    if [ -n "$js" ] && printf '%s' "$js" | python3 -m json.tool >/dev/null 2>&1; then
        ok "diagnose --json валиден"
    else
        bad "diagnose --json невалиден/пуст"
    fi
else
    echo "  ~ python3 нет — пропускаю проверку JSON"
fi

echo
if [ "$fail" = "0" ]; then echo "SMOKE OK"; exit 0; else echo "SMOKE FAIL"; exit 1; fi
