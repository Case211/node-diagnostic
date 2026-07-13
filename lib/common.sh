#!/usr/bin/env bash
# lib/common.sh — общие примитивы для node-diagnostic (палитра, детекторы, backup, drop-in, dry-run).
# Только для source: `source "$(dirname "$0")/lib/common.sh"`. Напрямую не запускается.

# защита от двойного подключения
[ -n "${ND_COMMON_LOADED:-}" ] && return 0
ND_COMMON_LOADED=1

ND_VERSION="4.1.1"
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

# ────────────────────────────────────────────────────────────────────
# Базовые хелперы
# ────────────────────────────────────────────────────────────────────
have()      { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ]; }

msg_ok()   { echo -e "    ${G}✓${NC} $*"; }
msg_warn() { echo -e "    ${Y}⚠${NC} $*"; }
msg_err()  { echo -e "    ${R}✗${NC} $*"; }
msg_info() { echo -e "    ${DIM}$*${NC}"; }

die() { echo -e "${R}${BOLD}✗${NC} $*" >&2; exit 1; }

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
