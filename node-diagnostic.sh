#!/usr/bin/env bash
# node-diagnostic.sh — точка входа модульного тулкита ноды (Remnawave / VPN / Linux).
# Диспетчер: интерактивное меню или прямой вызов модуля. Логика — в modules/, общее — в lib/common.sh.
# Источник: https://github.com/Case211/node-diagnostic
#
#   sudo bash node-diagnostic.sh                 # меню (или диагностика, если не TTY)
#   sudo bash node-diagnostic.sh diagnose -q     # только диагностика
#   sudo bash node-diagnostic.sh optimize --all  # тюнинг
#   sudo bash node-diagnostic.sh protect --panel-ip 1.2.3.4   # генерация защиты
#   sudo bash node-diagnostic.sh bbr3 --install  # XanMod (BBRv3)
#   sudo bash node-diagnostic.sh rollback        # откат оптимизаций

set -u
# ${BASH_SOURCE[0]:-$0}: при `curl … | bash` BASH_SOURCE пуст — без фоллбэка set -u
# роняет скрипт с «unbound variable» вместо внятного сообщения ниже
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MOD="$SELF/modules"

# shellcheck source=lib/common.sh
if ! source "$SELF/lib/common.sh" 2>/dev/null; then
    echo "Ошибка: не найден lib/common.sh рядом со скриптом (запуск через pipe?)." >&2
    echo "Тулкит модульный — нужен весь репозиторий. Установка одной командой:" >&2
    echo "  curl -sSL https://raw.githubusercontent.com/Case211/node-diagnostic/main/install.sh | sudo bash" >&2
    echo "или вручную:" >&2
    echo "  git clone https://github.com/Case211/node-diagnostic && cd node-diagnostic && sudo bash node-diagnostic.sh" >&2
    exit 1
fi
export FINDINGS_FILE ND_STATE_DIR   # общий findings-файл между диагностикой и модулями
export ND_VERSION                   # единый источник версии (diagnose.sh печатает её)

run() { local m="$1"; shift; bash "$MOD/$m.sh" "$@"; }

banner() {
    echo
    echo -e "  ${C}${BOLD}NODE DIAGNOSTIC${NC}  ${DIM}v${ND_VERSION} · toolkit${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}$(date -u +'%Y-%m-%d %H:%M UTC') · $(hostname) · $(detect_virt)${NC}"
}

usage() {
    cat <<HELP
node-diagnostic.sh v$ND_VERSION — модульный тулкит ноды (Remnawave / VPN / Linux).

Команды:
  diagnose [-q|-v|--no-net]      Диагностика ноды (23 чека, дашборд, вердикт)
  optimize [--all|--from-findings|--sysctl|--limits|--rps|--nic|--mss|--dry-run]
                                 Тюнинг: sysctl/BBR/FD-лимиты/RPS-RFS-XPS/NIC/MSS clamp
                                 --from-findings — только фиксы по находкам последней диагностики
  protect  [--panel-ip IP] [--node-port N] [--out DIR]
                                 Защита под Remnawave (firewall/fail2ban/SSH) — ГЕНЕРАЦИЯ, не применяет
  bbr3     [--status|--install|--dry-run|--yes]
                                 BBRv3 через XanMod-ядро (гейт контейнеров, без автоперезагрузки)
  rollback [--yes|--dry-run]     Откат наложенных оптимизаций (namespaced-артефакты)
  menu                           Интерактивное меню (по умолчанию в TTY)
  help | --version

Без аргументов: меню в терминале, диагностика — если ввод не интерактивный (curl | bash).
HELP
}

menu() {
    while true; do
        banner
        echo
        echo -e "    ${C}${BOLD}[1]${NC} Диагностика        ${DIM}23 чека, дашборд, вердикт${NC}"
        echo -e "    ${C}${BOLD}[2]${NC} Оптимизация        ${DIM}sysctl/BBR/FD/RPS/NIC${NC}"
        echo -e "    ${C}${BOLD}[3]${NC} Защита ноды        ${DIM}firewall/fail2ban/SSH (Remnawave, генерация)${NC}"
        echo -e "    ${C}${BOLD}[4]${NC} BBRv3-ядро         ${DIM}XanMod, нужен reboot${NC}"
        echo -e "    ${C}${BOLD}[5]${NC} Откат              ${DIM}снять наложенные оптимизации${NC}"
        echo -e "    ${C}${BOLD}[0]${NC} Выход"
        echo
        printf "  ${BOLD}Выбор${NC} ${DIM}[0-5]${NC}: "
        local c; read -r c
        echo
        case "$c" in
            1) menu_diagnose ;;
            2) menu_optimize ;;
            3) menu_protect ;;
            4) run bbr3 ;;
            5) run rollback ;;
            0|q|"") echo -e "  ${DIM}выход${NC}"; return 0 ;;
            *) echo -e "  ${Y}нет такого пункта${NC}" ;;
        esac
        echo
        printf "  ${DIM}Enter — вернуться в меню…${NC}"; read -r _
    done
}

menu_optimize() {
    if [ ! -t 0 ]; then run optimize --all; return; fi
    echo -e "  ${BOLD}Оптимизация${NC}"
    echo -e "    ${DIM}[a] всё   [f] по находкам диагностики   [d] предпросмотр (dry-run)   [Enter] всё${NC}"
    printf "  выбор: "; local c; read -r c
    case "${c,,}" in
        f) run optimize --from-findings ;;
        d) run optimize --dry-run ;;
        *) run optimize --all ;;
    esac
}

menu_diagnose() {
    if [ ! -t 0 ]; then run diagnose; return; fi
    echo -e "  ${BOLD}Диагностика${NC}"
    echo -e "    ${DIM}[Enter] полная (~5 мин)   [q] быстрая (~1 мин, без долгих тестов)${NC}"
    printf "  выбор: "; local c; read -r c
    case "${c,,}" in
        q) run diagnose -q ;;
        *) run diagnose ;;
    esac
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}
is_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

menu_protect() {
    if [ ! -t 0 ]; then run protect; return; fi
    echo -e "  ${BOLD}Защита ноды${NC} ${DIM}(генерация firewall/fail2ban/SSH — ничего не применяет)${NC}"
    local pip np
    while true; do
        printf "  IP панели Remnawave ${DIM}[Enter — оставить плейсхолдер <PANEL_IP>]${NC}: "
        read -r pip
        [ -z "$pip" ] || is_ipv4 "$pip" && break
        echo -e "    ${Y}это не IPv4-адрес${NC} ${DIM}(firewall.nft ждёт именно IPv4)${NC}"
    done
    while true; do
        printf "  NODE_PORT (панель→нода) ${DIM}[Enter — автодетект из .env/docker]${NC}: "
        read -r np
        [ -z "$np" ] || is_port "$np" && break
        echo -e "    ${Y}порт — это число 1-65535${NC}"
    done
    local args=()
    [ -n "$pip" ] && args+=(--panel-ip "$pip")
    [ -n "$np" ]  && args+=(--node-port "$np")
    run protect ${args[@]+"${args[@]}"}
}

# ── диспетчер ────────────────────────────────────────────────────────
cmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
    diagnose|diag)         run diagnose "$@" ;;
    optimize|opt|tune)     run optimize "$@" ;;
    protect|firewall|fw)   run protect "$@" ;;
    bbr3|kernel)           run bbr3 "$@" ;;
    rollback|revert)       run rollback "$@" ;;
    menu)                  menu ;;
    help|-h|--help)        usage ;;
    --version|-V)          echo "node-diagnostic $ND_VERSION" ;;
    "")
        if [ -t 0 ]; then menu; else run diagnose; fi
        ;;
    *)
        echo "Неизвестная команда: $cmd (см. help)" >&2
        usage
        exit 2 ;;
esac
