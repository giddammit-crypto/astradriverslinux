#!/bin/bash
# ============================================================================
#  epson-l800.sh — драйвер Epson L800 для Astra Linux / Debian / Ubuntu
#
#  Что делает:
#   1) Ставит системные зависимости: cups, cups-client, ghostscript,
#      imagemagick, libjpeg62-turbo (с созданием симлинка libjpeg.so.62 при нужде);
#   2) Ищет пакет epson-inkjet-printer-l800_1.0.1-1_amd64.deb в dist/ локально,
#      скачивает с сервера biblioteka33.ru, либо использует фолбэк на src.rpm/rpm;
#   3) Устанавливает драйвер и проверяет наличие PPD EPSON_L800.ppd;
#   4) Снимает ограничения ImageMagick policy (PDF/PS) для фильтра печати;
#   5) Автоматически определяет подключенный USB-принтер через lpinfo -v;
#      если принтер отключен — создает очередь с usb://EPSON/L800%20Series,
#      активирует cupsenable и cupsaccept;
#   6) Создает udev-правило /etc/udev/rules.d/86-epson-l800.rules для
#      горячего подключения и автопривязки;
#   7) Добавляет текущего пользователя в группу lp и перезапускает cups.
#
#  Запуск:  sudo bash epson-l800.sh
#  Сайт:    https://biblioteka33.ru/linux
# ============================================================================
set -u

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

PRINTER="Epson-L800"
DEB_NAME="epson-inkjet-printer-l800_1.0.1-1_amd64.deb"
BASE_URL="https://biblioteka33.ru/linux/dist/epson-inkjet-printer-l800_1.0.1-1_amd64.deb"
WORK="$(mktemp -d /tmp/epson-l800-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------
# 0. Окружение
# ----------------------------------------------------------------------------
. /etc/os-release 2>/dev/null || true
log "Операционная система: ${PRETTY_NAME:-неизвестно}"

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
[ "$ARCH" = "amd64" ] || [ "$ARCH" = "x86_64" ] || warn "Драйвер оптимизирован под 64-битные архитектуры (amd64)"

# ----------------------------------------------------------------------------
# 1. Зависимости (CUPS, ghostscript, imagemagick, libjpeg62-turbo)
# ----------------------------------------------------------------------------
log "Установка зависимостей (cups, cups-client, ghostscript, imagemagick, libjpeg62-turbo)..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || warn "apt-get update не прошел (офлайн?) — продолжаем"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        cups cups-client ghostscript imagemagick \
        || warn "Часть базовых пакетов не установилась из репозитория"

    # libjpeg62-turbo для фильтра печати epson_inkjet_printer_filter
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libjpeg62-turbo 2>/dev/null \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libjpeg62 2>/dev/null || true
fi
command -v lpadmin >/dev/null 2>&1 || die "Команда lpadmin (CUPS) не найдена — проверьте установку CUPS"

# Проверка наличия библиотеки libjpeg.so.62 и создание симлинка при необходимости
if ! ldconfig -p 2>/dev/null | grep -q "libjpeg.so.62" \
   && [ ! -f /usr/lib/x86_64-linux-gnu/libjpeg.so.62 ] \
   && [ ! -f /usr/lib64/libjpeg.so.62 ] \
   && [ ! -f /usr/lib/libjpeg.so.62 ]; then
    log "Поиск системной libjpeg для создания совместимого симлинка libjpeg.so.62..."
    JPEG_SRC=$(find /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu /lib64 /lib \
        -maxdepth 3 \( -name "libjpeg.so.8*" -o -name "libjpeg.so.9*" -o -name "libjpeg.so" \) 2>/dev/null | head -1)
    if [ -n "$JPEG_SRC" ]; then
        TARGET_LIB_DIR="/usr/lib/x86_64-linux-gnu"
        [ -d "$TARGET_LIB_DIR" ] || TARGET_LIB_DIR="/usr/lib"
        ln -sf "$JPEG_SRC" "$TARGET_LIB_DIR/libjpeg.so.62"
        ldconfig 2>/dev/null || true
        ok "Создан симлинк совместимости: $TARGET_LIB_DIR/libjpeg.so.62 -> $JPEG_SRC"
    else
        warn "libjpeg.so.62 не найдена. Если печать не начнется, установите пакет libjpeg62-turbo"
    fi
else
    ok "Библиотека libjpeg.so.62 присутствует в системе"
fi

# ----------------------------------------------------------------------------
# 2. Поиск и получение пакета драйвера
# ----------------------------------------------------------------------------
DEB=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CANDIDATE_DIRS=(
    "$SCRIPT_DIR/../dist"
    "$SCRIPT_DIR/dist"
    "$SCRIPT_DIR"
    "/home/astra/vint2/linux/dist"
    "$(pwd)/dist"
    "$(pwd)"
    "/root/dist"
    "/root"
)

log "Поиск пакета $DEB_NAME..."
for d in "${CANDIDATE_DIRS[@]}"; do
    if [ -f "$d/$DEB_NAME" ]; then
        DEB="$d/$DEB_NAME"
        break
    fi
done

# Если точное имя не найдено, ищем epson*.deb
if [ -z "$DEB" ]; then
    for d in "${CANDIDATE_DIRS[@]}"; do
        [ -d "$d" ] || continue
        c=$(find "$d" -maxdepth 2 -iname "*epson*l800*.deb" -o -iname "*epson-inkjet*.deb" 2>/dev/null | head -1)
        if [ -n "$c" ]; then
            DEB="$c"
            break
        fi
    done
fi

if [ -n "$DEB" ] && [ -f "$DEB" ]; then
    ok "Найден локальный пакет драйвера: $DEB"
else
    log "Локальный пакет не найден, скачиваю с $BASE_URL ..."
    if curl -fsSL --connect-timeout 15 --max-time 300 -o "$WORK/$DEB_NAME" "$BASE_URL"; then
        DEB="$WORK/$DEB_NAME"
        ok "Пакет успешно загружен: $DEB"
    else
        warn "Загрузка с BASE_URL не удалась, пробую фолбэк (src.rpm / зеркала)..."
        # Поиск src.rpm или rpm пакета локально или скачивание
        SRC_RPM=""
        for d in "${CANDIDATE_DIRS[@]}"; do
            [ -d "$d" ] || continue
            c=$(find "$d" -maxdepth 2 -iname "*epson*l800*.rpm" -o -iname "*epson*201101w*.rpm" 2>/dev/null | head -1)
            [ -n "$c" ] && SRC_RPM="$c" && break
        done

        if [ -n "$SRC_RPM" ]; then
            log "Распаковка фильтра и PPD из rpm-пакета: $SRC_RPM"
            if command -v rpm2cpio >/dev/null 2>&1; then
                mkdir -p "$WORK/rpm_extracted"
                (cd "$WORK/rpm_extracted" && rpm2cpio "$SRC_RPM" | cpio -idmv >/dev/null 2>&1)
                # Установка фильтра и PPD вручную
                RPM_FILTER=$(find "$WORK/rpm_extracted" -name "epson_inkjet_printer_filter" | head -1)
                RPM_PPD=$(find "$WORK/rpm_extracted" -iname "*L800*.ppd*" | head -1)
                if [ -n "$RPM_FILTER" ] && [ -n "$RPM_PPD" ]; then
                    mkdir -p /opt/epson-inkjet-printer-l800/cups/lib/filter /usr/lib/cups/filter /usr/share/cups/model/epson-inkjet-printer-l800
                    cp -a "$RPM_FILTER" /opt/epson-inkjet-printer-l800/cups/lib/filter/
                    chmod +x /opt/epson-inkjet-printer-l800/cups/lib/filter/epson_inkjet_printer_filter
                    ln -sf /opt/epson-inkjet-printer-l800/cups/lib/filter/epson_inkjet_printer_filter /usr/lib/cups/filter/epson_inkjet_printer_filter
                    cp -a "$RPM_PPD" /usr/share/cups/model/epson-inkjet-printer-l800/EPSON_L800.ppd
                    ok "Фильтр печати и PPD успешно извлечены из $SRC_RPM"
                    DEB="MANUALLY_INSTALLED_FROM_RPM"
                fi
            else
                warn "rpm2cpio не установлен — не удалось распаковать $SRC_RPM"
            fi
        fi
    fi
fi

# ----------------------------------------------------------------------------
# 3. Установка deb-пакета
# ----------------------------------------------------------------------------
if [ "$DEB" != "MANUALLY_INSTALLED_FROM_RPM" ]; then
    [ -n "$DEB" ] && [ -f "$DEB" ] || die "Не удалось найти или скачать пакет драйвера Epson L800"
    if ! dpkg -i "$DEB" 2>/dev/null; then
        log "  Доустановка зависимостей через apt-get..."
        DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true
        dpkg -i "$DEB" 2>/dev/null || true
    fi
fi

# Проверка PPD
PPDFILE="/usr/share/cups/model/epson-inkjet-printer-l800/EPSON_L800.ppd"
if [ ! -f "$PPDFILE" ]; then
    PPDFILE=$(find /usr/share/cups/model /usr/share/ppd /opt -iname "*L800*.ppd*" 2>/dev/null | head -1)
fi
[ -n "$PPDFILE" ] && [ -f "$PPDFILE" ] || die "PPD файл для Epson L800 не найден после установки драйвера"
ok "Драйвер установлен, PPD файл: $PPDFILE"

# Проверка симлинка фильтра в /usr/lib/cups/filter/
if [ -f "/opt/epson-inkjet-printer-l800/cups/lib/filter/epson_inkjet_printer_filter" ]; then
    mkdir -p /usr/lib/cups/filter
    ln -sf /opt/epson-inkjet-printer-l800/cups/lib/filter/epson_inkjet_printer_filter /usr/lib/cups/filter/epson_inkjet_printer_filter
    chmod +x /opt/epson-inkjet-printer-l800/cups/lib/filter/epson_inkjet_printer_filter
fi

# ----------------------------------------------------------------------------
# 4. Снятие ограничений ImageMagick policy (PDF/PS)
# ----------------------------------------------------------------------------
log "Снятие ограничений ImageMagick security policy для печати..."
for p in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml /etc/ImageMagick/policy.xml; do
    [ -f "$p" ] || continue
    [ -f "$p.bak" ] || cp -a "$p" "$p.bak"
    sed -i 's|<policy domain="coder" rights="none" pattern="PDF"|<policy domain="coder" rights="read\|write" pattern="PDF"|g' "$p"
    sed -i 's|<policy domain="coder" rights="none" pattern="PS"|<policy domain="coder" rights="read\|write" pattern="PS"|g' "$p"
    sed -i 's|<policy domain="coder" rights="none" pattern="EPS"|<policy domain="coder" rights="read\|write" pattern="EPS"|g' "$p"
    sed -i 's|<policy domain="coder" rights="none" pattern="XPS"|<policy domain="coder" rights="read\|write" pattern="XPS"|g' "$p"
    sed -i 's|<policy domain="ghostscript" rights="none" pattern="PS"|<policy domain="ghostscript" rights="read\|write" pattern="PS"|g' "$p"
    sed -i 's|<policy domain="ghostscript" rights="none" pattern="PDF"|<policy domain="ghostscript" rights="read\|write" pattern="PDF"|g' "$p"
    ok "ImageMagick policy обновлена: $p (резервная копия $p.bak)"
done

# ----------------------------------------------------------------------------
# 5. Автоматическая регистрация очереди печати Epson-L800
# ----------------------------------------------------------------------------
log "Регистрация очереди печати $PRINTER в CUPS..."
systemctl start cups 2>/dev/null || service cups start 2>/dev/null || true
sleep 1

lpadmin -x "$PRINTER" 2>/dev/null || true

# Определение подключенного USB
USBURI=$(lpinfo -v 2>/dev/null | grep -iE "epson.*l800|usb://epson" | head -1 | awk '{print $2}')

if [ -n "$USBURI" ]; then
    lpadmin -p "$PRINTER" -P "$PPDFILE" -v "$USBURI" -E
    ok "Принтер Epson L800 обнаружен на порту: $USBURI"
else
    DEF_URI="usb://EPSON/L800%20Series"
    lpadmin -p "$PRINTER" -P "$PPDFILE" -v "$DEF_URI" -E
    warn "Принтер сейчас не подключен по USB — создана очередь с URI: $DEF_URI"
fi

cupsenable "$PRINTER" 2>/dev/null || true
cupsaccept "$PRINTER" 2>/dev/null || true
ok "Очередь печати $PRINTER активирована (cupsenable & cupsaccept)"

# ----------------------------------------------------------------------------
# 6. Udev-правило горячего подключения
# ----------------------------------------------------------------------------
log "Создание udev-правила автопривязки Epson L800..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/86-epson-l800.rules << 'EOF'
# Epson L800 printer hotplug auto-bind rule
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", RUN+="/bin/sh -c 'sleep 2; URI=$$(/usr/sbin/lpinfo -v 2>/dev/null | grep -iE \"epson.*l800|usb://epson\" | head -1 | awk \"{print \$$2}\"); [ -n \"$$URI\" ] && /usr/sbin/lpadmin -p Epson-L800 -v \"$$URI\" -E && /usr/sbin/cupsenable Epson-L800 && /usr/sbin/cupsaccept Epson-L800'"
EOF

udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
ok "Создано udev-правило /etc/udev/rules.d/86-epson-l800.rules"

# ----------------------------------------------------------------------------
# 7. Добавление пользователя в группу lp и перезапуск cups
# ----------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    usermod -aG lp "$TARGET_USER" 2>/dev/null || true
    ok "Пользователь $TARGET_USER добавлен в группу lp"
fi

log "Перезапуск службы CUPS..."
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl restart cups
else
    service cups restart 2>/dev/null || /etc/init.d/cups restart 2>/dev/null || true
fi
sleep 1

cupsenable "$PRINTER" 2>/dev/null || true
cupsaccept "$PRINTER" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 8. Проверка готовности
# ----------------------------------------------------------------------------
echo
log "Текущий статус очереди $PRINTER:"
lpstat -p "$PRINTER" 2>/dev/null || true

echo
echo -e "${G}================================================================${C0}"
echo -e "${G} Принтер Epson L800 успешно настроен и готов к работе!${C0}"
echo -e "   - Очередь печати: ${B}$PRINTER${C0}"
echo -e "   - PPD файл:       ${B}$PPDFILE${C0}"
echo -e "   - URI подключения: ${B}${USBURI:-$DEF_URI}${C0}"
echo -e "   - ImageMagick:     Ограничения PDF/PS сняты"
echo -e "   - Горячее подключение: автоматическая привязка через udev"
echo -e "   - Пробная печать:  ${B}lp -d $PRINTER /usr/share/cups/data/testprint${C0}"
echo -e "${G}================================================================${C0}"
echo "Сайт проекта: https://biblioteka33.ru/linux"
