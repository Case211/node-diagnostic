#!/usr/bin/env bash
# modules/shape.sh — per-IP полосовой шейпер ноды (eBPF + EDT).
# Каждый клиентский IP получает независимый лимит DL/UL под правилом порта;
# whitelist обходит шейпинг. BPF-программа: nd-shaper.bpf.c, карты через
# shape_ctrl.py (bpftool). Порт из Reshala-Remnawave-Bedolaga (MIT).
#
#   shape on|off|status|list
#   shape rule <id> <ports|all> <dl_mbit> <ul_mbit> [--dynamic]
#   shape unrule <id> <ports|all>
#   shape wl <ip> | unwl <ip>
#   shape reattach   # для systemd на boot (attach + повтор правил)
set -u
_self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_self/../lib/common.sh" 2>/dev/null || { echo "shape: нет lib/common.sh" >&2; exit 1; }

BPF_SRC="$_self/nd-shaper.bpf.c"
CTRL_PY="$_self/shape_ctrl.py"
BPF_OBJ="${ND_STATE_DIR:-/var/lib/node-diagnostic}/nd-shaper.bpf.o"
RULES_LIST="${ND_STATE_DIR:-/var/lib/node-diagnostic}/shaper-rules.list"
PIN_ROOT="/sys/fs/bpf/nd-shaper"
PIN_PROGS="$PIN_ROOT/progs"
PIN_MAPS="$PIN_ROOT/maps"
SHAPER_UNIT="node-diagnostic-shaper"
PROG_DOWN="nd_shape_down"
PROG_UP="nd_shape_up"

_iface() { default_iface; }
# «шейпер реально прицеплен» = пиннута программа (каталог мог остаться от провала)
_attached() { [ -e "$PIN_PROGS/$PROG_DOWN" ]; }

_kernel_ge_54() {
    local kv; kv=$(uname -r | grep -oE '^[0-9]+\.[0-9]+' | head -1)
    awk -v v="$kv" 'BEGIN{split(v,a,".");exit !(a[1]>5 || (a[1]==5 && a[2]>=4))}'
}

_ensure_tools() {
    ensure_pkg clang clang clang clang >/dev/null 2>&1 || true
    ensure_pkg bpftool "linux-tools-common" bpftool bpftool >/dev/null 2>&1 || true
    # bpftool на Ubuntu иногда в linux-tools-$(uname -r) / linux-tools-generic
    have bpftool || ensure_pkg bpftool "linux-tools-$(uname -r)" bpftool bpftool >/dev/null 2>&1 || true
    have bpftool || ensure_pkg bpftool "linux-tools-generic" bpftool bpftool >/dev/null 2>&1 || true
    ensure_pkg python3 python3 python3 python3 >/dev/null 2>&1 || true
    local miss=""
    for t in clang bpftool python3 tc; do have "$t" || miss="$miss $t"; done
    [ -n "$miss" ] && { msg_err "не хватает:$miss (поставь clang/bpftool(linux-tools)/python3/iproute2 + libbpf-dev/linux-headers)"; return 1; }
    return 0
}

_compile() {
    [ -f "$BPF_SRC" ] || die "нет $BPF_SRC (нужен весь репозиторий)"
    if [ -f "$BPF_OBJ" ] && [ "$BPF_OBJ" -nt "$BPF_SRC" ]; then return 0; fi
    mkdir -p "$(dirname "$BPF_OBJ")"
    local inc=""
    # заголовки ядра/арки для <bpf/bpf_helpers.h> + asm/types
    [ -d /usr/include/"$(uname -m)"-linux-gnu ] && inc="-I/usr/include/$(uname -m)-linux-gnu"
    msg_info "компиляция BPF (clang -target bpf)…"
    if ! clang -O2 -g -Wall -target bpf $inc -c "$BPF_SRC" -o "$BPF_OBJ" 2>/tmp/nd-shaper-clang.log; then
        msg_err "clang не собрал BPF — смотри /tmp/nd-shaper-clang.log (нет libbpf-dev/linux-headers?)"
        return 1
    fi
    msg_ok "собрано: $BPF_OBJ"
}

_attach() {
    local iface; iface=$(_iface)
    [ -n "$iface" ] || { msg_err "не определён интерфейс (нет iproute2?)"; return 1; }
    mountpoint -q /sys/fs/bpf 2>/dev/null || mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
    # чистый повторный attach
    rm -rf "$PIN_ROOT" 2>/dev/null || true
    mkdir -p "$PIN_PROGS" "$PIN_MAPS"
    if ! bpftool prog loadall "$BPF_OBJ" "$PIN_PROGS" type classifier pinmaps "$PIN_MAPS" 2>/tmp/nd-shaper-load.log; then
        msg_err "bpftool prog loadall упал — смотри /tmp/nd-shaper-load.log (ядро без BPF/clsact?)"
        return 1
    fi
    tc qdisc del dev "$iface" clsact 2>/dev/null || true
    tc qdisc add dev "$iface" clsact 2>/dev/null || { msg_err "tc clsact не добавился на $iface"; return 1; }
    tc filter add dev "$iface" egress  bpf direct-action pinned "$PIN_PROGS/$PROG_DOWN" 2>/dev/null || { msg_err "не прицепился DOWN-фильтр"; return 1; }
    tc filter add dev "$iface" ingress bpf direct-action pinned "$PIN_PROGS/$PROG_UP"   2>/dev/null || { msg_err "не прицепился UP-фильтр"; return 1; }
    msg_ok "BPF-шейпер прицеплен к $iface (egress+ingress)"
}

# повтор сохранённых правил (после attach / на boot)
_replay_rules() {
    [ -s "$RULES_LIST" ] || return 0
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # shellcheck disable=SC2086
        python3 "$CTRL_PY" --pin-dir "$PIN_MAPS" $line >/dev/null 2>&1 || true
    done < "$RULES_LIST"
    msg_info "правила восстановлены ($(grep -c . "$RULES_LIST") шт)"
}

_install_unit() {
    have systemctl && [ -d /etc/systemd/system ] || { msg_warn "нет systemd — шейпер не переживёт reboot"; return 0; }
    local nd; nd="$(cd "$_self/.." && pwd)/node-diagnostic.sh"
    cat > /etc/systemd/system/$SHAPER_UNIT.service <<UNIT
[Unit]
Description=node-diagnostic eBPF traffic shaper
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $nd shape reattach
ExecStop=/bin/bash $nd shape off --keep-rules
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$SHAPER_UNIT.service" >/dev/null 2>&1 || true
    record_fix "shaper attached ($SHAPER_UNIT.service)"
}

# ── команды ──────────────────────────────────────────────────────────
shape_on() {
    need_root || die "нужен root"
    _kernel_ge_54 || die "нужно ядро Linux ≥5.4 (EDT/clsact); у тебя $(uname -r)"
    _ensure_tools || return 1
    _compile || return 1
    ui_head "Шейпер: attach" "$(_iface)"
    _attach || return 1
    _replay_rules
    _install_unit
    echo; msg_ok "Шейпер включён. Правила: shape rule <id> <порты|all> <dl_mbit> <ul_mbit>"
}

shape_reattach() {   # для systemd (без переустановки юнита)
    need_root || die "нужен root"
    _ensure_tools || return 1
    _compile || return 1
    _attach || return 1
    _replay_rules
}

shape_off() {
    need_root || die "нужен root"
    local keep=0; [ "${1:-}" = "--keep-rules" ] && keep=1
    local iface; iface=$(_iface)
    [ -n "$iface" ] && tc qdisc del dev "$iface" clsact 2>/dev/null || true
    rm -rf "$PIN_ROOT" 2>/dev/null || true
    if have systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^$SHAPER_UNIT.service"; then
        systemctl disable "$SHAPER_UNIT.service" >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/$SHAPER_UNIT.service; systemctl daemon-reload 2>/dev/null || true
    fi
    [ "$keep" = "0" ] && rm -f "$RULES_LIST"
    msg_ok "Шейпер снят${keep:+ (правила сохранены)}"
}

_mbit_to_bps() { echo $(( ${1%%.*} * 125000 )); }   # Mbit/s → bytes/s

shape_rule() {
    need_root || die "нужен root"
    _attached || die "шейпер не включён — сначала: shape on"
    local id="${1:-}" ports="${2:-}" dl="${3:-}" ul="${4:-}" mode=1
    [ "${5:-}" = "--dynamic" ] && mode=2
    [ -n "$id" ] && [ -n "$ports" ] && [ -n "$dl" ] && [ -n "$ul" ] || die "shape rule <id> <порты|all> <dl_mbit> <ul_mbit> [--dynamic]"
    [ "$ports" = "all" ] && ports=0
    local down up args
    down=$(_mbit_to_bps "$dl"); up=$(_mbit_to_bps "$ul")
    args="set-rule --id $id --mode $mode --down $down --up $up --ports $ports"
    python3 "$CTRL_PY" --pin-dir "$PIN_MAPS" $args || die "не удалось задать правило"
    # сохранить для реаттача (перезаписав прежнее правило этого id)
    mkdir -p "$(dirname "$RULES_LIST")"; touch "$RULES_LIST"
    grep -v -- "--id $id " "$RULES_LIST" > "$RULES_LIST.tmp" 2>/dev/null || true
    mv "$RULES_LIST.tmp" "$RULES_LIST" 2>/dev/null || true
    echo "$args" >> "$RULES_LIST"
    msg_ok "правило $id: порты ${ports} · DL ${dl}Mbit · UL ${ul}Mbit · на IP$([ $mode = 2 ] && echo " · dynamic")"
}

shape_unrule() {
    need_root || die "нужен root"
    _attached || die "шейпер не включён"
    local id="${1:-}" ports="${2:-0}"; [ "$ports" = "all" ] && ports=0
    [ -n "$id" ] || die "shape unrule <id> <порты|all>"
    python3 "$CTRL_PY" --pin-dir "$PIN_MAPS" del-rule --id "$id" --ports "$ports" || true
    [ -f "$RULES_LIST" ] && { grep -v -- "--id $id " "$RULES_LIST" > "$RULES_LIST.tmp" 2>/dev/null || true; mv "$RULES_LIST.tmp" "$RULES_LIST" 2>/dev/null || true; }
    msg_ok "правило $id снято"
}

shape_wl()   { need_root || die "нужен root"; _attached || die "шейпер не включён"; python3 "$CTRL_PY" --pin-dir "$PIN_MAPS" wl-add "${1:?ip}"; }
shape_unwl() { need_root || die "нужен root"; _attached || die "шейпер не включён"; python3 "$CTRL_PY" --pin-dir "$PIN_MAPS" wl-del "${1:?ip}"; }

shape_status() {
    ui_head "Шейпер" "статус"
    if _attached; then
        msg_ok "активен на $(_iface); pin $PIN_ROOT"
        [ -s "$RULES_LIST" ] && { echo -e "  ${DIM}правила:${NC}"; sed 's/^/    /' "$RULES_LIST"; }
    else
        msg_info "не включён (shape on)"
    fi
}

case "${1:-}" in
    on)        shape_on ;;
    off)       shift; shape_off "${1:-}" ;;
    reattach)  shape_reattach ;;
    rule)      shift; shape_rule "$@" ;;
    unrule)    shift; shape_unrule "$@" ;;
    wl)        shift; shape_wl "${1:-}" ;;
    unwl)      shift; shape_unwl "${1:-}" ;;
    list|status) shape_status ;;
    ""|help|-h|--help)
        echo "shape: on | off | status | rule <id> <порты|all> <dl_mbit> <ul_mbit> [--dynamic] | unrule <id> <порты> | wl <ip> | unwl <ip>" ;;
    *) echo "shape: неизвестная команда '$1'" >&2; exit 2 ;;
esac
