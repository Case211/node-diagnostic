#!/usr/bin/env bash
# lib/common.sh — общие примитивы для node-diagnostic (палитра, детекторы, backup, drop-in, dry-run).
# Только для source: `source "$(dirname "$0")/lib/common.sh"`. Напрямую не запускается.

# защита от двойного подключения
[ -n "${ND_COMMON_LOADED:-}" ] && return 0
ND_COMMON_LOADED=1

# UTF-8 локаль для ВСЕХ модулей: без неё ${#s} и ${s:0:n} считают байты, а не символы —
# рамки карточек и паддинг кириллицы едут. Экспорт наследуется в под-процессы модулей.
export LANG=C.UTF-8

ND_VERSION="4.2.0"
ND_DROPIN_PREFIX="99-node-diagnostic"        # namespace для всех наших sysctl.d / systemd артефактов

# ────────────────────────────────────────────────────────────────────
# Палитра (цвета/CLR_LINE используются модулями, которые source этот файл)
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034
if [ -t 1 ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; C=$'\033[0;36m'; M=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'; CLR_LINE=$'\033[K'
else
    R=""; G=""; Y=""; B=""; C=""; M=""; BOLD=""; DIM=""; NC=""; CLR_LINE=""
fi

# ── Семантические токены (единый визуальный язык) ────────────────────
# Смысл, а не цвет: ok/warn/bad/info/accent/muted + иконки под каждым статусом.
# Кросс-модульные (diagnose/optimize/protect/node-diagnostic) — export снимает SC2034.
C_OK=$G; C_WARN=$Y; C_BAD=$R; C_INFO=$B; C_ACCENT=$C; C_MUTED=$DIM
# ⚠ (U+26A0) по Unicode default = emoji-presentation → 2 колонки в kitty/wezterm/iTerm2
# и т.п. VS15 (U+FE0E) форсит text-presentation = гарантированно 1 колонка везде.
# vlen ниже игнорирует вариационные селекторы, чтобы ширина совпала с рендером.
I_OK="✓"; I_WARN=$'⚠︎'; I_BAD="✗"; I_INFO="·"; I_SKIP="·"
export C_OK C_WARN C_BAD C_INFO C_ACCENT C_MUTED I_OK I_WARN I_BAD I_INFO I_SKIP
# статус (ok/warn/bad/skip/info) → цвет и иконка одним источником
sem_color() { case "$1" in ok) printf '%s' "$G";; warn) printf '%s' "$Y";; bad) printf '%s' "$R";; info) printf '%s' "$B";; *) printf '%s' "$DIM";; esac; }
sem_icon()  { case "$1" in ok) printf '%s' "$I_OK";; warn) printf '%s' "$I_WARN";; bad) printf '%s' "$I_BAD";; info) printf '%s' "$I_INFO";; *) printf '%s' "$I_SKIP";; esac; }

# ── UI-примитивы: карточки в рамках с корректной шириной ─────────────
# Ширина считается по ВИДИМЫМ колонкам (ANSI срезаются, кириллица = 1) —
# иначе рамки едут. Проверено на bash и busybox.
ND_ESC=$'\033'
shopt -s extglob 2>/dev/null || true
strip_ansi() { local s=$1; printf '%s' "${s//${ND_ESC}\[*([0-9;])m/}"; }
vlen() {
    local s; s=$(strip_ansi "$1")
    s=${s//$'︎'/}; s=${s//$'️'/}   # вариационные селекторы zero-width — не считать
    printf '%s' "${#s}"
}

# Ширина карточки адаптируется под терминал: на узком SSH-клиенте фикс-58
# переносил бы рамки. Полная карточка = ND_BOX_W+6 колонок (отступ+рамка+поля).
_detect_cols() {
    local c=""
    [ -t 1 ] && c=$( { tput cols; } 2>/dev/null )
    [ -z "$c" ] && c="${COLUMNS:-}"
    case "$c" in ''|*[!0-9]*) c=80 ;; esac   # не-TTY/мусор → безопасные 80
    printf '%s' "$c"
}
if [ -z "${ND_BOX_W:-}" ]; then
    _cols=$(_detect_cols)
    if [ "$_cols" -ge 66 ]; then ND_BOX_W=58            # штатный широкий терминал
    else ND_BOX_W=$(( _cols - 8 )); [ "$ND_BOX_W" -lt 30 ] && ND_BOX_W=30; fi
fi
# горизонтальная линия нужной длины (режем заранее готовую по символам — UTF-8-safe)
ND_HR=""; while [ "${#ND_HR}" -lt "$((ND_BOX_W + 4))" ]; do ND_HR="${ND_HR}─"; done

# русское склонение по числу: plural_ru N "одна" "две" "пять"
plural_ru() {
    local n=$1 m10=$(( ${1#-} % 10 )) m100=$(( ${1#-} % 100 ))
    if   [ "$m10" -eq 1 ] && [ "$m100" -ne 11 ]; then printf '%s' "$2"
    elif [ "$m10" -ge 2 ] && [ "$m10" -le 4 ] && { [ "$m100" -lt 12 ] || [ "$m100" -gt 14 ]; }; then printf '%s' "$3"
    else printf '%s' "$4"; fi
}

# обрезать видимый plain-текст (без ANSI) до N колонок с «…»
ui_fit() {
    local s=$1 n=$2
    [ "${#s}" -le "$n" ] && { printf '%s' "$s"; return; }
    printf '%s…' "${s:0:$((n-1))}"
}

# повтор ─ по СИМВОЛАМ (bash printf %.*s режет UTF-8 по байтам → мусор; подстрока — по символам)
_hr() { printf '%s' "${ND_HR:0:$1}"; }
# pad пробелами до N видимых колонок (учёт кириллицы/ANSI — printf %-Ns считает байты, врёт)
_vpad() { local s=$1 n=$2; local p=$(( n - $(vlen "$s") )); [ "$p" -lt 0 ] && p=0; printf '%s%*s' "$s" "$p" ""; }

box_top() {   # box_top "ЗАГОЛОВОК"
    local t="$1"                                 # "─ TITLE ─" = 4 обрамляющих + len
    local dash_n=$(( ND_BOX_W + 2 - 4 - ${#t} ))
    [ "$dash_n" -lt 1 ] && dash_n=1
    printf '  %s┌─ %s%s%s ─%s┐%s\n' "$DIM" "$C_ACCENT$BOLD" "$t" "$NC$DIM" "$(_hr "$dash_n")" "$NC"
}
box_row() {   # box_row "<контент, можно с ANSI>"
    local content=$1 vl pad
    vl=$(vlen "$content"); pad=$(( ND_BOX_W - vl )); [ "$pad" -lt 0 ] && pad=0
    printf '  %s│%s %s%*s %s│%s\n' "$DIM" "$NC" "$content" "$pad" "" "$DIM" "$NC"
}
box_kv() {    # box_kv "Ключ" "значение" [ширина_ключа] — выровненная пара
    local k=$1 v=$2 kw="${3:-11}" vw
    vw=$(( ND_BOX_W - kw - 1 ))
    v=$(ui_fit "$v" "$vw")
    box_row "${DIM}$(_vpad "$k" "$kw")${NC} $v"
}
box_bottom() { printf '  %s└%s┘%s\n' "$DIM" "$(_hr $((ND_BOX_W + 2)))" "$NC"; }

# заголовок секции для потоковых модулей (optimize/protect) — акцент-полоска без рамки
ui_head() {
    printf '\n  %s%s▍%s %s%s%s' "$C_ACCENT" "$BOLD" "$NC" "$BOLD" "$1" "$NC"
    [ -n "${2:-}" ] && printf ' %s%s%s' "$DIM" "$2" "$NC"
    printf '\n'
}

# тонкая линия во всю ширину карточки (без подписи или с подписью по центру)
ui_rule() { printf '  %s%s%s\n' "$DIM" "$(_hr $((ND_BOX_W + 4)))" "$NC"; }
ui_divider() {   # ui_divider "ТЕКСТ" — линия с центрированной приглушённой подписью
    local t=" $1 " vl total left right
    vl=$(vlen "$t"); total=$(( ND_BOX_W + 4 ))
    left=$(( (total - vl) / 2 )); [ "$left" -lt 1 ] && left=1
    right=$(( total - vl - left )); [ "$right" -lt 1 ] && right=1
    printf '  %s%s%s%s%s%s%s%s\n' "$DIM" "$(_hr "$left")" "$NC" "${C_MUTED}${BOLD}$t$NC" "$DIM" "$(_hr "$right")" "$NC" ""
}

# ────────────────────────────────────────────────────────────────────
# Базовые хелперы
# ────────────────────────────────────────────────────────────────────
have()      { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ]; }

msg_ok()   { echo -e "    ${G}${I_OK}${NC} $*"; }
msg_warn() { echo -e "    ${Y}${I_WARN}${NC} $*"; }
msg_err()  { echo -e "    ${R}${I_BAD}${NC} $*"; }
msg_info() { echo -e "    ${DIM}$*${NC}"; }

die() { echo -e "${R}${BOLD}${I_BAD}${NC} $*" >&2; exit 1; }

# ────────────────────────────────────────────────────────────────────
# Состояние (общий findings-файл между модулями)
# ────────────────────────────────────────────────────────────────────
if need_root; then
    ND_STATE_DIR="${ND_STATE_DIR:-/run/node-diagnostic}"
else
    ND_STATE_DIR="${ND_STATE_DIR:-${TMPDIR:-/tmp}/node-diagnostic-$(id -u)}"
fi
mkdir -p "$ND_STATE_DIR" 2>/dev/null || ND_STATE_DIR="$(mktemp -d)"
FINDINGS_FILE="${FINDINGS_FILE:-$ND_STATE_DIR/findings}"

# ────────────────────────────────────────────────────────────────────
# Dry-run / журнал / backup
# ────────────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"
run_or_dry() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} $*"
        return 0
    fi
    # команды приходят одной строкой (собраны с ${arr[*]}), eval здесь намеренный
    # shellcheck disable=SC2294
    eval "$@"
}

FIX_LOG="${FIX_LOG:-/etc/node-diagnostic.applied}"
record_fix() {
    [ "$DRY_RUN" = "1" ] && return 0
    { printf '%s | %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$FIX_LOG"; } 2>/dev/null || true
}

BACKUP_DIR="${BACKUP_DIR:-/var/backups/node-diagnostic}"
BACKUP_DONE=0
backup_settings() {
    [ "$DRY_RUN" = "1" ] && return 0
    [ "$BACKUP_DONE" = "1" ] && return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 0
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    sysctl -a 2>/dev/null > "$BACKUP_DIR/sysctl-$ts.txt"
    have iptables-save  && iptables-save  > "$BACKUP_DIR/iptables-$ts.rules"  2>/dev/null
    have ip6tables-save && ip6tables-save > "$BACKUP_DIR/ip6tables-$ts.rules" 2>/dev/null
    have nft            && nft list ruleset > "$BACKUP_DIR/nft-$ts.rules"      2>/dev/null
    msg_info "backup: $BACKUP_DIR/*-$ts.* — для ручного отката"
    BACKUP_DONE=1; export BACKUP_TS="$ts"
    record_fix "backup snapshot $ts"
}

# write_dropin <basename-без-99-node-diagnostic> — читает stdin, пишет namespaced sysctl.d + применяет.
# пример: write_dropin tuning <<'EOF' ...ключи... EOF
write_dropin() {
    local suffix="$1"
    local target="/etc/sysctl.d/${ND_DROPIN_PREFIX}-${suffix}.conf"
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "    ${DIM}[dry-run]${NC} записал бы $target:"
        sed 's/^/        /'
        return 0
    fi
    backup_settings
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    { echo "# Managed by node-diagnostic ($ND_VERSION). Откат: rm этот файл + sysctl --system"; cat; } > "$target"
    if sysctl --system >/dev/null 2>&1; then
        msg_ok "$target применён"
    elif sysctl -p "$target" >/dev/null 2>&1; then
        # busybox sysctl (Alpine) не знает --system — применяем хотя бы наш файл
        msg_ok "$target применён (sysctl -p)"
    else
        msg_warn "$target записан, но sysctl вернул ошибку (часть ключей может быть недоступна на этом ядре)"
    fi
    record_fix "sysctl dropin $target"
}

# модуль загружен (или встроен в ядро)?
module_loaded() { [ -d "/sys/module/$1" ] || lsmod 2>/dev/null | grep -qw "^$1"; }

# модуль вообще существует для этого ядра (built-in или .ko)?
module_available() { module_loaded "$1" || modinfo "$1" >/dev/null 2>&1; }

# load_module <name> — modprobe + персист в modules-load.d (идемпотентно, namespaced)
load_module() {
    local m="$1"
    if [ "$DRY_RUN" = "1" ]; then echo -e "    ${DIM}[dry-run]${NC} modprobe $m"; return 0; fi
    modprobe "$m" 2>/dev/null || true
    local f="/etc/modules-load.d/${ND_DROPIN_PREFIX}.conf"
    mkdir -p /etc/modules-load.d 2>/dev/null || true
    # редирект оборачиваем в {}: иначе его ошибка (нет каталога/ro-fs) летит на экран
    grep -qxF "$m" "$f" 2>/dev/null || { echo "$m" >> "$f"; } 2>/dev/null || true
}

# verify_sysctl <key> <expected> — сверить фактическое значение с ожидаемым (после применения)
verify_sysctl() {
    local key="$1" want="$2" got
    got=$(sysctl -n "$key" 2>/dev/null)
    # multi-value ключи (tcp_rmem) sysctl отдаёт с ТАБАМИ, drop-in пишем с пробелами —
    # echo в кавычках их не схлопывает; сравниваем по полям
    local -a g=() w=()
    read -ra g <<< "$got"
    read -ra w <<< "$want"
    [ "${g[*]}" = "${w[*]}" ]
}

# ────────────────────────────────────────────────────────────────────
# Детект окружения
# ────────────────────────────────────────────────────────────────────
detect_virt() { systemd-detect-virt 2>/dev/null || echo "unknown"; }

is_container() {
    systemd-detect-virt --container --quiet 2>/dev/null && return 0
    [ -f /.dockerenv ] && return 0          # Docker (без systemd и container= в environ)
    [ -f /run/.containerenv ] && return 0   # Podman
    [ -e /proc/vz ] && return 0
    [ -e /proc/user_beancounters ] && return 0
    grep -qa 'container=' /proc/1/environ 2>/dev/null && return 0
    grep -qaE ':/(docker|lxc|kubepods|containerd)' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

# можно ли сменить ядро (нужно своё ядро: bare-metal / KVM / Xen HVM, x86_64, не контейнер)
can_install_kernel() {
    [ "$(uname -m)" = "x86_64" ] || return 1
    is_container && return 1
    return 0
}

# уровень x86-64 psABI: печатает 1..4 по флагам /proc/cpuinfo (для выбора сборки XanMod)
cpu_psabi_level() {
    local f; f=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)
    has() { echo "$f" | grep -qw "$1"; }
    local lvl=1
    if has cx16 && has lahf_lm && has popcnt && has sse4_1 && has sse4_2 && has ssse3; then
        lvl=2
        if has avx && has avx2 && has bmi1 && has bmi2 && has f16c && has fma && has movbe && has xsave; then
            lvl=3
            if has avx512f && has avx512bw && has avx512cd && has avx512dq && has avx512vl; then
                lvl=4
            fi
        fi
    fi
    echo "$lvl"
}

# ────────────────────────────────────────────────────────────────────
# Сетевые детекторы
# ────────────────────────────────────────────────────────────────────
default_iface() { ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }

detect_ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [ -z "$p" ] && p=$(awk '/^[Pp]ort[ \t]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    echo "${p:-22}"
}

# IP, с которого пришёл текущий SSH-сеанс (для авто-whitelist в firewall)
ssh_client_ip() {
    if [ -n "${SSH_CLIENT:-}" ]; then
        echo "${SSH_CLIENT%% *}"; return 0
    fi
    if [ -n "${SSH_CONNECTION:-}" ]; then
        echo "$SSH_CONNECTION" | awk '{print $1}'; return 0
    fi
    who am i 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -1
}

os_codename() {
    ( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" )
}
os_id() {
    ( . /etc/os-release 2>/dev/null; echo "${ID:-unknown}" )
}

# apt-подобный дистрибутив?
is_debian_like() {
    case "$(os_id)" in
        debian|ubuntu|devuan|raspbian|pop|linuxmint) return 0 ;;
        *) have apt-get && return 0 || return 1 ;;
    esac
}
