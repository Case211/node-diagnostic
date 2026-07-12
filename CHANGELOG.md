# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## [4.1.0] — не выпущено (ветка `feat/interactive-menu`)

Меню доведено до полностью интерактивного: флаги больше не нужны ни для одного пункта.

### Added
- **Меню → Диагностика**: выбор режима — полная (~5 мин) / быстрая `[q]` (~1 мин).
- **Меню → Защита**: визард спрашивает IP панели (с проверкой, что это IPv4) и NODE_PORT; Enter — плейсхолдер/автодетект как раньше.
- **Меню → BBRv3**: план (dry-run) и установка запускаются прямо из пункта (`[d]`/`[i]`), установка — со своим подтверждением y/N; в не-TTY по-прежнему печатаются команды.

### Fixed
- **diagnose**: тихая установка зависимостей (`ensure_deps`) наследовала TTY — debconf съедал клавиатурный ввод, и меню после диагностики зависало на «Enter — вернуться» (найдено TTY-тестом меню). Теперь пакетные менеджеры получают `</dev/null` + `DEBIAN_FRONTEND=noninteractive`.

## [4.0.1] — в `main` с 2026-07-12

Пакет фиксов по аудиту v4.0 после мержа в main.

### Fixed
- **protect**: явное предупреждение о лок-ауте при динамическом SSH-IP — на экране при генерации и в `APPLY.txt` (варианты: CIDR подсети провайдера / только rate-limit+fail2ban / проверка VNC-консоли).
- **версия**: `ND_VERSION`/`SCRIPT_VERSION` дублировались — теперь единый источник `lib/common.sh` (диспетчер передаёт через env, standalone diagnose вытягивает сам).
- **optimize**: RPS-юнит писал мусор в корень ФС (`/rps_cpus` и др.) и не восстанавливал RPS/RFS/XPS после ребута — systemd раскрывал `$q` в ExecStart (нужно `$$`).
- **protect**: connlimit на 443 был глобальным на порт (душил ноду при >2048 суммарных соединений), а не per-IP — теперь `meter { ip saddr ct count }`.
- **protect**: `detect_node_port` мог взять published-порт чужого контейнера и брал internal-часть маппинга вместо хостовой.
- **bbr3**: sysctl-конфликт с optimize — `…-tuning.conf` сортируется позже `…-bbr.conf` и перекрывал cc обратно (сценарий «поставил XanMod, а cc снова cubic»).
- **bbr3**: гейт контейнеров не видел Docker/Podman (`/.dockerenv`, `/run/.containerenv`, cgroup) — установка ядра предлагалась внутри контейнера.
- **bbr3**: dry-run и сообщение об отсутствии пакета игнорировали `--level`.
- **diagnose**: ложный «PMTU=28» (crit) когда ICMP не ходит вовсе — теперь skip с подсказкой.
- **diagnose**: спидтесты затирали вывод curl при exit 28 — ложные fail на каналах медленнее ~70 (1-flow) / ~160 (variance) Mbit/s; теперь считается реально скачанное.
- **diagnose**: отсутствие `nc` считалось блокировкой UDP/443.
- **diagnose**: `--no-net` всё равно ходил в интернет (идентификация: ipify/гео-базы/latency-пробы).
- **diagnose**: 403 анти-бот-фронтов (Claude, Reddit) считался блокировкой IP на любом IP.
- **diagnose**: спиннер лился кадрами в пайп/лог (не гейтился на TTY); `apt-get update` дёргался на каждом прогоне даже без недостающих пакетов.
- **common**: `verify_sysctl` не нормализовал табы — multi-value ключи вечно «не применились».
- **common/optimize**: ошибки редиректов (`> file 2>/dev/null`) летели на экран, persist модулей в `modules-load.d` молча терялся без каталога — после ребута слетали bbr/conntrack-ключи.
- **все точки входа**: запуск через pipe (`curl … | bash`) падал с «BASH_SOURCE[0]: unbound variable»; модули без common.sh продолжали работать вхолостую — теперь внятный отказ с подсказкой.
- **install**: обещанное меню после `curl | sudo bash` никогда не открывалось (stdin занят пайпом) — теперь через `/dev/tty`.
- **CI**: `nft -c` фактически не выполнялся (нет CAP_NET_ADMIN) — smoke под sudo/NET_ADMIN, фейл под root блокирующий.

## [4.0] — в `main` с 2026-07-11 (PR #1)

Переработка монолита в модульный тулкит + защита под Remnawave + BBRv3.

### Added
- Модульная структура: `node-diagnostic.sh` (меню + диспетчер команд) · `lib/common.sh` · `modules/{diagnose,optimize,protect,bbr3,rollback}.sh`.
- Интерактивное меню и подкоманды (`diagnose`/`optimize`/`protect`/`bbr3`/`rollback`) + флаги для CI/non-TTY.
- `optimize`: `tcp_min_snd_mss=512`, FD-лимиты (`fs.file-max` + systemd `DefaultLimitNOFILE` для xray + pam), SYN-flood/anti-spoof, TIME_WAIT/keepalive, UDP-буферы, буферы и conntrack масштабом по RAM, RPS/RFS/XPS, NIC offloads. Загрузка модулей (`tcp_bbr`/`nf_conntrack`/`sch_cake`) + verify-after-apply + выбор cc/qdisc по доступности. Флаг `--from-findings`.
- `protect`: генерация firewall (nftables/ufw — 443/80 всем, NODE_PORT только с IP панели, per-IP rate-limit), fail2ban, SSH-хардненинг + `APPLY.txt` с защитой от лок-аута. Режим только генерация.
- `bbr3`: установка ядра XanMod (BBRv3) — гейт контейнеров, проверка отпечатка GPG-ключа, psABI-детект, override `--level`, предупреждение о маскированном CPU, без автоперезагрузки.
- `rollback`: откат namespaced-артефактов.
- `diagnose --json` — машиночитаемый вывод для агрегации по флоту.
- `install.sh` — бутстрап `curl | bash`.
- CI (GitHub Actions): shellcheck + smoke на Ubuntu и Debian · `tests/smoke.sh`.

### Changed
- Движок 23 чеков вынесен в `modules/diagnose.sh`; sysctl теперь в namespaced drop-in (`/etc/sysctl.d/99-node-diagnostic-*.conf`), откат детерминированный.

### Fixed
- `tcp_mtu_probing=1` без `tcp_min_snd_mss` → коллапс send-MSS до 48б на лоссовом плече (перенято из node-accelerator).
- sysctl `bbr`/conntrack применялись вслепую — теперь грузятся модули и проверяется фактическое значение.

## [3.4] и ранее

Монолитный `node-diagnostic.sh`: 23 чека (система/сеть/скорость/сервисы/репутация IP/Xray) + inline-автофиксы (sysctl/MSS clamp/RPS/ring).