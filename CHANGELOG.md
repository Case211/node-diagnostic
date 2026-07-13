# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## [4.2.0] — не выпущено (ветка `dev`)

Всё, что тулкит устанавливает, ставится проверенно и без сюрпризов. XanMod-путь впервые прогнан живьём до конца (ключ → репо → пакет ядра → prereboot-чеки) на Ubuntu 24.04 и Debian 12.

### Fixed
- **bbr3**: XanMod дропает репозитории старых релизов (`jammy`/`focal` → 404) — раньше скрипт успевал поставить ключ и источник, ломал `apt update` юзеру и падал с невнятным warn. Теперь пре-чек suite ДО любых изменений: на Ubuntu 22.04 — внятный отказ («система не тронута»), с живыми альтернативами.
- **bbr3**: при психе `apt update` после добавления репо источник и ключ убираются автоматически (apt юзера восстанавливается).
- **bbr3**: подбор пакета перепрыгивал v3 — CPU уровня v4 получал v2-ядро, хотя v3 в репо есть (v4 XanMod не публикует). Деградация теперь ступенчатая v4→v3→v2→v1; на реальном CPU v4 выбирается `linux-xanmod-lts-x64v3`.
- **diagnose/ensure_deps**: dpkg-лок-таймаут 60с (unattended-upgrades на Ubuntu держит лок — установка молча отваливалась); честный отчёт «не удалось поставить: …» в дашборд; список устанавливаемого — в лог; `iproute2/iproute` добавлен в карту (минимальные RHEL-образы без `ip` — NIC/туннели были слепые). dnf-путь впервые проверен живьём (Rocky 9: все 10 утилит ставятся), apk — тоже.
- **diagnose/CPU**: колонка softirq в mpstat искалась по фиксированному номеру `$9` — это `%steal`, не `%soft`: детект «softirq — настрой RPS» годами читал не ту метрику. Колонки теперь ищутся по имени из заголовка (sysstat с/без `%gnice`, busybox).
- **optimize/MSS clamp**: `iptables-persistent` на apt-дистро ставится автоматически (тихо, noninteractive) — раньше правила не переживали reboot, а скрипт лишь советовал доустановить руками.

## [4.1.1] — в `main` с 2026-07-13

Второй аудит — косяки, найденные живыми прогонами на Alpine (busybox) и non-root Debian.

### Fixed
- **diagnose/variance**: расчёт разброса шёл через `bc` с тернарником `?:`, которого у bc нет (ни GNU, ни busybox) — строка всегда падала, `ratio` был пустой («(x)» в сводке), а пороги троттлинга x2/x3 не срабатывали. Детект троттлинга по разбросу был мёртв. Переведено на целочисленный bash.
- **diagnose/4-flow**: под non-root/минимальной системой без `bc` результат был пустым — дашборд показывал «Speed: 4-flow  Mbit/s» без числа и печатал «integer expression expected». Считается нативным bash.
- **optimize/RPS**: битмаска CPU обнулялась при 64+ ядрах (переполнение `1<<n`) и давала невалидный формат при 33–63 — RPS/RFS/XPS не применялся. Хелпер `cpu_mask` генерит корректный многословный формат (`ffffffff,ffffffff`).
- **protect/ufw**: правило `ufw limit <ssh>/tcp` («анти-брут») — это ALLOW отовсюду с рейт-лимитом: оно открывало SSH всему интернету и обесценивало ограничение по IP. Удалено (анти-брут — fail2ban), в скрипте предупреждение.
- **protect**: подсказка для remnanode в docker-bridge (NODE_PORT-фильтр в input не видит DNAT-трафик — готовое правило для forward закомментировано в firewall.nft + пометка в APPLY.txt); IPv6-адрес SSH/панели больше не уезжает в IPv4-шаблон (плейсхолдер + предупреждение); детект authorized_keys видит `ecdsa-sha2-*` и `sk-*` ключи; комментарий для fail2ban без systemd (Alpine).
- **diagnose**: полностью выпилен `bc` (identify/CPU/bufferbloat/retrans/variance/4-flow) — на системах без bc пороги молча не работали; убран из автоустановки. Совместимость с busybox: MTU без `grep -P` (на Alpine был «слеп»), «ping без `-M do`» отличается от «ICMP порезан», fallback MemFree для ядер без MemAvailable, `export LANG`.
- **diagnose/bufferbloat**: объём под нагрузкой меряется по файлу (`stat`), а не `-w %{size_download}` — kill по дедлайну терял вывод, и на каналах медленнее ~115 Mbit/s тест всегда фейлился «0 bytes».
- **diagnose/services**: один повторный запрос при коде 000 — разовый сетевой чих больше не даёт ложное «Недоступны: …».
- **optimize**: на системах без systemd (Alpine/OpenRC) — честное предупреждение вместо сырой ошибки записи юнита; runtime-применение sysctl через `sysctl -p` (busybox без `--system`).
- **install**: обновление по тегу работало только при первой установке (`origin/<тег>` не существует — теперь `FETCH_HEAD`); ошибки git/скачивания больше не молчат; tarball-путь пробует и `refs/tags`.
- **меню**: октеты IPv4 проверяются (`300.1.1.1` отклоняется), NODE_PORT — число 1–65535 с переспросом.

## [4.1.0] — в `main` с 2026-07-12

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