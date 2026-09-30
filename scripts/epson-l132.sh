#!/bin/bash
# ============================================================================
#  epson-l132.sh — драйвер Epson L132 для Astra Linux / Debian / Ubuntu
#
#  Запуск:  sudo bash epson-l132.sh
#  Сайт:    https://biblioteka33.ru/linux
# ============================================================================
set -euo pipefail

C0='\033[0m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[1;34m'
if [ ! -t 1 ]; then
    C0=''; G=''; Y=''; R=''; B=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }
die()  { err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запустите скрипт с правами root: sudo bash $0"

PRINTER="Epson-L132"
DEB_NAME="epson-inkjet-printer-201401w_1.0.0-1lsb3.2_amd64.deb"
BASE_URL="https://biblioteka33.ru/linux/dist"
WORK="$(mktemp -d /tmp/epson-l132-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

. /etc/os-release 2>/dev/null || true
log "Операционная система: ${PRETTY_NAME:-неизвестно}"

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
[ "$ARCH" = "amd64" ] || [ "$ARCH" = "x86_64" ] || warn "Драйвер оптимизирован под 64-битные архитектуры (amd64)"

log "Установка зависимостей..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || warn "apt-get update не прошел — продолжаем"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cups cups-client ghostscript imagemagick || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libjpeg62-turbo 2>/dev/null \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libjpeg62 2>/dev/null || true
else
    command -v lpadmin >/dev/null 2>&1 || die "lpadmin (CUPS) не найден"
fi

if [ ! -f /usr/lib/x86_64-linux-gnu/libjpeg.so.62 ] && [ ! -f /usr/lib/libjpeg.so.62 ]; then
    SYS_LIBJPEG=$(find /usr/lib/x86_64-linux-gnu /usr/lib -name 'libjpeg.so.[89]*' 2>/dev/null | head -1) || true
    if [ -n "${SYS_LIBJPEG:-}" ]; then
        ln -sf "$SYS_LIBJPEG" /usr/lib/x86_64-linux-gnu/libjpeg.so.62 2>/dev/null \
            || ln -sf "$SYS_LIBJPEG" /usr/lib/libjpeg.so.62 2>/dev/null || true
        ok "Симлинк libjpeg.so.62 -> $(basename "$SYS_LIBJPEG")"
    fi
fi
command -v lpadmin >/dev/null 2>&1 || die "CUPS недоступен"

DEB_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
for cand in \
    "${SCRIPT_DIR:+$SCRIPT_DIR/../dist/$DEB_NAME}" \
    "${SCRIPT_DIR:+$SCRIPT_DIR/dist/$DEB_NAME}" \
    "/root/$DEB_NAME" "$(pwd)/dist/$DEB_NAME" "$(pwd)/$DEB_NAME"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { DEB_PATH="$cand"; ok "Локальный пакет: $DEB_PATH"; break; } || true
done

if [ -z "${DEB_PATH:-}" ]; then
    log "Загрузка драйвера Epson L132..."
    if curl -fsSL --connect-timeout 15 --max-time 180 -o "$WORK/$DEB_NAME" "$BASE_URL/$DEB_NAME"; then
        DEB_PATH="$WORK/$DEB_NAME"; ok "Загружен с biblioteka33.ru"
    else
        warn "Основной сервер недоступен — пробуем GitHub..."
        GITHUB_URL="https://raw.githubusercontent.com/giddammit-crypto/astradriverslinux/main/dist/$DEB_NAME"
        curl -fsSL --connect-timeout 15 --max-time 180 -o "$WORK/$DEB_NAME" "$GITHUB_URL" \
            && DEB_PATH="$WORK/$DEB_NAME" && ok "Загружен с GitHub" \
            || die "Не удалось загрузить $DEB_NAME ни с одного сервера"
    fi
fi

log "Установка..."
dpkg -i "$DEB_PATH" 2>/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true; }
ldconfig 2>/dev/null || true

PPDFILE=$(find /usr/share/cups/model /opt -iname '*L132*.ppd*' 2>/dev/null | head -1) || true
[ -z "${PPDFILE:-}" ] && PPDFILE=$(find /usr/share/cups/model /opt -iname '*L130*.ppd*' 2>/dev/null | head -1) || true
[ -n "${PPDFILE:-}" ] || die "PPD-файл Epson L132 не найден!"
ok "Драйвер установлен, PPD: $PPDFILE"

FILTER_BIN=$(find /opt /usr/lib/cups/filter -name 'epson_inkjet_printer_filter' -type f 2>/dev/null | head -1) || true
if [ -n "${FILTER_BIN:-}" ]; then
    chmod +x "$FILTER_BIN"
    mkdir -p /usr/lib/cups/filter
    [ -e /usr/lib/cups/filter/epson_inkjet_printer_filter ] || \
        ln -sf "$FILTER_BIN" /usr/lib/cups/filter/epson_inkjet_printer_filter
fi

for p in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml /etc/ImageMagick/policy.xml; do
    [ -f "$p" ] || continue
    [ -f "${p}.bak" ] || cp -a "$p" "${p}.bak"
    sed -i 's|rights="none" pattern="PDF"|rights="read|write" pattern="PDF"|g' "$p"
    sed -i 's|rights="none" pattern="PS"|rights="read|write" pattern="PS"|g'  "$p"
    ok "ImageMagick policy обновлена: $p"
done

log "Регистрация очереди..."
lpadmin -x "$PRINTER" 2>/dev/null || true
USBURI=$(lpinfo -v 2>/dev/null | grep -iE 'epson.*l13[02]|usb://EPSON/L13' | head -1 | awk '{print $2}') || true
if [ -n "${USBURI:-}" ]; then
    lpadmin -p "$PRINTER" -P "$PPDFILE" -v "$USBURI" -E -o printer-is-shared=false
    ok "USB: $USBURI"
else
    lpadmin -p "$PRINTER" -P "$PPDFILE" -v "usb://EPSON/L132%20Series" -E -o printer-is-shared=false
    ok "Очередь '$PRINTER' создана."
fi
cupsenable "$PRINTER" 2>/dev/null || true
cupsaccept "$PRINTER" 2>/dev/null || true

cat > /etc/udev/rules.d/86-epson-l132.rules << 'UDEV'
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", \
    RUN+="/usr/sbin/cupsenable Epson-L132", RUN+="/usr/sbin/cupsaccept Epson-L132"
UDEV
udevadm control --reload-rules 2>/dev/null || true
ok "udev: /etc/udev/rules.d/86-epson-l132.rules"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
[ -n "${REAL_USER:-}" ] && id "$REAL_USER" >/dev/null 2>&1 && usermod -aG lp,lpadmin "$REAL_USER" 2>/dev/null || true

command -v systemctl >/dev/null 2>&1 && systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || true
sleep 1; echo
lpstat -p "$PRINTER" >/dev/null 2>&1 \
    && ok "Очередь '$PRINTER' готова к печати!" \
    || warn "Перезапустите: sudo systemctl restart cups"
echo; echo -e "${G}Готово!${C0} Epson L132 настроен. https://biblioteka33.ru/linux"
