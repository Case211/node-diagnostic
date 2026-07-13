# node-diagnostic

Модульный тулкит для VPN/Linux-ноды (заточен под стек **Remnawave**): диагностика, оптимизация сети, защита и установка ядра с BBRv3. Диагностика — компактный дашборд с прогресс-баром, сводкой и вердиктом; фиксы вынесены в отдельные модули с явным откатом.

```
  NODE DIAGNOSTIC  v4.0 · toolkit
  ─────────────────────────────────────────────────────

[ 1/23] ✓ Идентификация             host.example.com · Helsinki/FI · ~2ms→Tallinn
[ 2/23] ✓ CPU и нагрузка            2c · load 0.05 · idle 94%
[ 5/23] ⚠ Туннели                   1 активн.: NetBird:wt0 (MTU=1280)
[ 6/23] ✓ TCP congestion            bbr + cake
[ 7/23] ⚠ TCP tuning                mtu_probing=0
[10/23] ✗ PMTU                      1437 (вместо 1500)
[11/23] ✗ Loss до Google            max 18% loss
[14/23] ✗ Speed: 1-flow             21 Mbit/s
...
```

## Модули

| Команда | Что делает | Применяет? |
|---|---|---|
| `diagnose` | 24 чека: система, сеть, скорость, сервисы, репутация IP, Xray/Remnanode | — (только читает) |
| `optimize` | sysctl-тюнинг, BBR+cake, FD-лимиты, RPS/RFS/XPS, NIC offloads, MSS clamp | да (namespaced drop-in) |
| `protect`  | firewall под Remnawave, fail2ban, SSH-хардненинг, DDoS-хардненинг | **нет — только генерирует файлы** |
| `bbr3`     | ядро XanMod для TCP **BBRv3** (mainline даёт только v1) | да, но **без автоперезагрузки** |
| `rollback` | снять всё, что наложил `optimize` | да |

## Структура

```
node-diagnostic.sh          точка входа: меню + диспетчер команд
lib/common.sh               палитра, детекторы (virt/psABI/ssh), backup, namespaced drop-in, dry-run
modules/
  diagnose.sh               24 чека, дашборд, вердикт, рекомендации
  optimize.sh               сетевой/системный тюнинг
  protect.sh                защита ноды (генерация артефактов)
  bbr3.sh                   установка XanMod (BBRv3)
  rollback.sh               откат оптимизаций
```

## Установка

**Одной командой:**

```bash
curl -sSL https://raw.githubusercontent.com/Case211/node-diagnostic/main/install.sh | sudo bash
```

Скачивает репозиторий в `/opt/node-diagnostic`; в терминале сразу открывает меню. Переопределяемо через env: `ND_REF` (ветка/тег), `ND_DEST` (каталог).

**Или вручную** (тулкит модульный — нужен весь репозиторий):

```bash
git clone https://github.com/Case211/node-diagnostic
cd node-diagnostic
sudo bash node-diagnostic.sh        # интерактивное меню
```

Зависимости диагностики (`mtr`, `dig`, `ethtool`, `conntrack`, `jq` и т.д.) ставятся сами через apt/dnf/yum/apk.

## Использование

```bash
sudo bash node-diagnostic.sh                       # меню (диагностика, если ввод не TTY)
sudo bash node-diagnostic.sh diagnose -q           # быстрая диагностика ~1 мин
sudo bash node-diagnostic.sh diagnose --json       # машиночитаемый JSON (для агрегации по флоту)
sudo bash node-diagnostic.sh optimize --all        # весь тюнинг
sudo bash node-diagnostic.sh optimize --from-findings   # только фиксы по находкам диагностики
sudo bash node-diagnostic.sh optimize --dry-run    # показать, что применил бы
sudo bash node-diagnostic.sh protect --panel-ip 1.2.3.4 --node-port 2222
sudo bash node-diagnostic.sh bbr3 --install        # XanMod (нужен reboot); --level 2 если CPU маскирован
sudo bash node-diagnostic.sh rollback              # откат оптимизаций
sudo bash node-diagnostic.sh status                # что наложено на систему, ядро, cc/qdisc
```

Типовой поток: `diagnose` → он сохраняет находки → `optimize --from-findings` применяет только релевантное. Для флота: `diagnose --json` на каждой ноде, сводишь в одну картину.

Каждый модуль запускается и самостоятельно: `sudo bash modules/optimize.sh --sysctl`.

## Что проверяет `diagnose` (24 чека)

**Система** — CPU/память/load/softirq, NIC drops, ring buffers, ethtool offloads.
**Сеть** — TCP congestion + qdisc, буферы, conntrack, DNS, PMTU (бинпоиск с защитой от false-negative на лоссе), туннели (WireGuard/NetBird/Tailscale/OpenVPN/IPsec), loss/latency до Google и DNS, MTR с худшим хопом, UDP/QUIC/HTTP-3, IPv6.
**Производительность** — 1-flow (Cachefly), 4-flow, мульти-CDN (детект ASN-троттлинга), **bufferbloat** (ping под нагрузкой), variance.
**Сервисы** — reachability + TTFB для 19 популярных (YouTube/Netflix/Twitch/TikTok/Telegram/Discord/ChatGPT/Claude/Gemini/Spotify/…); различает 200 / блок (403/429) / unreachable.
**Репутация IP** — Cloudflare colo, гео-кросс-чек по 3 базам, реальная локация по latency до IX, Google CAPTCHA-проба, reverse DNS, «датацентр vs резидентский».
**Xray/Remnanode** — версия, ресурсы контейнера, ошибки в логах, рестарты.
**Открытые порты** — публичные листенеры (`ss`): docker-API (2375/2376), голые БД (postgres/mysql/redis/mongo/…) и нестандартные порты на `0.0.0.0`/`[::]` — частая дыра, через которую ломают ноду.

## `optimize` — что накладывает

Всё пишется в namespaced drop-in (`/etc/sysctl.d/99-node-diagnostic-*.conf`, `node-diagnostic-*.service`), поэтому откат детерминированный (`rollback`), а не восстановление дампа.

- **sysctl** — BBR + cake; **`tcp_min_snd_mss=512`** (пол MSS под `tcp_mtu_probing=1` — без него на лоссовом плече MSS схлопывается до 48б); буферы и conntrack **масштабируются по RAM** (16M→128M); SYN-flood + anti-spoof; TIME_WAIT/keepalive; UDP-буферы (Hysteria2/TUIC/QUIC); `ip_local_port_range`.
- **FD-лимиты** — `fs.file-max`/`nr_open` + `limits.d` + **systemd `DefaultLimitNOFILE`** (xray-сервис читает именно его) + pam.
- **RPS/RFS/XPS** — размазать softirq и flow-steering по всем CPU (systemd-юнит для постоянства).
- **NIC** — ring buffers max + `gro/gso/tso` + `txqueuelen 10000`.
- **MSS clamp** — iptables TCPMSS `--clamp-mss-to-pmtu` (FORWARD/OUTPUT), persist.

## `protect` — защита под Remnawave (только генерация)

Firewall на удалённой ноде может отрезать SSH, поэтому модуль **ничего не применяет** — пишет готовые артефакты в каталог и даёт пошаговый `APPLY.txt` с защитой от лок-аута (авто-откат правил через `systemd-run` таймер).

Генерируется:
- `firewall.nft` / `firewall-ufw.sh` — карта портов ноды: **443** (VLESS/Reality + QUIC/HY2) и **80** (ACME/Caddy) всем; **NODE_PORT** (control-API панель→нода) — только с IP панели; **SSH** — с твоего IP; ICMP не режется полностью (нужен для PMTU), только per-IP флуд; per-IP connlimit/SYN-rate; всё прочее — drop. `61000`/localhost и Caddy `:9443`/localhost наружу не открываются.
- `fail2ban-sshd.local` — джейл SSH с нарастающим баном.
- `sshd-hardening.conf` — key-only, `PermitRootLogin prohibit-password` и т.д. (модуль проверяет наличие `authorized_keys` и предупреждает о риске лок-аута).
- `sysctl` DDoS-хардненинг идёт через `optimize` (syncookies/anti-spoof).

```bash
sudo bash node-diagnostic.sh protect --panel-ip <IP_панели> --node-port <NODE_PORT>
# → /root/node-diagnostic-protect/  (открыть APPLY.txt)
```

Из меню то же самое без флагов: пункт **[3]** спросит IP панели и NODE_PORT (Enter — автодетект/плейсхолдер).

## `bbr3` — TCP BBRv3 через XanMod

Mainline-ядро отдаёт только BBRv1; BBRv3 приходит с кастомным ядром **XanMod**. Модуль:
- гейтит контейнеры (OpenVZ/LXC используют ядро хоста — своё не поставить) и не-x86_64;
- проверяет **отпечаток GPG-ключа** XanMod перед установкой;
- выбирает сборку по **psABI** (x64v1..v4) под реальный CPU (иначе ядро не загрузится);
- **не перезагружает сам**, делает проверки перед reboot (новое ядро в /boot, старое остаётся как откат, GRUB_TIMEOUT);
- детект «это именно v3»: `uname -r` содержит `xanmod` и ядро ≥6.4.

```bash
sudo bash node-diagnostic.sh bbr3 --status              # что сейчас
sudo bash node-diagnostic.sh bbr3 --install --dry-run   # план без установки
sudo bash node-diagnostic.sh bbr3 --install             # затем reboot вручную
```

## Откат

```bash
sudo bash node-diagnostic.sh rollback            # снять sysctl drop-in, systemd-юниты, limits, MSS clamp
sudo bash node-diagnostic.sh rollback --dry-run  # показать, что снял бы
```
Не входит: ядро XanMod (`apt purge 'linux-xanmod*' && update-grub && reboot`) и firewall/fail2ban/sshd (они generate-only — откат в их `APPLY.txt`).

## Артефакты

- `/tmp/node-diagnostic-<ts>.log` — полный лог диагностики
- `/tmp/node-diagnostic-summary-<ts>.txt` — плоская сводка без ANSI
- `/var/backups/node-diagnostic/*` — снапшоты sysctl/iptables/nft перед фиксом
- `/etc/node-diagnostic.applied` — журнал применённого

## Требования

- bash 4+, root для `optimize`/`protect`/`bbr3`/`rollback` (диагностика работает и без root, часть проверок пропускается).
- Поддержка дистрибутивов по модулям:
  - `diagnose`, `optimize`, `rollback` — Ubuntu/Debian/RHEL/Fedora/Alpine (sysctl универсален; deps ставятся через apt/dnf/yum/apk).
  - `protect` — firewall на nftables/ufw универсален; инструкции по fail2ban в `APPLY.txt` даны под apt (для dnf/apk — аналогично).
  - `bbr3` — **только Debian/Ubuntu** (XanMod = deb-репозиторий) и **только bare-metal/KVM x86_64** (не контейнер).

Диагностика тестировалась на Ubuntu 22.04, Debian 12, Alpine 3.18. CI гоняет shellcheck + smoke на Ubuntu/Debian.

## Лицензия

MIT.
