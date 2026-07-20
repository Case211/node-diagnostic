#!/usr/bin/env bash
# modules/optimize.sh — сетевой/системный тюнинг ноды (sysctl, FD-лимиты, RPS/RFS/XPS, NIC, MSS clamp).
# Всё живёт в namespaced drop-in (99-node-diagnostic-*), откат — modules/rollback.sh.
#
# Standalone:  sudo bash modules/optimize.sh [--all|--sysctl|--limits|--rps|--nic|--mss|--dry-run]
# Как модуль:  source lib/common.sh; source modules/optimize.sh; opt_all

if [ -z "${ND_COMMON_LOADED:-}" ]; then
    _self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck source=../lib/common.sh
    source "$_self/../lib/common.sh" 2>/dev/null \
        || { echo "не найден lib/common.sh — нужен весь репозиторий (см. install.sh)" >&2; exit 1; }
fi

# ── масштаб буферов/conntrack по объёму RAM ──────────────────────────
_mem_kb() { awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 1048576; }
_sock_max() {
    local m; m=$(_mem_kb)
    if   [ "$m" -le 1258291 ]; then echo 16777216     # ≤1.2G → 16M
    elif [ "$m" -le 2621440 ]; then echo 33554432     # ≤2.5G → 32M
    elif [ "$m" -le 8912896 ]; then echo 67108864     # ≤8.5G → 64M
    else echo 134217728; fi                           # >8.5G → 128M
}
_ct_max() {
    local m ct; m=$(_mem_kb)
    ct=$(( m * 1024 / 8 / 320 ))                       # ~320 байт/запись, ≤1/8 RAM
    [ "$ct" -lt 262144 ]  && ct=262144
    [ "$ct" -gt 2000000 ] && ct=2000000
    echo "$ct"
}

# ── 1. sysctl: congestion, PMTU, буферы, очереди, SYN/anti-spoof, TIME_WAIT ──
opt_sysctl() {
    local sock_max ct_max cc="bbr" qdisc="cake"
    sock_max=$(_sock_max); ct_max=$(_ct_max)

    # модули: без tcp_bbr cc не переключится, без nf_conntrack ключи net.netfilter.* не существуют
    load_module tcp_bbr
    load_module nf_conntrack
    load_module sch_cake

    # выбираем congestion control / qdisc по РЕАЛЬНОЙ доступности, а не вслепую
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        cc="cubic"
        msg_warn "BBR недоступен в ядре — ставлю cc=cubic. Для BBR(v3) поставь ядро: bbr3.sh --install"
    fi
    if ! module_available sch_cake; then
        qdisc="fq"
        msg_info "sch_cake недоступен — qdisc=fq"
    fi

    ui_head "sysctl tuning" "RAM=$(( $(_mem_kb)/1024 ))M → буферы $((sock_max/1024/1024))M · conntrack $ct_max · cc=$cc · qdisc=$qdisc"

    write_dropin tuning <<EOF
# Congestion control + qdisc
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc

# PMTU / MSS — tcp_mtu_probing без пола MSS = коллапс до 48б на лоссовом плече
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_min_snd_mss = 512
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
# ECN=2: принимаем ECN от клиента пассивно, но не инициируем на исходящих
# (безопаснее 1 на путях с битыми middlebox к апстримам)
net.ipv4.tcp_ecn = 2

# Буферы (масштаб по RAM)
net.core.rmem_max = $sock_max
net.core.wmem_max = $sock_max
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 $sock_max
net.ipv4.tcp_wmem = 4096 65536 $sock_max
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Очереди / бэклоги
net.core.netdev_max_backlog = 16384
# softirq-бюджет: сколько пакетов дренировать за цикл (дефолт 300) — потолок под high-PPS
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# SYN-flood (уровень ядра)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2

# TIME_WAIT / keepalive / гигиена
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.ip_local_port_range = 10000 65535

# Anti-spoof / redirects (rp_filter=2 loose — strict=1 рубит асимметрию host-network нод)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# src_valid_mark=1 — пропускать marked-пакеты (WireGuard/WARP fwmark) через
# reverse-path проверку; иначе исходящий WARP/WG на ноде может молча отваливаться
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

# Conntrack (масштаб по RAM)
net.netfilter.nf_conntrack_max = $ct_max
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
EOF

    # verify-after: подтверждаем, что критичное реально применилось (ключ мог отсутствовать/не иметь модуля)
    if [ "$DRY_RUN" != "1" ]; then
        local bad=0
        verify_sysctl net.ipv4.tcp_congestion_control "$cc"    || { bad=1; msg_warn "cc=$cc не применился"; }
        verify_sysctl net.core.default_qdisc "$qdisc"          || { bad=1; msg_warn "qdisc=$qdisc не применился"; }
        verify_sysctl net.ipv4.tcp_min_snd_mss 512             || { bad=1; msg_warn "tcp_min_snd_mss не применился"; }
        verify_sysctl net.netfilter.nf_conntrack_max "$ct_max" || msg_warn "nf_conntrack_max не применился (модуль nf_conntrack не загружен?)"
        [ "$bad" = "0" ] && msg_ok "ключевые значения подтверждены (cc / qdisc / tcp_min_snd_mss)"
    fi
}

# ── 2. FD-лимиты (xray упирается в дескрипторы; sysctl + limits + systemd + pam) ──
opt_fd_limits() {
    ui_head "FD-лимиты" "file-max, nofile для сессий и systemd-сервисов"
    write_dropin fd <<'EOF'
fs.file-max = 2097152
fs.nr_open = 2097152
EOF
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} limits.conf + systemd DefaultLimitNOFILE + pam_limits"
        return 0
    fi
    backup_settings
    # /etc/security/limits.d — интерактивные сессии
    cat > /etc/security/limits.d/99-node-diagnostic.conf <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
*    soft nproc  1048576
*    hard nproc  1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    # systemd — сервисы (xray!) не читают limits.conf, только это
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=1048576\nDefaultLimitNPROC=1048576\n' \
        | tee /etc/systemd/system.conf.d/99-node-diagnostic-limits.conf \
              /etc/systemd/user.conf.d/99-node-diagnostic-limits.conf >/dev/null
    systemctl daemon-reexec 2>/dev/null || true
    msg_ok "лимиты записаны (сервисам — reexec/reboot, чтобы подхватили)"
    record_fix "fd limits (limits.d + systemd + sysctl)"
}

# ── 3. RPS + RFS + XPS (размазать softirq/поток по CPU) ──────────────
# CPU-битмаска для rps_cpus/xps_cpus. Ядро ждёт группы по 32 бита через запятую,
# старшее слово первым. Наивный printf '%x' $(( (1<<n)-1 )) ломался при n≥64
# (1<<64 в 64-битном bash = переполнение → mask=0, RPS выключался вовсе) и давал
# одно слово >32 бит при 33≤n≤63, которое ядро могло отвергнуть.
cpu_mask() {
    local n=$1
    local full=$(( n / 32 )) rem=$(( n % 32 )) words=() i
    [ "$rem" -gt 0 ] && words+=("$(printf '%x' $(( (1 << rem) - 1 )))")
    for ((i=0; i<full; i++)); do words+=("ffffffff"); done
    [ ${#words[@]} -eq 0 ] && words=("0")
    local IFS=,; echo "${words[*]}"
}

# shellcheck disable=SC2120  # iface — опциональный аргумент (обычно берётся из default_iface)
opt_rps() {
    ensure_pkg ip iproute2 iproute iproute2 >/dev/null 2>&1 || true
    local iface="${1:-$(default_iface)}"
    [ -z "$iface" ] && { msg_err "интерфейс не определён — нет iproute2 (поставь пакет iproute2)"; return 1; }
    local n mask; n=$(nproc); mask=$(cpu_mask "$n")
    ui_head "RPS/RFS/XPS" "mask=$mask на $iface"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} rps_cpus/xps_cpus=$mask, rps_flow_cnt=4096, rps_sock_flow_entries=32768"
        return 0
    fi
    backup_settings
    # {}: ошибка самого редиректа (ключа нет в ядре) иначе не глушится 2>/dev/null
    { echo 32768 > /proc/sys/net/core/rps_sock_flow_entries; } 2>/dev/null || true
    local q
    for q in /sys/class/net/"$iface"/queues/rx-*; do
        [ -d "$q" ] || continue
        { echo "$mask" > "$q/rps_cpus"; }    2>/dev/null || true
        { echo 4096   > "$q/rps_flow_cnt"; } 2>/dev/null || true
    done
    for q in /sys/class/net/"$iface"/queues/tx-*; do
        [ -d "$q" ] || continue
        { echo "$mask" > "$q/xps_cpus"; }    2>/dev/null || true
    done
    msg_ok "применено к очередям $iface"

    # persist: sysctl для sock_flow_entries + systemd-юнит для per-queue
    write_dropin rps <<'EOF'
net.core.rps_sock_flow_entries = 32768
EOF
    if ! have systemctl || [ ! -d /etc/systemd/system ]; then
        msg_warn "нет systemd — RPS/XPS не переживут reboot (повтори optimize --rps после перезагрузки или добавь в свой автозапуск)"
        record_fix "RPS/RFS/XPS mask=$mask on $iface (без persist: нет systemd)"
        return 0
    fi
    cat > /etc/systemd/system/node-diagnostic-rps.service <<UNIT
[Unit]
Description=node-diagnostic RPS/RFS/XPS on $iface
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for q in /sys/class/net/$iface/queues/rx-*; do echo $mask > \$\$q/rps_cpus; echo 4096 > \$\$q/rps_flow_cnt; done; for q in /sys/class/net/$iface/queues/tx-*; do echo $mask > \$\$q/xps_cpus; done'
[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable node-diagnostic-rps.service >/dev/null 2>&1 || true
    record_fix "RPS/RFS/XPS mask=$mask on $iface (node-diagnostic-rps.service)"
}

# ── 4. NIC: ring buffers + offloads + txqueuelen ─────────────────────
# shellcheck disable=SC2120  # iface — опциональный аргумент (обычно берётся из default_iface)
opt_nic() {
    ensure_pkg ip iproute2 iproute iproute2 >/dev/null 2>&1 || true
    ensure_pkg ethtool ethtool ethtool ethtool >/dev/null 2>&1 || true
    local iface="${1:-$(default_iface)}"
    [ -z "$iface" ] && { msg_err "интерфейс не определён — нет iproute2 (поставь пакет iproute2)"; return 1; }
    have ethtool || { msg_warn "нет ethtool — пропускаю (apt install ethtool)"; return 0; }
    ui_head "NIC tuning" "ring max + gro/gso/tso + txqueuelen на $iface"

    local max_rx max_tx
    max_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/^RX:/{print $2; exit}')
    max_tx=$(ethtool -g "$iface" 2>/dev/null | awk '/^TX:/{print $2; exit}')

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} ethtool -G $iface rx $max_rx tx $max_tx; -K gro/gso/tso on lro off; txqueuelen 10000"
        return 0
    fi
    backup_settings
    [ -n "$max_rx" ] && ethtool -G "$iface" rx "$max_rx" 2>/dev/null || true
    [ -n "$max_tx" ] && ethtool -G "$iface" tx "$max_tx" 2>/dev/null || true
    # gro/gso/tso on (обратимы, ускоряют), НО lro off — LRO необратимо склеивает
    # пакеты и ЛОМАЕТ форвардинг на роутящей/VPN-ноде
    ethtool -K "$iface" gro on gso on tso on lro off 2>/dev/null || true
    ip link set "$iface" txqueuelen 10000 2>/dev/null || true
    msg_ok "ring/offloads/txqueuelen применены"

    if ! have systemctl || [ ! -d /etc/systemd/system ]; then
        msg_warn "нет systemd — NIC-тюнинг не переживёт reboot (повтори optimize --nic после перезагрузки)"
        record_fix "NIC ring/offloads on $iface (без persist: нет systemd)"
        return 0
    fi
    cat > /etc/systemd/system/node-diagnostic-nic.service <<UNIT
[Unit]
Description=node-diagnostic NIC tuning on $iface
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'ethtool -G $iface rx ${max_rx:-4096} tx ${max_tx:-4096}; ethtool -K $iface gro on gso on tso on; ip link set $iface txqueuelen 10000'
[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable node-diagnostic-nic.service >/dev/null 2>&1 || true
    record_fix "NIC ring/offloads on $iface (node-diagnostic-nic.service)"
}

# ── 5. iptables MSS clamp (большие чанки не упираются в Frag-needed) ──
opt_mss_clamp() {
    ensure_pkg iptables iptables iptables iptables >/dev/null 2>&1 || true
    have iptables || { msg_warn "нет iptables — пропускаю MSS clamp"; return 0; }
    ui_head "MSS clamp" "iptables TCPMSS --clamp-mss-to-pmtu (FORWARD/OUTPUT)"
    # SYN,RST — маска флагов iptables (один аргумент), не разделитель массива
    # shellcheck disable=SC2054
    local rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu)
    local chain
    for chain in FORWARD OUTPUT; do
        if iptables -t mangle -C "$chain" "${rule_args[@]}" 2>/dev/null; then
            msg_info "правило в $chain уже есть"
        else
            run_or_dry "iptables -t mangle -A $chain ${rule_args[*]}" && msg_ok "$chain"
        fi
    done
    [ "$DRY_RUN" = "1" ] && return 0
    backup_settings
    # persist: netfilter-persistent; на apt-дистро при его отсутствии ставим сами
    # (</dev/null + noninteractive — debconf в TTY съедает клавиатурный ввод юзера)
    if ! have netfilter-persistent && have apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 \
            install -y -qq iptables-persistent >/dev/null 2>&1 </dev/null || true
        have netfilter-persistent && msg_ok "поставил iptables-persistent (для сохранения правил)"
    fi
    if have netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 && msg_ok "netfilter-persistent save"
    elif [ -d /etc/iptables ] && have iptables-save; then
        iptables-save > /etc/iptables/rules.v4 && msg_ok "сохранил в /etc/iptables/rules.v4"
    else
        msg_warn "нет netfilter-persistent — правила НЕ переживут reboot. apt install iptables-persistent"
    fi
    record_fix "iptables MSS clamp (FORWARD+OUTPUT)"
}

opt_swappiness() {
    ui_head "vm.swappiness=10"
    write_dropin swappiness <<'EOF'
vm.swappiness = 10
EOF
}

# ── irqbalance: раскидать IRQ NIC по ядрам (для multi-queue — основной механизм) ──
opt_irqbalance() {
    ui_head "irqbalance" "распределение прерываний NIC по ядрам"
    if [ "$(nproc)" -le 1 ]; then msg_info "1 ядро — irqbalance не нужен"; return 0; fi
    if [ "$DRY_RUN" = "1" ]; then echo -e "    ${DIM}[dry-run]${NC} ensure irqbalance + enable --now"; return 0; fi
    ensure_pkg irqbalance irqbalance irqbalance irqbalance >/dev/null 2>&1 || true
    have irqbalance || { msg_warn "нет пакета irqbalance — пропускаю"; return 0; }
    if have systemctl && [ -d /etc/systemd/system ]; then
        systemctl enable --now irqbalance >/dev/null 2>&1 \
            && { msg_ok "irqbalance включён"; record_fix "irqbalance enabled"; } \
            || msg_warn "не удалось включить irqbalance"
    else
        msg_warn "нет systemd — запусти irqbalance вручную"
    fi
}

# ── journald cap: флуд логов/сканов не забивает диск и inodes ─────────
opt_journald() {
    ui_head "journald cap" "лимит журнала 300M + сжатие"
    if ! have systemctl || [ ! -d /etc/systemd ]; then msg_info "нет systemd-journald — пропускаю"; return 0; fi
    if [ "$DRY_RUN" = "1" ]; then echo -e "    ${DIM}[dry-run]${NC} journald.conf.d SystemMaxUse=300M Compress=yes"; return 0; fi
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-node-diagnostic.conf <<'EOF'
[Journal]
SystemMaxUse=300M
SystemKeepFree=500M
SystemMaxFileSize=50M
Compress=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    msg_ok "лимит журнала 300M"
    record_fix "journald cap (SystemMaxUse=300M)"
}

# ── zram-swap (opt-in): компрессированный swap в RAM, анти-OOM без дисковых просадок ──
opt_zram() {
    ui_head "zram-swap" "компрессированный swap в RAM (lz4, ~50% RAM)"
    need_root || die "нужен root"
    local mem_mb zram_mb
    mem_mb=$(( $(_mem_kb)/1024 )); zram_mb=$(( mem_mb / 2 ))
    [ "$zram_mb" -lt 128 ] && zram_mb=128
    if [ "$DRY_RUN" = "1" ]; then echo -e "    ${DIM}[dry-run]${NC} zram0 ${zram_mb}M lz4 · swapon -p 100 · persist-юнит"; return 0; fi
    modprobe zram 2>/dev/null || { msg_warn "модуль zram недоступен в ядре — пропускаю"; return 0; }
    swapon --show=NAME 2>/dev/null | grep -q '^/dev/zram0$' && swapoff /dev/zram0 2>/dev/null || true
    { echo 1 > /sys/block/zram0/reset; } 2>/dev/null || true
    { echo lz4 > /sys/block/zram0/comp_algorithm; } 2>/dev/null || true
    if ! { echo "${zram_mb}M" > /sys/block/zram0/disksize; } 2>/dev/null; then
        msg_warn "не удалось задать disksize zram0 — пропускаю"; return 0
    fi
    mkswap /dev/zram0 >/dev/null 2>&1
    if swapon -p 100 /dev/zram0 2>/dev/null; then
        msg_ok "zram0 ${zram_mb}M lz4 (приоритет 100)"
    else
        msg_warn "swapon zram0 не удался"; return 0
    fi
    if have systemctl && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/node-diagnostic-zram.service <<UNIT
[Unit]
Description=node-diagnostic zram swap
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe zram; echo lz4 > /sys/block/zram0/comp_algorithm; echo ${zram_mb}M > /sys/block/zram0/disksize; mkswap /dev/zram0; swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 || true'
[Install]
WantedBy=multi-user.target
UNIT
        systemctl enable node-diagnostic-zram.service >/dev/null 2>&1 || true
        record_fix "zram swap ${zram_mb}M (node-diagnostic-zram.service)"
    fi
}

opt_all() {
    [ "$DRY_RUN" = "1" ] || need_root || die "нужен root для применения фиксов."
    # ui_head сам даёт верхний отступ секции — отдельные echo больше не нужны
    opt_sysctl
    opt_fd_limits
    opt_rps
    opt_nic
    opt_mss_clamp
    opt_swappiness
    opt_irqbalance
    opt_journald
    echo
    echo -e "  ${G}${BOLD}✓ Оптимизация применена.${NC} ${DIM}Проверить: sudo bash node-diagnostic.sh diagnose. Откат: rollback${NC}"
}

# применить только фиксы, релевантные находкам diagnose (общий FINDINGS_FILE)
opt_from_findings() {
    [ "$DRY_RUN" = "1" ] || need_root || die "нужен root."
    local ff="${FINDINGS_FILE:-}"
    if [ -z "$ff" ] || [ ! -s "$ff" ]; then
        msg_warn "findings пуст/нет (${ff:-не задан}). Сначала: node-diagnostic.sh diagnose"
        return 0
    fi
    local s=0 mss=0 rps=0 nic=0 tag msg
    while IFS='|' read -r _ tag msg; do
        case "$tag" in
            tcp|conntrack|bufferbloat) s=1 ;;
            pmtu)                      s=1; mss=1 ;;
            cpu) echo "$msg" | grep -qi softirq && rps=1 ;;
            nic) echo "$msg" | grep -qi drop && nic=1 ;;
        esac
    done < "$ff"
    if [ $((s+mss+rps+nic)) -eq 0 ]; then
        msg_ok "по находкам релевантных фиксов нет — нода уже настроена"
        return 0
    fi
    echo -e "  ${BOLD}Фиксы по находкам диагностики${NC}"; echo
    [ "$s" = "1" ]   && { opt_sysctl; echo; opt_fd_limits; echo; }
    [ "$mss" = "1" ] && { opt_mss_clamp; echo; }
    [ "$rps" = "1" ] && { opt_rps; echo; }
    [ "$nic" = "1" ] && { opt_nic; echo; }
    echo -e "  ${G}${BOLD}✓ Применены фиксы по находкам.${NC} ${DIM}Откат: rollback${NC}"
}

opt_main() {
    local do_all=1 ff=0 s=0 l=0 r=0 nic=0 mss=0 sw=0 irq=0 jr=0 z=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)           do_all=1 ;;
            --from-findings) do_all=0; ff=1 ;;
            --sysctl)  do_all=0; s=1 ;;
            --limits)  do_all=0; l=1 ;;
            --rps)     do_all=0; r=1 ;;
            --nic)     do_all=0; nic=1 ;;
            --mss)     do_all=0; mss=1 ;;
            --swap)    do_all=0; sw=1 ;;
            --irqbalance) do_all=0; irq=1 ;;
            --journald)   do_all=0; jr=1 ;;
            --zram)       do_all=0; z=1 ;;
            --dry-run) DRY_RUN=1 ;;
            *) die "optimize: неизвестный аргумент $1" ;;
        esac
        shift
    done
    if [ "$do_all" = "1" ]; then opt_all; return; fi
    if [ "$ff" = "1" ]; then opt_from_findings; return; fi
    [ "$DRY_RUN" = "1" ] || need_root || die "нужен root."
    [ "$s" = "1" ]   && { opt_sysctl; echo; }
    [ "$l" = "1" ]   && { opt_fd_limits; echo; }
    [ "$r" = "1" ]   && { opt_rps; echo; }
    [ "$nic" = "1" ] && { opt_nic; echo; }
    [ "$mss" = "1" ] && { opt_mss_clamp; echo; }
    [ "$sw" = "1" ]  && { opt_swappiness; echo; }
    [ "$irq" = "1" ] && { opt_irqbalance; echo; }
    [ "$jr" = "1" ]  && { opt_journald; echo; }
    [ "$z" = "1" ]   && { opt_zram; echo; }
}

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    opt_main "$@"
fi
