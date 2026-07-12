#!/usr/bin/env bash
# modules/optimize.sh — сетевой/системный тюнинг ноды (sysctl, FD-лимиты, RPS/RFS/XPS, NIC, MSS clamp).
# Всё живёт в namespaced drop-in (99-node-diagnostic-*), откат — modules/rollback.sh.
#
# Standalone:  sudo bash modules/optimize.sh [--all|--sysctl|--limits|--rps|--nic|--mss|--dry-run]
# Как модуль:  source lib/common.sh; source modules/optimize.sh; opt_all

if [ -z "${ND_COMMON_LOADED:-}" ]; then
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../lib/common.sh
    source "$_self/../lib/common.sh"
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

    echo -e "  ${BOLD}sysctl tuning${NC} ${DIM}(RAM=$(( $(_mem_kb)/1024 ))M → буферы $((sock_max/1024/1024))M · conntrack $ct_max · cc=$cc · qdisc=$qdisc)${NC}"

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
    echo -e "  ${BOLD}FD-лимиты${NC} ${DIM}(file-max, nofile для сессий и systemd-сервисов)${NC}"
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
# shellcheck disable=SC2120  # iface — опциональный аргумент (обычно берётся из default_iface)
opt_rps() {
    local iface="${1:-$(default_iface)}"
    [ -z "$iface" ] && { msg_err "интерфейс не определён"; return 1; }
    local n mask; n=$(nproc); mask=$(printf '%x' $(( (1 << n) - 1 )))
    echo -e "  ${BOLD}RPS/RFS/XPS${NC} ${DIM}mask=$mask на $iface${NC}"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} rps_cpus/xps_cpus=$mask, rps_flow_cnt=4096, rps_sock_flow_entries=32768"
        return 0
    fi
    backup_settings
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    local q
    for q in /sys/class/net/"$iface"/queues/rx-*; do
        [ -d "$q" ] || continue
        echo "$mask" > "$q/rps_cpus"      2>/dev/null || true
        echo 4096   > "$q/rps_flow_cnt"   2>/dev/null || true
    done
    for q in /sys/class/net/"$iface"/queues/tx-*; do
        [ -d "$q" ] || continue
        echo "$mask" > "$q/xps_cpus"      2>/dev/null || true
    done
    msg_ok "применено к очередям $iface"

    # persist: sysctl для sock_flow_entries + systemd-юнит для per-queue
    write_dropin rps <<'EOF'
net.core.rps_sock_flow_entries = 32768
EOF
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
    local iface="${1:-$(default_iface)}"
    [ -z "$iface" ] && { msg_err "интерфейс не определён"; return 1; }
    have ethtool || { msg_warn "нет ethtool — пропускаю (apt install ethtool)"; return 0; }
    echo -e "  ${BOLD}NIC tuning${NC} ${DIM}ring max + gro/gso/tso + txqueuelen на $iface${NC}"

    local max_rx max_tx
    max_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/^RX:/{print $2; exit}')
    max_tx=$(ethtool -g "$iface" 2>/dev/null | awk '/^TX:/{print $2; exit}')

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} ethtool -G $iface rx $max_rx tx $max_tx; -K gro/gso/tso on; txqueuelen 10000"
        return 0
    fi
    backup_settings
    [ -n "$max_rx" ] && ethtool -G "$iface" rx "$max_rx" 2>/dev/null || true
    [ -n "$max_tx" ] && ethtool -G "$iface" tx "$max_tx" 2>/dev/null || true
    ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
    ip link set "$iface" txqueuelen 10000 2>/dev/null || true
    msg_ok "ring/offloads/txqueuelen применены"

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
    have iptables || { msg_warn "нет iptables — пропускаю MSS clamp"; return 0; }
    echo -e "  ${BOLD}MSS clamp${NC} ${DIM}iptables TCPMSS --clamp-mss-to-pmtu (FORWARD/OUTPUT)${NC}"
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
    echo -e "  ${BOLD}vm.swappiness=10${NC}"
    write_dropin swappiness <<'EOF'
vm.swappiness = 10
EOF
}

opt_all() {
    [ "$DRY_RUN" = "1" ] || need_root || die "нужен root для применения фиксов."
    opt_sysctl;   echo
    opt_fd_limits; echo
    opt_rps;      echo
    opt_nic;      echo
    opt_mss_clamp; echo
    opt_swappiness; echo
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
    local do_all=1 ff=0 s=0 l=0 r=0 nic=0 mss=0 sw=0
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
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    opt_main "$@"
fi
