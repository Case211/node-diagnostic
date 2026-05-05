# node-diagnostic

Диагностика VPN/Linux-ноды для YouTube, видео-CDN и популярных сервисов одной командой. Прогресс-бар, сводка, вердикт и автоприменение исправлений — всё в одном bash-скрипте, без зависимостей кроме базовых утилит.

```
╔═════════════════════════════════════════════════════════════════════╗
║   Node Diagnostic v3.3 · 2026-05-06 18:42 UTC                       ║
╚═════════════════════════════════════════════════════════════════════╝

[ 1/23] ✓ Идентификация             host.example.com · Helsinki/FI · ~2ms→Tallinn
[ 2/23] ✓ CPU и нагрузка            2c · load 0.05 · idle 94%
[ 3/23] ✓ Память                    55% доступно
[ 4/23] ✓ NIC / интерфейс           ens3 · mtu 1500 · drops 0/0
[ 5/23] ⚠ Туннели                   1 активн.: NetBird:wt0 (MTU=1280)
[ 6/23] ✓ TCP congestion            bbr + cake
[ 7/23] ⚠ TCP tuning                mtu_probing=0
[ 8/23] ✓ Conntrack                 4006 / 524288 (0%)
[ 9/23] ⚠ DNS-резолв                3/5 fail (Netbird DNS таймаутит)
[10/23] ✗ PMTU                      1437 (вместо 1500)
[11/23] ✗ Loss до Google            max 18% loss
[12/23] ✗ Маршрут (mtr)             10h · loss 53% на 62.115.137.119/53.0%
[13/23] ⚠ QUIC / HTTP-3             udp=on http3=off
[14/23] ✗ Speed: 1-flow             21 Mbit/s
...
```

## Что проверяет (23 чека)

**Система** — CPU/память/load/softirq, NIC drops, ring buffers, ethtool offloads.

**Сеть** — TCP congestion control + qdisc, буферы, conntrack, DNS-резолв, PMTU (бинарным поиском с защитой от false-negative на сетях с потерями), туннели (WireGuard/NetBird/Tailscale/OpenVPN/IPsec), packet loss и latency до Google и публичных DNS, MTR с детектом худшего хопа, UDP/QUIC/HTTP-3, IPv6.

**Производительность** — скорость в один поток (Cachefly), 4 параллельных потока, мульти-CDN тест (Cloudflare/Cachefly/Hetzner/OVH/Linode) для детекта ASN-троттлинга, **bufferbloat** (ping под нагрузкой — главная причина «дёрганых» шортсов), sustained variance.

**Сервисы** — reachability + TTFB для 19 популярных: YouTube, Netflix, Twitch, TikTok, Telegram, Discord, WhatsApp, Signal, ChatGPT, Claude, Gemini, Spotify, Steam, GitHub и др. Различает 200/блок (403/429)/unreachable.

**Репутация IP** — Cloudflare colo, гео-кросс-чек по 3 базам (ipinfo.io, ip-api.com, ipwho.is), реальная локация по latency до национальных IX, Google CAPTCHA-проба, reverse DNS, эвристика «датацентр vs резидентский».

**Xray/Remnanode** — версия, ресурсы контейнера, ошибки в логах, число рестартов.

## Установка и запуск

```bash
# Просто запустить
curl -sSL https://raw.githubusercontent.com/Case211/node-diagnostic/main/node-diagnostic.sh | sudo bash

# Или скачать и запустить
wget https://raw.githubusercontent.com/Case211/node-diagnostic/main/node-diagnostic.sh
sudo bash node-diagnostic.sh
```

Зависимости (`mpstat`, `mtr`, `dig`, `ethtool`, `conntrack`, `jq` и т.д.) скрипт ставит сам через apt/dnf/yum/apk.

## Опции

```
sudo bash node-diagnostic.sh           # полный прогон ~5 мин
sudo bash node-diagnostic.sh -q        # быстрый прогон ~1 мин (без mtr/4-flow/multi-CDN/services/variance/bufferbloat)
sudo bash node-diagnostic.sh -a        # применить ВСЕ рекомендованные фиксы без вопросов
sudo bash node-diagnostic.sh -n        # вообще не предлагать фиксы
sudo bash node-diagnostic.sh --dry-run # показать что было бы применено, но не делать
sudo bash node-diagnostic.sh --no-net  # только локальная конфигурация (без сетевых тестов)
sudo bash node-diagnostic.sh -v        # детальный режим (всё на экран, как раньше)
sudo bash node-diagnostic.sh --version
sudo bash node-diagnostic.sh -h        # справка
```

## Что умеет автоматически чинить

После прогона показывается список релевантных фиксов (только тех, что реально помогут конкретно этой ноде):

- **sysctl tuning** — BBR + cake qdisc + 64MB буферы + tcp_mtu_probing=1 + tcp_slow_start_after_idle=0 + tcp_notsent_lowat + conntrack 524288. Файл `/etc/sysctl.d/99-vpn-tuning.conf`.
- **MSS clamping** — iptables TCPMSS clamp в FORWARD/OUTPUT для туннельных интерфейсов с PMTU<1500. Persist через `netfilter-persistent` или `/etc/iptables/rules.v4`.
- **RPS на NIC** — балансировка softirq по всем CPU. Создаёт systemd unit `node-diagnostic-rps.service`.
- **Ring buffers up** — `ethtool -G $iface rx max tx max`. Systemd unit для постоянства.

Перед применением — автобэкап (`sysctl -a` и `iptables-save`) в `/var/backups/node-diagnostic/`. История применённых фиксов — в `/etc/node-diagnostic.applied`. В финале выводится команда отката.

## Артефакты прогона

- `/tmp/node-diagnostic-<ts>.log` — полный детальный лог
- `/tmp/node-diagnostic-summary-<ts>.txt` — компактная плоская сводка (без ANSI-цветов, удобно слать)
- `/var/backups/node-diagnostic/sysctl-<ts>.txt` — снепшот настроек до фикса
- `/var/backups/node-diagnostic/iptables-<ts>.rules` — снепшот iptables до фикса

## Типичный сценарий

```bash
# 1. Полный диагноз
sudo bash node-diagnostic.sh

# 2. Применяешь рекомендованные фиксы (или -a сразу всё)

# 3. Быстро перепроверить, что починилось
sudo bash node-diagnostic.sh -q
```

## Сравнение нод

Запусти на двух нодах, сравни сводки:

```bash
# Helsinki, NODE HOST AS198550 — медленный
[10/23] ✗ Loss до Google     max 18% loss
[11/23] ✗ Маршрут            10h · loss 53% на 62.115.137.119/53.0%
[14/23] ✗ Speed: 1-flow      21 Mbit/s

# Helsinki, OC NETWORKS AS209693 — рабочий
[10/23] ✓ Loss до Google     max 0% loss
[11/23] ✓ Маршрут            8h · loss 0%
[14/23] ✓ Speed: 1-flow      800 Mbit/s
```

В таком случае sysctl-настройки не помогут — проблема в пиринге провайдера. Скрипт это видит и в сводке отдельно предупреждает.

## Системные требования

- Linux (Ubuntu/Debian/RHEL/Fedora/Alpine)
- bash 4+
- root для применения фиксов (диагностика без root тоже работает, но часть проверок пропускается)

Тестировалось на Ubuntu 22.04, Debian 12, Alpine 3.18.

## Лицензия

MIT.
