#!/usr/bin/env bash
# modules/install.sh — установка компонентов ноды Remnawave.
# Сабкоманды: node | selfsteal | netbird | monitoring.
# Вызывается через node-diagnostic.sh (пункт меню «Установка Remnanode»).
# Внешние установщики запускаются ТОЛЬКО после явного подтверждения.
set -u
_self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_self/../lib/common.sh" 2>/dev/null || { echo "install: не найден lib/common.sh" >&2; exit 1; }

# ── источники (обнови здесь при смене репо/версий) ────────────────────
REMNANODE_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
SELFSTEAL_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"
NETBIRD_INSTALL_URL="https://pkgs.netbird.io/install.sh"
# Мониторинг — версии по гайду https://wiki.egam.es/ru/configuration/grafana-monitoring-setup/
CADVISOR_VER="0.53.0"
NODE_EXPORTER_VER="1.9.1"
VMUTILS_VER="1.123.0"

_need_tty() { [ -t 0 ] || die "нужен интерактивный терминал — установщики спрашивают ввод"; }

_is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}

_show_cmd() { echo -e "    ${DIM}будет выполнено:${NC}\n    ${C}$1${NC}"; }

_need_curl() { have curl || ensure_pkg curl curl curl curl || die "нужен curl (не удалось поставить)"; }

# ── 1. Нода Remnawave (DigneZzZ/remnawave-scripts) ───────────────────
inst_node() {
    ui_head "Установка ноды Remnawave" "репозиторий DigneZzZ/remnawave-scripts"
    _show_cmd "bash <(curl -Ls $REMNANODE_URL) @ install"
    msg_info "это интерактивный установщик из стороннего репозитория — он задаст свои вопросы"
    confirm "Скачать и запустить установщик ноды?" || { msg_info "отменено"; return 1; }
    _need_curl
    bash <(curl -Ls "$REMNANODE_URL") @ install
}

# ── 2. Selfsteal ─────────────────────────────────────────────────────
inst_selfsteal() {
    ui_head "Установка Selfsteal" "репозиторий DigneZzZ/remnawave-scripts"
    _show_cmd "bash <(curl -Ls $SELFSTEAL_URL) @ install"
    msg_info "интерактивный установщик из стороннего репозитория"
    confirm "Скачать и запустить установщик Selfsteal?" || { msg_info "отменено"; return 1; }
    _need_curl
    bash <(curl -Ls "$SELFSTEAL_URL") @ install
}

# ── 3. NetBird + подключение по setup-key ────────────────────────────
inst_netbird() {
    ui_head "Установка NetBird" "агент оверлей-сети + подключение по setup-key"
    local key
    printf "  ${BOLD}Setup-key NetBird${NC}: "; read -r key
    [ -n "$key" ] || { msg_err "ключ пустой — отмена"; return 1; }
    _show_cmd "curl -fsSL $NETBIRD_INSTALL_URL | sh   &&   netbird up --setup-key ***"
    confirm "Установить NetBird и подключиться этим ключом?" || { msg_info "отменено"; return 1; }
    _need_curl
    curl -fsSL "$NETBIRD_INSTALL_URL" | sh || die "установщик NetBird завершился с ошибкой"
    have netbird || die "netbird не появился после установки"
    netbird up --setup-key "$key" || die "netbird up не удался (проверь ключ/сеть)"
    msg_ok "NetBird подключён — проверь: netbird status"
}

# ── 4. Мониторинг ноды (cAdvisor + node_exporter + vmagent) ──────────
# Точно по гайду wiki.egam.es: всё слушает 127.0.0.1, vmagent шлёт remoteWrite
# на центральный VictoriaMetrics по адресу NetBird.
inst_monitoring() {
    ui_head "Мониторинг ноды" "cAdvisor + node_exporter + vmagent → VictoriaMetrics"
    need_root || die "нужен root"
    [ "$(uname -m)" = "x86_64" ] || die "гайд рассчитан на amd64 (uname -m=$(uname -m))"
    have systemctl || die "нужен systemd (юниты cadvisor/nodeexporter/vmagent)"

    local inst ip def_inst
    def_inst="$(hostname)"
    printf "  ${BOLD}Имя инстанса (ноды)${NC} ${DIM}[Enter — %s]${NC}: " "$def_inst"; read -r inst
    inst="${inst:-$def_inst}"
    while true; do
        printf "  ${BOLD}IP сервера мониторинга (NetBird)${NC} ${DIM}напр. 10.0.0.5${NC}: "; read -r ip
        _is_ipv4 "$ip" && break
        msg_warn "это не IPv4-адрес"
    done
    echo
    msg_info "инстанс: $inst · vmagent remoteWrite → http://$ip:8428/api/v1/write"
    confirm "Установить и запустить мониторинг?" || { msg_info "отменено"; return 1; }

    _need_curl
    ensure_pkg tar tar tar tar >/dev/null 2>&1 || true
    have tar || die "нужен tar"

    # 1/4 — компоненты
    ui_head "1/4 загрузка компонентов" "cadvisor $CADVISOR_VER · node_exporter $NODE_EXPORTER_VER · vmutils $VMUTILS_VER"
    mkdir -p /opt/monitoring/cadvisor /opt/monitoring/nodeexporter /opt/monitoring/vmagent/conf.d

    curl -fL --retry 3 -o /opt/monitoring/cadvisor/cadvisor \
        "https://github.com/google/cadvisor/releases/download/v${CADVISOR_VER}/cadvisor-v${CADVISOR_VER}-linux-amd64" \
        && chmod +x /opt/monitoring/cadvisor/cadvisor && msg_ok "cAdvisor" || die "cAdvisor не скачался"

    local ne_tgz="/tmp/nd-node_exporter.tar.gz"
    curl -fL --retry 3 -o "$ne_tgz" \
        "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/node_exporter-${NODE_EXPORTER_VER}.linux-amd64.tar.gz" \
        || die "node_exporter не скачался"
    tar -xf "$ne_tgz" -C /tmp
    mv "/tmp/node_exporter-${NODE_EXPORTER_VER}.linux-amd64/node_exporter" /opt/monitoring/nodeexporter/node_exporter
    chmod +x /opt/monitoring/nodeexporter/node_exporter
    rm -rf "$ne_tgz" "/tmp/node_exporter-${NODE_EXPORTER_VER}.linux-amd64"
    msg_ok "node_exporter"

    local vm_tgz="/tmp/nd-vmutils.tar.gz"
    curl -fL --retry 3 -o "$vm_tgz" \
        "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMUTILS_VER}/vmutils-linux-amd64-v${VMUTILS_VER}.tar.gz" \
        || die "vmutils не скачался"
    tar -xf "$vm_tgz" -C /opt/monitoring/vmagent
    mv /opt/monitoring/vmagent/vmagent-prod /opt/monitoring/vmagent/vmagent
    # прочие бинари из vmutils не нужны — оставляем только vmagent (conf.d не трогаем)
    find /opt/monitoring/vmagent -maxdepth 1 -type f ! -name vmagent -delete
    chmod +x /opt/monitoring/vmagent/vmagent
    rm -f "$vm_tgz"
    msg_ok "vmagent"

    # 2/4 — конфиги vmagent
    ui_head "2/4 конфигурация vmagent" ""
    cat > /opt/monitoring/vmagent/scrape.yml <<'EOF'
scrape_config_files:
  - "/opt/monitoring/vmagent/conf.d/*.yml"

global:
  scrape_interval: 15s
EOF
    cat > /opt/monitoring/vmagent/conf.d/cadvisor.yml <<EOF
- job_name: integrations/cAdvisor
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9101']
      labels:
        instance: "$inst"
EOF
    cat > /opt/monitoring/vmagent/conf.d/nodeexporter.yml <<EOF
- job_name: integrations/node_exporter
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9100']
      labels:
        instance: "$inst"
EOF
    msg_ok "scrape.yml + conf.d/{cadvisor,nodeexporter}.yml"

    # 3/4 — systemd-юниты
    ui_head "3/4 systemd-юниты" ""
    cat > /etc/systemd/system/cadvisor.service <<'EOF'
[Unit]
Description=cAdvisor
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/cadvisor/cadvisor \
        -listen_ip=127.0.0.1 \
        -logtostderr \
        -port=9101 \
        -docker_only=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/nodeexporter.service <<'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/nodeexporter/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/vmagent.service <<EOF
[Unit]
Description=VictoriaMetrics Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/vmagent/vmagent \\
      -httpListenAddr=127.0.0.1:8429 \\
      -promscrape.config=/opt/monitoring/vmagent/scrape.yml \\
      -promscrape.configCheckInterval=60s \\
      -remoteWrite.url=http://$ip:8428/api/v1/write
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    msg_ok "cadvisor.service + nodeexporter.service + vmagent.service"

    # 4/4 — запуск
    ui_head "4/4 запуск и автозагрузка" ""
    systemctl daemon-reload
    systemctl enable cadvisor nodeexporter vmagent >/dev/null 2>&1 || true
    systemctl restart cadvisor nodeexporter vmagent
    local svc
    for svc in cadvisor nodeexporter vmagent; do
        if systemctl is-active --quiet "$svc"; then
            msg_ok "$svc активен"
        else
            msg_err "$svc НЕ активен — смотри: journalctl -u $svc -n 30"
        fi
    done
    echo
    msg_info "метрики слушают локально (127.0.0.1:9101/9100/8429); центральный VM собирает их по NetBird ($ip)"
}

case "${1:-}" in
    node)       _need_tty; inst_node ;;
    selfsteal)  _need_tty; inst_selfsteal ;;
    netbird)    _need_tty; inst_netbird ;;
    monitoring) _need_tty; inst_monitoring ;;
    ""|help|-h|--help)
        echo "install: sudo bash node-diagnostic.sh install {node|selfsteal|netbird|monitoring}"
        ;;
    *) echo "install: неизвестная сабкоманда '$1' (node|selfsteal|netbird|monitoring)" >&2; exit 2 ;;
esac
