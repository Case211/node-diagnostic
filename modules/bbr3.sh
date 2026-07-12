#!/usr/bin/env bash
# modules/bbr3.sh — установка ядра XanMod (TCP BBRv3).
# Mainline-ядро даёт только BBRv1; BBRv3 приходит с кастомным ядром XanMod.
# Гейтит контейнеры (OpenVZ/LXC — своё ядро не поставить), проверяет отпечаток ключа,
# выбирает сборку по psABI, НЕ перезагружает сам. Источник: https://xanmod.org
#
# Standalone:  sudo bash modules/bbr3.sh [--status|--install|--yes|--dry-run]
# Как модуль:  source lib/common.sh; source modules/bbr3.sh; bbr3_menu

if [ -z "${ND_COMMON_LOADED:-}" ]; then
    _self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck source=../lib/common.sh
    source "$_self/../lib/common.sh" 2>/dev/null \
        || { echo "не найден lib/common.sh — нужен весь репозиторий (см. install.sh)" >&2; exit 1; }
fi

XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
# Отпечаток сверять на 2026 (xanmod.org). Полный fingerprint, не 64-бит keyid.
XANMOD_FPR="D38D7D1DA1349567ADED882D86F7D09EE734E623"
BBR3_LEVEL="${BBR3_LEVEL:-}"     # ручной override psABI-уровня (1..4), иначе автодетект

# CPU-модель выглядит маскированной? (qemu64/kvm64 → флаги psABI могут врать → риск не загрузиться)
cpu_masked() { awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | grep -qiE 'qemu|kvm64|common kvm|virtual cpu'; }

# BBRv3 активен, если ядро XanMod и версия >= 6.4 (XanMod по умолчанию с BBRv3 с 6.4.0).
is_bbr3() {
    uname -r | grep -q xanmod || return 1
    local kv; kv=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
    [ -n "$kv" ] || return 1
    [ "$(printf '%s\n6.4\n' "$kv" | sort -V | head -1)" = "6.4" ]
}

bbr3_status() {
    local cc qdisc krel
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    krel=$(uname -r)
    echo -e "  ${BOLD}Текущее состояние${NC}"
    echo -e "    ядро:        $krel"
    echo -e "    congestion:  $cc"
    echo -e "    qdisc:       $qdisc"
    echo -e "    virt:        $(detect_virt)"
    if is_bbr3; then
        msg_ok "BBRv3 активен (XanMod ядро ≥6.4)"
        return 0
    fi
    if [ "$cc" = "bbr" ]; then
        msg_warn "активен BBR, но это v1 (стоковое ядро). Для v3 нужен XanMod."
    else
        msg_warn "BBR не активен (cc=$cc)."
    fi
    return 1
}

bbr3_preflight() {
    is_debian_like || die "XanMod-путь только для Debian/Ubuntu (apt). Твой дистрибутив: $(os_id)."
    if is_container; then
        die "$(detect_virt): контейнер использует ядро хоста — своё ядро поставить нельзя.
    BBRv1 доступен и на текущем ядре: net.core.default_qdisc=fq + tcp_congestion_control=bbr."
    fi
    [ "$(uname -m)" = "x86_64" ] || die "XanMod-пакеты только под x86_64 (у тебя $(uname -m))."
    need_root || die "нужен root."
    for c in wget gpg apt-get; do have "$c" || die "нет $c — установи: apt install -y wget gpg"; done
}

# добавляет ключ (с проверкой отпечатка) и репозиторий
bbr3_add_repo() {
    local codename; codename=$(os_codename)
    [ -n "$codename" ] || die "не определил codename дистрибутива (/etc/os-release)."
    msg_info "codename: $codename"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} wget $XANMOD_KEY_URL | gpg --dearmor -o $XANMOD_KEYRING"
        echo -e "    ${DIM}[dry-run]${NC} проверка отпечатка $XANMOD_FPR"
        echo -e "    ${DIM}[dry-run]${NC} echo 'deb [signed-by=$XANMOD_KEYRING] http://deb.xanmod.org $codename main' > $XANMOD_LIST"
        return 0
    fi

    mkdir -p /etc/apt/keyrings
    local tmpkey; tmpkey=$(mktemp)
    if ! wget -qO - "$XANMOD_KEY_URL" | gpg --dearmor > "$tmpkey" 2>/dev/null; then
        rm -f "$tmpkey"; die "не скачал/не распаковал ключ XanMod ($XANMOD_KEY_URL)."
    fi
    # проверка отпечатка перед установкой ключа
    local got
    got=$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    if [ "$got" != "$XANMOD_FPR" ]; then
        rm -f "$tmpkey"
        die "отпечаток ключа не совпал!
    ожидал: $XANMOD_FPR
    получил: ${got:-<пусто>}
    Установка прервана (возможна подмена / устаревший отпечаток — сверь на xanmod.org)."
    fi
    install -m 0644 "$tmpkey" "$XANMOD_KEYRING"; rm -f "$tmpkey"
    msg_ok "ключ проверен ($XANMOD_FPR) и установлен"

    echo "deb [signed-by=$XANMOD_KEYRING] http://deb.xanmod.org $codename main" > "$XANMOD_LIST"
    if ! apt-get update >/dev/null 2>&1; then
        msg_warn "apt update дал ошибку для '$codename' — возможно codename не поддержан репо. Убери $XANMOD_LIST если что."
        return 1
    fi
    msg_ok "репозиторий XanMod добавлен"
}

# подбирает доступный пакет по psABI-уровню, деградируя v3→v2→v1
bbr3_pick_pkg() {
    local lvl="${BBR3_LEVEL:-$(cpu_psabi_level)}"
    local l
    for l in "$lvl" 2 1; do
        for pkg in "linux-xanmod-lts-x64v${l}" "linux-xanmod-x64v${l}"; do
            if apt-cache show "$pkg" >/dev/null 2>&1; then
                echo "$pkg"; return 0
            fi
        done
    done
    return 1
}

bbr3_install() {
    bbr3_preflight
    local eff_lvl="${BBR3_LEVEL:-$(cpu_psabi_level)}"
    echo -e "  ${BOLD}Установка XanMod-ядра (BBRv3)${NC}"
    echo -e "    ${DIM}virt=$(detect_virt) · psABI=v${eff_lvl}$([ -n "$BBR3_LEVEL" ] && echo ' (override)') · $(os_id)/$(os_codename)${NC}"
    if [ -z "$BBR3_LEVEL" ] && cpu_masked; then
        msg_warn "CPU-модель маскирована (qemu64/kvm64) — флаги psABI могут врать. Если ядро не загрузится, переставь консервативнее: --level 2"
    fi
    echo

    bbr3_add_repo || die "не удалось добавить репозиторий."

    local pkg
    if [ "$DRY_RUN" = "1" ]; then
        pkg="linux-xanmod-lts-x64v${eff_lvl}"
        echo -e "    ${DIM}[dry-run]${NC} выбрал бы пакет: $pkg"
        echo -e "    ${DIM}[dry-run]${NC} apt-get install -y $pkg && update-grub"
        echo -e "    ${DIM}[dry-run]${NC} reboot НЕ выполняется автоматически"
        return 0
    fi

    pkg=$(bbr3_pick_pkg) || die "не нашёл пакет XanMod под psABI v${eff_lvl}. Проверь 'apt-cache search linux-xanmod'."
    msg_info "пакет: $pkg"

    if [ "${ASSUME_YES:-0}" != "1" ]; then
        echo
        echo -e "    ${Y}Ставлю ядро $pkg. Потребуется РУЧНАЯ перезагрузка. Продолжить? [y/N]${NC}"
        local a; read -r a; [ "${a,,}" = "y" ] || { echo "    отменено"; return 1; }
    fi

    if ! apt-get install -y "$pkg"; then
        die "apt install $pkg упал. Ядро не установлено, система не тронута."
    fi
    update-grub >/dev/null 2>&1 || true
    record_fix "xanmod kernel installed ($pkg)"
    msg_ok "ядро $pkg установлено"

    bbr3_prereboot_check "$pkg"

    # добить sysctl, чтобы после reboot bbr сразу включился.
    # Если optimize уже наложил tuning-dropin — правим cc прямо в нём: отдельный
    # bbr-файл сортируется РАНЬШЕ tuning (b < t), и tuning перекрывал бы cc обратно
    # (классика: tuning записал cubic на ядре без bbr → поставили XanMod → опять cubic).
    local tuning="/etc/sysctl.d/${ND_DROPIN_PREFIX}-tuning.conf"
    if [ -f "$tuning" ]; then
        sed -i 's/^net\.ipv4\.tcp_congestion_control *=.*/net.ipv4.tcp_congestion_control = bbr/' "$tuning"
        grep -q '^net\.ipv4\.tcp_congestion_control' "$tuning" \
            || echo "net.ipv4.tcp_congestion_control = bbr" >> "$tuning"
        msg_ok "cc=bbr прописан в $tuning (qdisc оставлен — cake/fq оба ок для BBR)"
        record_fix "bbr3: cc=bbr in tuning dropin"
    else
        write_dropin bbr <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    echo
    echo -e "  ${Y}${BOLD}⚠ Нужна перезагрузка${NC} — BBRv3 подхватится только после неё."
    echo -e "    ${DIM}На удалённой ноде убедись, что есть VNC/serial-консоль провайдера (на случай, если новое ядро не загрузится — в GRUB выберешь старое).${NC}"
    echo -e "    ${DIM}Перезагрузить:${NC} ${BOLD}reboot${NC}"
    echo -e "    ${DIM}После reboot проверь:${NC} ${BOLD}uname -r${NC} ${DIM}(должно быть xanmod) и${NC} ${BOLD}bash modules/bbr3.sh --status${NC}"
}

# проверки перед reboot: новое ядро на месте, старое — тоже (путь отката), GRUB видит
bbr3_prereboot_check() {
    local pkg="$1"
    echo
    echo -e "  ${BOLD}Проверки перед reboot${NC}"
    ls /boot/vmlinuz-*xanmod* >/dev/null 2>&1 \
        && msg_ok "образ нового ядра есть в /boot" \
        || msg_err "НЕ вижу /boot/vmlinuz-*xanmod* — установка могла не завершиться"
    local nkern; nkern=$(ls /boot/vmlinuz-* 2>/dev/null | wc -l)
    if [ "$nkern" -ge 2 ]; then
        msg_ok "в /boot ≥2 ядер — старое остаётся как откат"
    else
        msg_warn "в /boot только одно ядро — нет запасного на случай проблем"
    fi
    grep -qE 'GRUB_TIMEOUT=[1-9]' /etc/default/grub 2>/dev/null \
        && msg_ok "GRUB_TIMEOUT>0 (успеешь выбрать ядро в меню)" \
        || msg_warn "GRUB_TIMEOUT=0 — меню GRUB не покажется; поставь GRUB_TIMEOUT=5 для страховки"
}

bbr3_menu() {
    echo
    bbr3_status && { echo -e "\n  ${G}BBRv3 уже активен — делать нечего.${NC}"; return 0; }
    echo
    if ! can_install_kernel; then
        echo -e "  ${Y}Своё ядро тут поставить нельзя${NC} ${DIM}(контейнер/не-x86_64). Доступен BBRv1 на текущем ядре.${NC}"
        echo -e "  ${DIM}Включить BBRv1:${NC} ${BOLD}bash modules/optimize.sh${NC} ${DIM}(fix_sysctl поставит bbr+cake).${NC}"
        return 0
    fi
    echo -e "  ${DIM}Поставить XanMod-ядро для BBRv3? Это heavy-операция с ручным reboot.${NC}"
    echo -e "  ${DIM}Сначала посмотри план:${NC} ${BOLD}bash modules/bbr3.sh --install --dry-run${NC}"
    echo -e "  ${DIM}Установить:${NC} ${BOLD}sudo bash modules/bbr3.sh --install${NC}"
}

bbr3_main() {
    local action="menu"
    while [ $# -gt 0 ]; do
        case "$1" in
            --status)  action="status" ;;
            --install) action="install" ;;
            --level)   BBR3_LEVEL="$2"; shift ;;
            --yes|-y)  ASSUME_YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            *) die "bbr3: неизвестный аргумент $1" ;;
        esac
        shift
    done
    case "$action" in
        status)  bbr3_status ;;
        install) bbr3_install ;;
        menu)    bbr3_menu ;;
    esac
}

# запуск напрямую (не через source)
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    bbr3_main "$@"
fi
