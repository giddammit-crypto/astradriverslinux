#!/bin/bash
# ============================================================================
#  install.sh — консольный установщик компонентов (fallback без GUI)
#  Сайт: https://biblioteka33.ru/linux
#
#  Запуск:  curl -fsSL https://biblioteka33.ru/linux/scripts/install.sh | bash
#        или: bash install.sh
# ============================================================================
set -euo pipefail

C0='\033[0m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[1;34m'; DIM='\033[2m'
if [ ! -t 1 ]; then
    C0=''; G=''; Y=''; B=''; DIM=''
fi

BASE="https://biblioteka33.ru/linux/scripts"
log()  { echo -e "${B}[*]${C0} $*"; }

# Безопасное определение каталога скрипта (работает и при pipe curl | bash)
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
fi

echo -e "${B}╔══════════════════════════════════════════════╗${C0}"
echo -e "${B}║   Astra Linux Helper — установка компонентов  ║${C0}"
echo -e "${B}║   biblioteka33.ru/linux                        ║${C0}"
echo -e "${B}╚══════════════════════════════════════════════╝${C0}"
echo

echo "  1) 🖨️  Canon LBP2900 (драйвер + очередь печати)"
echo "  2) 🎨  Epson L800 (драйвер + СНПЧ + PDF-фикс)"
echo "  3) 📄  Epson L132 (драйвер 201401w + очередь)"
echo "  4) 📚  Патч НЭБ РФ (чинит запуск и SSL к rusneb.ru)"
echo "  5) 📦  Всё сразу (драйверы + НЭБ РФ)"
echo "  0) Выход"
echo

choice=""
for arg in "$@"; do
    case "$arg" in
        0|1|2|3|4|5) choice="$arg"; break ;;
    esac
done

if [ -z "${choice:-}" ]; then
    # Надёжно читаем из /dev/tty если stdin — пайп (curl | bash)
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        read -rp "Выберите [0-5]: " choice </dev/tty
    else
        read -rp "Выберите [0-5]: " choice
    fi
fi

fetch() {  # $1=имя скрипта, $2=нужен ли root
    local script_name="$1"
    local need_root="$2"
    local script_file=""
    local tmp=""

    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/$script_name" ]; then
        script_file="$SCRIPT_DIR/$script_name"
    else
        tmp=$(mktemp /tmp/astra-XXXXXX.sh)
        log "Скачиваю $script_name..."
        if ! curl -fsSL --connect-timeout 15 --max-time 300 "$BASE/$script_name" -o "$tmp"; then
            echo -e "${Y}[!!]${C0} Не удалось скачать $script_name — проверьте подключение к интернету."
            rm -f "$tmp"
            return 1
        fi
        script_file="$tmp"
    fi

    echo -e "${DIM}────────── выполнение $script_name ──────────${C0}"
    local rc=0
    if [ "$need_root" = "sudo" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            bash "$script_file" || rc=$?
        else
            sudo bash "$script_file" || rc=$?
        fi
    else
        bash "$script_file" || rc=$?
    fi
    [ -n "${tmp:-}" ] && rm -f "$tmp" || true
    echo -e "${DIM}───────────────────────────────────────────${C0}"
    return $rc
}

case "${choice:-}" in
    1) fetch canon-lbp2900.sh sudo ;;
    2) fetch epson-l800.sh    sudo ;;
    3) fetch epson-l132.sh    sudo ;;
    4) fetch nelrf-fix.sh     user ;;
    5)
        fetch canon-lbp2900.sh sudo
        fetch epson-l800.sh    sudo
        fetch epson-l132.sh    sudo
        fetch nelrf-fix.sh     user
        ;;
    0) echo "Выход."; exit 0 ;;
    *) echo "Неверный выбор: $choice"; exit 1 ;;
esac

echo
echo -e "${G}Готово.${C0} Вопросы и помощь: https://biblioteka33.ru/linux"
