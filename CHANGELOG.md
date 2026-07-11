# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## [4.0] — не выпущено (ветка `modular`)

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