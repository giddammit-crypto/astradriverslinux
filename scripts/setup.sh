#!/bin/bash
# ============================================================================
#  setup.sh — Единая точка входа для установки оборудования «Космо»
#  Сайт: https://biblioteka33.ru/linux
#
#  Запуск одной командой:
#    curl -fsSL https://biblioteka33.ru/linux/scripts/setup.sh | bash
# ============================================================================
set -euo pipefail

C0='\033[0m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[1;34m'; R='\033[0;31m'
if [ ! -t 1 ]; then
    C0=''; G=''; Y=''; B=''; R=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }

BASE_URL="https://biblioteka33.ru/linux"
SCRIPT_SOURCE_DIR=""

# Проверяем, запущен ли скрипт из локального репозитория
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi

LOCAL_REPO=""
if [ -n "$SCRIPT_SOURCE_DIR" ]; then
    if [ -f "$SCRIPT_SOURCE_DIR/../installer_gui.py" ]; then
        LOCAL_REPO="$(cd "$SCRIPT_SOURCE_DIR/.." && pwd)"
    elif [ -f "$SCRIPT_SOURCE_DIR/installer_gui.py" ]; then
        LOCAL_REPO="$SCRIPT_SOURCE_DIR"
    fi
fi

if [ -n "$LOCAL_REPO" ]; then
    WORK_DIR="$LOCAL_REPO"
    IS_TEMP=0
else
    WORK_DIR=$(mktemp -d /tmp/cosmo-setup-XXXXXX)
    IS_TEMP=1
    trap 'rm -rf "$WORK_DIR"' EXIT

    log "Загрузка компонентов установщика «Космо»..."
    mkdir -p "$WORK_DIR/scripts" "$WORK_DIR/assets"

    download() {
        local rel="$1"
        local dst="$WORK_DIR/$rel"
        mkdir -p "$(dirname "$dst")"
        if ! curl -fsSL --connect-timeout 10 --max-time 120 "$BASE_URL/$rel" -o "$dst"; then
            warn "Не удалось загрузить $rel с $BASE_URL/$rel"
            return 1
        fi
        return 0
    }

    # Скачиваем скрипты и ассеты
    download "installer_gui.py" || true
    download "assets/hero-cosmo.png" || true
    download "scripts/install.sh" || true
    download "scripts/canon-lbp2900.sh" || true
    download "scripts/epson-l800.sh" || true
    download "scripts/epson-l132.sh" || true
    download "scripts/nelrf-fix.sh" || true
fi

chmod +x "$WORK_DIR/installer_gui.py" 2>/dev/null || true
chmod +x "$WORK_DIR/scripts/"*.sh 2>/dev/null || true

# Проверка наличия графического окружения
HAS_DISPLAY=0
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    HAS_DISPLAY=1
fi

# Проверка работоспособности GTK3 в Python
CAN_RUN_GUI=0
if [ "$HAS_DISPLAY" -eq 1 ] && [ -f "$WORK_DIR/installer_gui.py" ]; then
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk; exit(0 if Gtk.init_check()[0] else 1)" 2>/dev/null; then
            CAN_RUN_GUI=1
        fi
    fi
fi

# Если графический интерфейс доступен — запускаем GUI
if [ "$CAN_RUN_GUI" -eq 1 ] && [ "${1:-}" != "--cli" ]; then
    log "Запуск графического мастера установки «Космо»..."
    # Разрешаем root доступ к X-серверу на случай запуска через pkexec / sudo
    xhost +si:localuser:root >/dev/null 2>&1 || true
    exec python3 "$WORK_DIR/installer_gui.py" "$@"
else
    # Консольный режим (fallback)
    if [ "$HAS_DISPLAY" -eq 0 ]; then
        log "Графическое окружение не обнаружено. Запуск консольного установщика..."
    elif [ "${1:-}" = "--cli" ]; then
        log "Запрошен консольный режим (--cli)..."
    else
        warn "GTK 3 или графический сервер недоступны. Переход в консольный режим..."
    fi

    if [ -f "$WORK_DIR/scripts/install.sh" ]; then
        exec bash "$WORK_DIR/scripts/install.sh" "$@"
    elif [ -f "$WORK_DIR/installer_gui.py" ]; then
        exec python3 "$WORK_DIR/installer_gui.py" --cli "$@"
    else
        err "Ошибка: установщик не найден."
        exit 1
    fi
fi
