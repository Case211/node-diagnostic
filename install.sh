#!/usr/bin/env bash
# install.sh — бутстрап node-diagnostic: скачать репозиторий целиком и запустить меню.
# Установка одной командой:
#   curl -sSL https://raw.githubusercontent.com/Case211/node-diagnostic/main/install.sh | sudo bash
# Переопределяемо через env: ND_REPO, ND_REF (ветка/тег), ND_DEST (каталог).
set -eu

REPO="${ND_REPO:-https://github.com/Case211/node-diagnostic}"
REF="${ND_REF:-main}"
if [ "$(id -u)" -eq 0 ]; then DEST="${ND_DEST:-/opt/node-diagnostic}"
else DEST="${ND_DEST:-$HOME/.local/share/node-diagnostic}"; fi

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '  %s\n' "$*"; }

say "node-diagnostic → $DEST  (ref: $REF)"

if have git; then
    if [ -d "$DEST/.git" ]; then
        # FETCH_HEAD вместо origin/$REF — работает и для ветки, и для тега
        # (origin/<тег> не существует, старый вариант на теге молча умирал)
        if git -C "$DEST" fetch --depth 1 origin "$REF" >/dev/null 2>&1 \
           && git -C "$DEST" reset --hard FETCH_HEAD >/dev/null 2>&1; then
            say "обновлено через git"
        else
            say "ОШИБКА: не смог обновить $DEST (нет сети? ref '$REF' существует?)"
            exit 1
        fi
    else
        rm -rf "$DEST"
        git clone --quiet --depth 1 --branch "$REF" "$REPO" "$DEST" \
            || { say "ОШИБКА: клонирование не удалось ($REPO, ref '$REF')"; exit 1; }
        say "склонировано через git"
    fi
else
    # без git — tarball; пробуем ветку, затем тег
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    fetch() {
        if   have curl; then curl -fsSL "$1" -o "$tmp/src.tgz"
        elif have wget; then wget -qO "$tmp/src.tgz" "$1"
        else say "нужен git, curl или wget"; exit 1; fi
    }
    fetch "$REPO/archive/refs/heads/$REF.tar.gz" \
        || fetch "$REPO/archive/refs/tags/$REF.tar.gz" \
        || { say "ОШИБКА: не скачал tarball для ref '$REF'"; exit 1; }
    tar -xzf "$tmp/src.tgz" -C "$tmp"
    mkdir -p "$DEST"
    cp -r "$tmp"/node-diagnostic-*/. "$DEST/"
    say "распаковано из tarball"
fi

chmod +x "$DEST/node-diagnostic.sh" "$DEST"/modules/*.sh "$DEST"/lib/*.sh 2>/dev/null || true

echo
say "Готово. Запуск:"
say "  sudo bash $DEST/node-diagnostic.sh"

# В терминале — сразу открыть меню. При `curl | bash` stdin занят пайпом,
# поэтому подключаем клавиатуру через /dev/tty (иначе меню не открылось бы никогда).
if [ -t 1 ] && [ -r /dev/tty ]; then
    exec bash "$DEST/node-diagnostic.sh" "$@" </dev/tty
fi
