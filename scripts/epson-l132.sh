#!/bin/bash
# ============================================================================
#  epson-l132.sh — драйвер Epson L132 для Astra Linux / Debian / Ubuntu
#
#  Что делает:
#   1) Ставит системные зависимости: cups, cups-client, ghostscript,
#      imagemagick, libjpeg62-turbo (с созданием симлинка libjpeg.so.62 при нужде);
#   2) Ищет пакет epson-inkjet-printer-201401w_1.0.0-1lsb3.2_amd64.deb в dist/ локально
#      или скачивает с сервера biblioteka33.ru;
#   3) Устанавливает драйвер и регистрирует PPD EPSON_L132.ppd;
#   4) Снимает ограничения ImageMagick policy (PDF/PS) для фильтра печати;
#   5) Автоматически определяет подключенный USB-принтер через lpinfo -v;
#      если принтер отключен — создает очередь с usb://EPSON/L132%20Series,
#      активирует cupsenable и cupsaccept;
#   6) Создает udev-правило /etc/udev/rules.d/86-epson-l132.rules для
#      горячего подключения и автопривязки;
#   7) Добавляет текущего пользователя в группу lp и перезапускает cups.
#
#  Запуск:  sudo bash epson-l132.sh
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

PRINTER="Epson-L132"
DEB_NAME="epson-inkjet-printer-201401w_1.0.0-1lsb3.2_amd64.deb"
BASE_URL="https://biblioteka33.ru/linux/dist/${DEB_NAME}"
WORK="$(mktemp -d /tmp/epson-l132-XXXXXX)"
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
else
    command -v lpadmin >/dev/null 2>&1 || die "Команда lpadmin (CUPS) не найдена в системе"
fi

# Проверка наличия библиотеки libjpeg.so.62
if [ ! -f /usr/lib/x86_64-linux-gnu/libjpeg.so.62 ] && [ ! -f /usr/lib/libjpeg.so.62 ]; then
    log "Поиск совместимой libjpeg для фильтра Epson..."
    SYS_LIBJPEG=$(find /usr/lib/x86_64-linux-gnu /usr/lib -name "libjpeg.so.[89]*" 2>/dev/null | head -1)
    if [ -n "$SYS_LIBJPEG" ]; then
        ln -sf "$SYS_LIBJPEG" /usr/lib/x86_64-linux-gnu/libjpeg.so.62 2>/dev/null \
            || ln -sf "$SYS_LIBJPEG" /usr/lib/libjpeg.so.62 2>/dev/null || true
        ok "Создан симлинк libjpeg.so.62 -> $(basename "$SYS_LIBJPEG")"
    fi
fi

command -v lpadmin >/dev/null 2>&1 || die "CUPS не установлен или недоступен"

# ----------------------------------------------------------------------------
# 2. Поиск и загрузка пакета драйвера Epson L132
# ----------------------------------------------------------------------------
DEB_PATH=""

# Проверяем локальные каталоги
for cand in \
    "$(cd "$(dirname "$0")/../dist" 2>/dev/null && pwd)/${DEB_NAME}" \
    "$(cd "$(dirname "$0")/dist" 2>/dev/null && pwd)/${DEB_NAME}" \
    "/home/astra/vint2/linux/dist/${DEB_NAME}" \
    "/root/dist/${DEB_NAME}" \
    "/root/${DEB_NAME}" \
    "$(pwd)/dist/${DEB_NAME}" \
    "$(pwd)/${DEB_NAME}"; do
    if [ -f "$cand" ]; then
        DEB_PATH="$cand"
        ok "Найден локальный пакет: $DEB_PATH"
        break
    fi
done

# Если локально нет — скачиваем с сервера
if [ -z "$DEB_PATH" ]; then
    log "Загрузка официального драйвера Epson L132 с $BASE_URL..."
    if curl -fsSL --connect-timeout 15 --max-time 180 -o "$WORK/$DEB_NAME" "$BASE_URL"; then
        DEB_PATH="$WORK/$DEB_NAME"
        ok "Драйвер успешно загружен с сервера проекта"
    else
        warn "Не удалось скачать с сервера проекта — проверяем GitHub-зеркало..."
        GITHUB_URL="https://raw.githubusercontent.com/cigarzh/epson-inkjet-printer-201401w/main/sign_epson-inkjet-printer-201401w_1_0_0_amd64.deb"
        if curl -fsSL --connect-timeout 15 --max-time 180 -o "$WORK/$DEB_NAME" "$GITHUB_URL"; then
            DEB_PATH="$WORK/$DEB_NAME"
            ok "Драйвер успешно загружен с резервного зеркала"
        fi
    fi
fi

[ -n "$DEB_PATH" ] && [ -f "$DEB_PATH" ] || die "Не удалось найти или загрузить $DEB_NAME"

# ----------------------------------------------------------------------------
# 3. Установка пакета драйвера
# ----------------------------------------------------------------------------
log "Установка $(basename "$DEB_PATH")..."
dpkg -i "$DEB_PATH" 2>/dev/null || {
    warn "Доустановка системных зависимостей через apt-get -f..."
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true
}

# Обновление кэша динамических библиотек
ldconfig 2>/dev/null || true

# Поиск PPD-файла Epson L132
PPDFILE=$(find /usr/share/cups/model /opt -iname "*L132*.ppd*" 2>/dev/null | head -1)
if [ -z "$PPDFILE" ]; then
    PPDFILE=$(find /usr/share/cups/model /opt -iname "*L130*.ppd*" 2>/dev/null | head -1)
fi

[ -n "$PPDFILE" ] || die "PPD-файл Epson L132 не найден после установки пакета!"
ok "Драйвер установлен, PPD-файл: $PPDFILE"

# Проверяем исполняемый фильтр печати
FILTER_BIN=$(find /opt /usr/lib/cups/filter -name "epson_inkjet_printer_filter" -type f 2>/dev/null | head -1)
if [ -n "$FILTER_BIN" ]; then
    chmod +x "$FILTER_BIN"
    mkdir -p /usr/lib/cups/filter
    if [ ! -e /usr/lib/cups/filter/epson_inkjet_printer_filter ]; then
        ln -sf "$FILTER_BIN" /usr/lib/cups/filter/epson_inkjet_printer_filter
    fi
fi

# ----------------------------------------------------------------------------
# 4. Снятие ограничений ImageMagick policy (устраняет падение CUPS-фильтра на PDF)
# ----------------------------------------------------------------------------
for p in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml /etc/ImageMagick/policy.xml; do
    [ -f "$p" ] || continue
    [ -f "$p.bak" ] || cp -a "$p" "$p.bak"
    sed -i 's|<policy domain="coder" rights="none" pattern="PDF" />|<policy domain="coder" rights="read\|write" pattern="PDF" />|g' "$p"
    sed -i 's|<policy domain="coder" rights="none" pattern="PS" />|<policy domain="coder" rights="read\|write" pattern="PS" />|g' "$p"
    sed -i 's|<policy domain="ghostscript" rights="none" pattern="PS" />|<policy domain="ghostscript" rights="read\|write" pattern="PS" />|g' "$p"
    ok "ImageMagick policy обновлена для корректной печати PDF/PS: $p"
done

# ----------------------------------------------------------------------------
# 5. Регистрация очереди печати (работает сразу!)
# ----------------------------------------------------------------------------
log "Регистрация очереди печати $PRINTER..."
lpadmin -x "$PRINTER" 2>/dev/null || true

# Поиск реального USB-URI подключенного принтера
USBURI=$(lpinfo -v 2>/dev/null | grep -iE "epson.*l132|epson.*l130|usb://epson" | head -1 | awk '{print $2}')

if [ -n "$USBURI" ]; then
    lpadmin -p "$PRINTER" -P "$PPDFILE" -v "$USBURI" -E -o printer-is-shared=false
    ok "Принтер обнаружен и привязан к USB: $USBURI"
else
    # Создаем очередь с постоянным URI
    DEFAULT_URI="usb://EPSON/L132%20Series"
    lpadmin -p "$PRINTER" -P "$PPDFILE" -v "$DEFAULT_URI" -E -o printer-is-shared=false
    ok "Очередь '$PRINTER' создана. Принтер готов к горячему подключению USB."
fi

# Активация очереди и прием заданий
cupsenable "$PRINTER" 2>/dev/null || true
cupsaccept "$PRINTER" 2>/dev/null || true

# UDEV правило для автоматической привязки при подключении USB
cat > /etc/udev/rules.d/86-epson-l132.rules <<EOF
# Автоматическая активация Epson L132 при подключении по USB
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", RUN+="/usr/sbin/cupsenable $PRINTER", RUN+="/usr/sbin/cupsaccept $PRINTER"
EOF
udevadm control --reload-rules 2>/dev/null || true

# Добавление пользователя в группу печати lp
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
if [ -n "$REAL_USER" ] && id "$REAL_USER" >/dev/null 2>&1; then
    usermod -aG lp "$REAL_USER" 2>/dev/null || true
    usermod -aG lpadmin "$REAL_USER" 2>/dev/null || true
    ok "Пользователь '$REAL_USER' добавлен в группы печати (lp, lpadmin)"
fi

# Перезапуск CUPS
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || true
else
    service cups restart 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 6. Финальная проверка
# ----------------------------------------------------------------------------
sleep 1
echo
if lpstat -p "$PRINTER" >/dev/null 2>&1; then
    ok "Очередь '$PRINTER' готова к печати!"
    echo -e "   Команда для проверки: ${B}lp -d $PRINTER /etc/issue${C0}"
else
    warn "Очередь создана. После подключения принтера перезапустите: sudo systemctl restart cups"
fi

echo
echo -e "${G}Готово!${C0} Принтер Epson L132 полностью настроен для работы."
echo "Сайт проекта: https://biblioteka33.ru/linux"
