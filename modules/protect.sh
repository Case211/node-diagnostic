#!/usr/bin/env bash
# modules/protect.sh — защита ноды под стек Remnawave. РЕЖИМ: только генерация.
# Пишет готовые артефакты (nftables/ufw firewall, fail2ban, SSH-хардненинг) в каталог
# и печатает пошаговую инструкцию по применению. САМ НИЧЕГО НЕ ПРИМЕНЯЕТ — фаервол на
# удалённой ноде может отрезать SSH, поэтому применяешь руками, сверив IP панели/SSH.
#
# Standalone:  sudo bash modules/protect.sh [--panel-ip X.X.X.X] [--node-port N] [--out DIR]
# Как модуль:  source lib/common.sh; source modules/protect.sh; protect_generate

if [ -z "${ND_COMMON_LOADED:-}" ]; then
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../lib/common.sh
    source "$_self/../lib/common.sh"
fi

# ── детект параметров Remnawave-ноды ────────────────────────────────
detect_node_port() {
    local f v
    for f in /opt/remnanode/.env /root/remnanode/.env /opt/remnawave/node/.env ./.env; do
        [ -r "$f" ] || continue
        v=$(awk -F= '/^[[:space:]]*NODE_PORT[[:space:]]*=/{gsub(/[" ]/,"",$2);print $2;exit}' "$f")
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    # из запущенного контейнера remnanode
    if have docker; then
        v=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '0.0.0.0:[0-9]+->[0-9]+' | head -1 | grep -oE '->[0-9]+' | tr -d '->')
        [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    return 1
}

PROTECT_OUT="${PROTECT_OUT:-}"
PANEL_IP="${PANEL_IP:-}"
NODE_PORT="${NODE_PORT:-}"

# per-IP лимиты в nft (из практики node-accelerator)
CONN_LIMIT="${CONN_LIMIT:-2048}"
SYN_RATE="${SYN_RATE:-200}"
UDP_RATE="${UDP_RATE:-200}"
ICMP_RATE="${ICMP_RATE:-10}"
SSH_RATE="${SSH_RATE:-6}"     # соединений/мин на IP

protect_generate() {
    local ssh_port ssh_ip out
    ssh_port=$(detect_ssh_port)
    ssh_ip=$(ssh_client_ip)
    [ -z "$NODE_PORT" ] && NODE_PORT=$(detect_node_port || echo "")
    if need_root; then out="${PROTECT_OUT:-/root/node-diagnostic-protect}"; else out="${PROTECT_OUT:-$PWD/node-diagnostic-protect}"; fi
    mkdir -p "$out" || die "не создал каталог $out"

    local ph_panel="$PANEL_IP" ph_ssh="$ssh_ip"
    [ -z "$ph_panel" ] && ph_panel="<PANEL_IP>"
    [ -z "$ph_ssh" ]   && ph_ssh="<YOUR_SSH_IP>"

    echo
    echo -e "  ${BOLD}Генерация защиты ноды (Remnawave)${NC}"
    echo -e "    ${DIM}SSH-порт:${NC} $ssh_port   ${DIM}твой SSH-IP:${NC} $ph_ssh"
    echo -e "    ${DIM}NODE_PORT (control-API):${NC} ${NODE_PORT:-<не найден, укажи --node-port>}"
    echo -e "    ${DIM}IP панели:${NC} $ph_panel"
    echo -e "    ${DIM}каталог:${NC} $out"
    echo
    [ "$ph_panel" = "<PANEL_IP>" ] && msg_warn "IP панели не задан — в правилах плейсхолдер <PANEL_IP>, подставь перед применением (--panel-ip)"
    [ -z "$NODE_PORT" ] && msg_warn "NODE_PORT не найден — плейсхолдер <NODE_PORT>, подставь (--node-port)"
    [ "$ph_ssh" = "<YOUR_SSH_IP>" ] && msg_warn "SSH-IP не определён (не по SSH?) — подставь свой IP вручную"

    _gen_nft   "$out" "$ssh_port" "$ph_ssh" "$ph_panel" "${NODE_PORT:-<NODE_PORT>}"
    _gen_ufw   "$out" "$ssh_port" "$ph_ssh" "$ph_panel" "${NODE_PORT:-<NODE_PORT>}"
    _gen_fail2ban "$out" "$ssh_port"
    _gen_sshd  "$out"
    _gen_apply "$out" "$ssh_port" "$ph_ssh"

    echo
    echo -e "  ${G}${BOLD}✓ Сгенерировано в $out${NC}"
    ls -1 "$out" | sed 's/^/      /'
    echo
    echo -e "  ${Y}${BOLD}Ничего не применено.${NC} ${DIM}Открой ${BOLD}$out/APPLY.txt${NC}${DIM} — там пошагово, с защитой от лок-аута.${NC}"
    record_fix "protect artifacts generated -> $out"
}

_gen_nft() {
    local out=$1 ssh_port=$2 ssh_ip=$3 panel=$4 node_port=$5
    cat > "$out/firewall.nft" <<EOF
#!/usr/sbin/nft -f
# node-diagnostic: firewall для Remnawave-ноды. Своя таблица, ruleset не флашится (уживается с Docker).
# Применить:  sudo nft -f $out/firewall.nft
# Порты: 443 (VLESS/Reality + QUIC/HY2), 80 (ACME/Caddy), NODE_PORT (control-API) — только с IP панели.

table inet node_protect
delete table inet node_protect
table inet node_protect {
    set panel_ip {
        type ipv4_addr
        elements = { $panel }
    }
    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # ICMP нужен для PMTU — не резать полностью, только флуд (per-IP)
        ip  protocol icmp   meter icmp4 { ip  saddr limit rate over ${ICMP_RATE}/second } drop
        ip6 nexthdr icmpv6  meter icmp6 { ip6 saddr limit rate over ${ICMP_RATE}/second } drop
        ip  protocol icmp   accept
        ip6 nexthdr icmpv6  accept

        # SSH — только с твоего IP + анти-брут по скорости соединений
        tcp dport $ssh_port ip saddr $ssh_ip ct state new \\
            meter ssh_rate { ip saddr limit rate over ${SSH_RATE}/minute } drop
        tcp dport $ssh_port ip saddr $ssh_ip accept

        # 443 — публичный вход. Per-IP лимит одновременных соединений и SYN-rate.
        tcp dport 443 ct count over $CONN_LIMIT drop
        tcp dport 443 ct state new \\
            meter syn443 { ip saddr limit rate over ${SYN_RATE}/second burst $((SYN_RATE*2)) packets } drop
        tcp dport 443 accept
        udp dport 443 \\
            meter udp443 { ip saddr limit rate over ${UDP_RATE}/second } drop
        udp dport 443 accept

        # 80 — ACME HTTP-01 / редирект (Caddy держит сам)
        tcp dport 80 accept

        # NODE_PORT — канал панель->нода, ТОЛЬКО с IP панели
        tcp dport $node_port ip saddr @panel_ip accept

        # остальное — в лог и drop
        limit rate 5/minute log prefix "node_protect drop: " level info
        counter drop
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
}

_gen_ufw() {
    local out=$1 ssh_port=$2 ssh_ip=$3 panel=$4 node_port=$5
    cat > "$out/firewall-ufw.sh" <<EOF
#!/usr/bin/env bash
# node-diagnostic: firewall через ufw (проще nft, но без per-IP rate-limit).
# Применить:  sudo bash $out/firewall-ufw.sh
set -e
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from $ssh_ip to any port $ssh_port proto tcp comment 'SSH (твой IP)'
ufw allow 443 comment 'VLESS/Reality + QUIC/HY2'
ufw allow 80/tcp comment 'ACME/Caddy'
ufw allow from $panel to any port $node_port proto tcp comment 'Remnawave control-API (панель)'
ufw limit $ssh_port/tcp comment 'анти-брут SSH'
ufw --force enable
ufw status verbose
EOF
    chmod +x "$out/firewall-ufw.sh" 2>/dev/null || true
}

_gen_fail2ban() {
    local out=$1 ssh_port=$2
    cat > "$out/fail2ban-sshd.local" <<EOF
# node-diagnostic: fail2ban jail для SSH.
# Скопировать:  sudo cp $out/fail2ban-sshd.local /etc/fail2ban/jail.d/sshd.local && sudo systemctl restart fail2ban
[sshd]
enabled  = true
port     = $ssh_port
backend  = systemd
maxretry = 4
findtime = 10m
bantime  = 1h
# рецидив — дольше бан
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
EOF
}

_gen_sshd() {
    local out=$1 has_key="нет"
    # проверим, есть ли вообще ключи (иначе key-only лок-аут)
    if grep -rqsE 'ssh-(rsa|ed25519|ecdsa)' /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null; then
        has_key="да"
    fi
    cat > "$out/sshd-hardening.conf" <<EOF
# node-diagnostic: SSH-хардненинг (drop-in). Обнаружены authorized_keys: $has_key
# ОПАСНО: без рабочего ключа PasswordAuthentication no = лок-аут. Проверь вход по ключу ПЕРЕД применением!
# Скопировать: sudo cp $out/sshd-hardening.conf /etc/ssh/sshd_config.d/99-node-diagnostic.conf
#   sudo sshd -t && sudo systemctl reload ssh   # sshd -t обязателен, чтобы не убить демон опечаткой
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    [ "$has_key" = "нет" ] && msg_warn "authorized_keys не найдены — НЕ применяй sshd-hardening.conf, иначе лок-аут"
}

_gen_apply() {
    local out=$1 ssh_port=$2 ssh_ip=$3
    cat > "$out/APPLY.txt" <<EOF
================  node-diagnostic · применение защиты  ================
Всё сгенерировано, НО НЕ ПРИМЕНЕНО. Порядок безопасного наката на удалённой ноде.

ПЕРЕД ВСЕМ: убедись, что в правилах подставлены реальные значения —
  IP панели вместо <PANEL_IP>, NODE_PORT вместо <NODE_PORT>, твой SSH-IP вместо <YOUR_SSH_IP>.
  Файлы: firewall.nft / firewall-ufw.sh.

--- 1. FIREWALL (самое опасное — можно отрезать SSH) ---
Способ А (nftables, с per-IP rate-limit — рекомендуется):
  # СТРАХОВКА от лок-аута: авто-откат через 300с, если не подтвердишь
  sudo systemd-run --on-active=300 --unit=fw-rollback nft delete table inet node_protect
  sudo nft -f $out/firewall.nft
  # проверь, что SSH-сессия жива и открывается НОВАЯ сессия во втором окне.
  # если ок — отменяем откат:
  sudo systemctl stop fw-rollback.timer 2>/dev/null; sudo systemctl reset-failed fw-rollback 2>/dev/null
  # сделать постоянным:
  sudo nft list ruleset > /etc/nftables.conf && sudo systemctl enable nftables

Способ Б (ufw, проще):
  sudo bash $out/firewall-ufw.sh
  # держи ВТОРУЮ SSH-сессию открытой на время применения.

--- 2. fail2ban ---
  sudo apt install -y fail2ban        # Debian/Ubuntu · dnf install fail2ban (RHEL/Fedora) · apk add fail2ban (Alpine)
  sudo cp $out/fail2ban-sshd.local /etc/fail2ban/jail.d/sshd.local
  sudo systemctl enable --now fail2ban && sudo fail2ban-client status sshd

--- 3. SSH-хардненинг (только если вход по КЛЮЧУ уже работает!) ---
  # проверь из второго окна: ssh -i ключ user@нода  — заходит без пароля?
  sudo cp $out/sshd-hardening.conf /etc/ssh/sshd_config.d/99-node-diagnostic.conf
  sudo sshd -t && sudo systemctl reload ssh
  # НЕ закрывай текущую сессию, пока не проверил новый вход.

--- ОТКАТ ---
  firewall nft:  sudo nft delete table inet node_protect
  firewall ufw:  sudo ufw disable
  fail2ban:      sudo rm /etc/fail2ban/jail.d/sshd.local && sudo systemctl restart fail2ban
  sshd:          sudo rm /etc/ssh/sshd_config.d/99-node-diagnostic.conf && sudo systemctl reload ssh

Карта портов Remnawave-ноды: 443 (вход), 80 (ACME), NODE_PORT (панель->нода, только IP панели),
61000/localhost и Caddy :9443/localhost наружу НЕ открываются.
======================================================================
EOF
}

protect_main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --panel-ip)  PANEL_IP="$2"; shift ;;
            --node-port) NODE_PORT="$2"; shift ;;
            --out)       PROTECT_OUT="$2"; shift ;;
            *) die "protect: неизвестный аргумент $1" ;;
        esac
        shift
    done
    protect_generate
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    protect_main "$@"
fi
