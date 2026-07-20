#!/usr/bin/env bash
# modules/rollback.sh — снять всё, что наложил optimize (namespaced drop-in подход).
# Удаляет только СВОИ артефакты (99-node-diagnostic-*, node-diagnostic-*.service) — чужой
# конфиг не трогает. Не откатывает XanMod-ядро (см. bbr3) и не снимает firewall (он generate-only).
#
# Standalone:  sudo bash modules/rollback.sh [--yes|--dry-run]

if [ -z "${ND_COMMON_LOADED:-}" ]; then
    _self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck source=../lib/common.sh
    source "$_self/../lib/common.sh" 2>/dev/null \
        || { echo "не найден lib/common.sh — нужен весь репозиторий (см. install.sh)" >&2; exit 1; }
fi

rollback_all() {
    [ "$DRY_RUN" = "1" ] || need_root || die "нужен root."
    local removed=0

    echo -e "  ${BOLD}Откат артефактов node-diagnostic${NC}"

    _rm() {
        local p=$1
        [ -e "$p" ] || return 0
        if [ "$DRY_RUN" = "1" ]; then echo -e "    ${DIM}[dry-run]${NC} rm $p"; else rm -f "$p" && msg_ok "удалён $p"; fi
        removed=$((removed+1))
    }

    # sysctl drop-in
    local f
    for f in /etc/sysctl.d/${ND_DROPIN_PREFIX}-*.conf; do [ -e "$f" ] && _rm "$f"; done
    # modules-load.d (tcp_bbr/nf_conntrack/sch_cake)
    _rm "/etc/modules-load.d/${ND_DROPIN_PREFIX}.conf"
    # FD-лимиты
    _rm /etc/security/limits.d/99-node-diagnostic.conf
    _rm /etc/systemd/system.conf.d/99-node-diagnostic-limits.conf
    _rm /etc/systemd/user.conf.d/99-node-diagnostic-limits.conf
    # journald cap
    _rm /etc/systemd/journald.conf.d/99-node-diagnostic.conf

    # systemd-юниты (RPS/NIC/zram; для zram disable --now дёргает ExecStop=swapoff)
    local svc
    for svc in node-diagnostic-rps node-diagnostic-nic node-diagnostic-zram; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$svc.service"; then
            if [ "$DRY_RUN" = "1" ]; then
                echo -e "    ${DIM}[dry-run]${NC} systemctl disable --now $svc.service"
            else
                systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
                msg_ok "отключён $svc.service"
            fi
            removed=$((removed+1))
        fi
        _rm "/etc/systemd/system/$svc.service"
    done

    # iptables MSS clamp (наше правило)
    if have iptables; then
        # shellcheck disable=SC2054  # SYN,RST — маска флагов iptables, не разделитель массива
        local rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu)
        local chain
        for chain in FORWARD OUTPUT; do
            if iptables -t mangle -C "$chain" "${rule_args[@]}" 2>/dev/null; then
                if [ "$DRY_RUN" = "1" ]; then
                    echo -e "    ${DIM}[dry-run]${NC} iptables -t mangle -D $chain (MSS clamp)"
                else
                    iptables -t mangle -D "$chain" "${rule_args[@]}" 2>/dev/null && msg_ok "снят MSS clamp из $chain"
                fi
                removed=$((removed+1))
            fi
        done
    fi

    # zram-swap: снять, если наш zram0 всё ещё активен (например, без systemd)
    if swapon --show=NAME 2>/dev/null | grep -q '^/dev/zram0$'; then
        if [ "$DRY_RUN" = "1" ]; then
            echo -e "    ${DIM}[dry-run]${NC} swapoff /dev/zram0 (zram)"
        else
            swapoff /dev/zram0 2>/dev/null && msg_ok "снят zram0 swap"
            { echo 1 > /sys/block/zram0/reset; } 2>/dev/null || true
        fi
        removed=$((removed+1))
    fi

    if [ "$DRY_RUN" != "1" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl try-restart systemd-journald 2>/dev/null || true
        sysctl --system >/dev/null 2>&1 || true
        record_fix "rollback: removed $removed artifacts"
    fi

    echo
    if [ "$removed" -eq 0 ]; then
        echo -e "  ${DIM}Артефактов node-diagnostic не найдено — откатывать нечего.${NC}"
    else
        echo -e "  ${G}${BOLD}✓ Откат готов${NC} ${DIM}(снято элементов: $removed). sysctl перечитан.${NC}"
    fi
    echo -e "  ${DIM}Не входит в откат:${NC}"
    echo -e "  ${DIM}  · XanMod-ядро → ${BOLD}sudo apt purge 'linux-xanmod*' && sudo update-grub && reboot${NC}"
    echo -e "  ${DIM}  · firewall/fail2ban/sshd → они generate-only, откат в их APPLY.txt${NC}"
    echo -e "  ${DIM}  · eBPF-шейпер → снимается отдельно: ${BOLD}node-diagnostic.sh shape off${NC}"
    echo -e "  ${DIM}  · sysctl-бэкапы дампов лежат в $BACKUP_DIR${NC}"
}

rollback_main() {
    local yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y)  yes=1 ;;
            --dry-run) DRY_RUN=1 ;;
            *) die "rollback: неизвестный аргумент $1" ;;
        esac
        shift
    done
    if [ "$yes" != "1" ] && [ "$DRY_RUN" != "1" ] && [ -t 0 ]; then
        printf "  Откатить все изменения node-diagnostic? [y/N]: "
        local a; read -r a; [ "${a,,}" = "y" ] || { echo "  отменено"; return 0; }
    fi
    rollback_all
}

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    rollback_main "$@"
fi
