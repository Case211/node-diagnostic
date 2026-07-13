#!/usr/bin/env bash
# tests/integration.sh — интеграционный тест РЕАЛЬНОГО применения (для CI в privileged-контейнере).
# В отличие от smoke (dry-run), реально применяет optimize к системе, сверяет значения,
# откатывает и проверяет, что откат дочиста. ТРЕБУЕТ: root + ND_INTEGRATION=1 (защита от
# случайного запуска на рабочей ноде — тест меняет sysctl/iptables и откатывает их).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

[ "${ND_INTEGRATION:-0}" = "1" ] || { echo "пропуск: выставь ND_INTEGRATION=1 (тест реально меняет систему)"; exit 0; }
[ "$(id -u)" -eq 0 ]             || { echo "нужен root"; exit 2; }

fail=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; fail=1; }

# shellcheck source=../lib/common.sh
source lib/common.sh

echo "== optimize --all (реальное применение) =="
if bash modules/optimize.sh --all > /tmp/it-opt.log 2>&1; then ok "optimize отработал"; else bad "optimize упал"; fi
grep -aE "line [0-9]+:|No such file" /tmp/it-opt.log && bad "сырые bash-ошибки в выводе" || ok "вывод без сырых ошибок"

echo "== значения реально в ядре =="
v() { # v <key> <want> <label>
    if verify_sysctl "$1" "$2"; then ok "$3"; else
        # в контейнере часть ключей может отсутствовать — различаем «нет ключа» и «не то значение»
        if sysctl -n "$1" >/dev/null 2>&1; then bad "$3 (ключ есть, значение не то: $(sysctl -n "$1" 2>/dev/null))"
        else echo "  ~ $3: ключа нет в этом ядре — не блокирую"; fi
    fi
}
v net.ipv4.tcp_min_snd_mss 512            "tcp_min_snd_mss=512"
v net.ipv4.tcp_mtu_probing 1              "tcp_mtu_probing=1"
v net.core.somaxconn 8192                 "somaxconn=8192"
v fs.nr_open 2097152                      "fs.nr_open=2M"
v vm.swappiness 10                        "swappiness=10"

echo "== артефакты =="
[ -f /etc/sysctl.d/99-node-diagnostic-tuning.conf ] && ok "tuning drop-in" || bad "нет tuning drop-in"
[ -f /etc/security/limits.d/99-node-diagnostic.conf ] && ok "limits.d" || bad "нет limits.d"
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
    grep -q '\$\$q' /etc/systemd/system/node-diagnostic-rps.service 2>/dev/null \
        && ok "RPS-юнит с \$\$q (systemd не съест переменную)" || bad "RPS-юнит битый/отсутствует"
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        && ok "MSS clamp в OUTPUT" || bad "MSS clamp не встал"
fi

echo "== идемпотентность (второй прогон не дублирует) =="
bash modules/optimize.sh --all > /tmp/it-opt2.log 2>&1
# grep -c сам печатает 0 при отсутствии совпадений — «|| echo 0» добавил бы второй 0
n_rules=$(iptables -t mangle -S 2>/dev/null | grep -c TCPMSS); n_rules=${n_rules:-0}
[ "$n_rules" -le 2 ] && ok "MSS-правила не задвоились ($n_rules)" || bad "MSS-правила задвоились ($n_rules)"

echo "== rollback дочиста =="
bash modules/rollback.sh --yes > /tmp/it-rb.log 2>&1 && ok "rollback отработал" || bad "rollback упал"
leftovers=$(ls /etc/sysctl.d/99-node-diagnostic-* /etc/systemd/system/node-diagnostic-* \
    /etc/security/limits.d/99-node-diagnostic.conf 2>/dev/null | wc -l)
[ "$leftovers" -eq 0 ] && ok "артефактов не осталось" || bad "остались артефакты: $leftovers"
if command -v iptables >/dev/null 2>&1; then
    n_after=$(iptables -t mangle -S 2>/dev/null | grep -c TCPMSS); n_after=${n_after:-0}
    [ "$n_after" -eq 0 ] && ok "MSS-правила сняты" || bad "MSS-правила остались ($n_after)"
fi

echo "== protect: генерация + nft -c =="
out=$(mktemp -d)
PROTECT_OUT="$out" bash modules/protect.sh --panel-ip 203.0.113.5 --node-port 2222 >/dev/null 2>&1
sed 's/<YOUR_SSH_IP>/198.51.100.2/g' "$out/firewall.nft" > "$out/fw.nft"
if command -v nft >/dev/null 2>&1; then
    nft -c -f "$out/fw.nft" && ok "nft -c валиден" || bad "nft -c не прошёл"
fi

echo
if [ "$fail" = "0" ]; then echo "INTEGRATION OK"; exit 0; else echo "INTEGRATION FAIL"; exit 1; fi
