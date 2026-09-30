#!/bin/bash
# ============================================================================
#  canon-lbp2900.sh — драйвер Canon LBP2900 для Astra Linux / Debian / Ubuntu
#
#  Что делает:
#   1) Ставит зависимости (CUPS, ghostscript, libpopt, usbutils, libglade2);
#   2) Ищет пакеты cndrvcups-common (3.21-1) и cndrvcups-capt (2.71-1) локально
#      в dist/, скачивает с сервера biblioteka33.ru или официального архива
#      archive.org / Canon;
#   3) Устанавливает пакеты cndrvcups-common и cndrvcups-capt;
#   4) Загружает модуль ядра usblp и закрепляет его в /etc/modules-load.d/;
#   5) Создает очередь печати: lpadmin -p LBP2900 -m CNCUPSLBP2900CAPTK.ppd
#      -v ccp://localhost:59787 -E, включает cupsenable и cupsaccept;
#   6) Автоматически определяет порт USB (/dev/usb/lp*) и привязывает очередь
#      через ccpdadmin -p LBP2900 -o /dev/usb/lp0;
#   7) Создает udev-правило /etc/udev/rules.d/85-canon-capt.rules для
#      автопривязки и перезапуска ccpd при горячем подключении принтера;
#   8) Настраивает systemd unit override и сервис ccpd, стартующий СТРОГО ПОСЛЕ cups;
#   9) Запускает cups и ccpd — принтер СРАЗУ готов к работе (для библиотекарей).
#
#  Запуск:  sudo bash canon-lbp2900.sh
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

[ "$(id -u)" -eq 0 ] || die "Запустите скрипт с правами суперпользователя: sudo bash $0"

PRINTER="LBP2900"
PPD="CNCUPSLBP2900CAPTK.ppd"
BASE_URL="https://biblioteka33.ru/linux/dist"
ARCHIVE_URL="https://archive.org/download/canon-lbp-2900-driver/Canon%20LBP2900%20Driver.gz"
WORK="$(mktemp -d /tmp/canon-lbp2900-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------
# 0. Окружение и архитектура
# ----------------------------------------------------------------------------
. /etc/os-release 2>/dev/null || true
log "Операционная система: ${PRETTY_NAME:-неизвестно}"
case "${ID:-} ${ID_LIKE:-}" in
    *astra*|*debian*|*ubuntu*) ;;
    *) warn "Дистрибутив не Debian/Ubuntu/Astra — установка может потребовать адаптации"; sleep 2 ;;
esac

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64) ARCH="amd64" ;;
    i386|i686)    ARCH="i386" ;;
    *) die "Архитектура $ARCH не поддерживается драйвером Canon CAPT (требуется amd64 или i386)" ;;
esac
log "Архитектура системы: $ARCH"

COMMON_PKG="cndrvcups-common_3.21-1_${ARCH}.deb"
CAPT_PKG="cndrvcups-capt_2.71-1_${ARCH}.deb"

# ----------------------------------------------------------------------------
# 1. Зависимости
# ----------------------------------------------------------------------------
log "Установка системных зависимостей (CUPS, ghostscript, libpopt0, usbutils)..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || warn "apt-get update не завершился успешно (офлайн-режим?) — используем доступные пакеты"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        cups cups-client ghostscript libpopt0 usbutils \
        || warn "Некоторые базовые зависимости не установились из репозитория — продолжаем"
    # libglade2-0 доступна в старых дистрибутивах (Astra 1.6/1.7, Ubuntu 20.04/Debian 10)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libglade2-0 2>/dev/null || true
else
    die "Менеджер пакетов apt-get не найден"
fi
command -v lpadmin >/dev/null 2>&1 || die "Команда lpadmin (CUPS) не найдена — проверьте установку cups"

# ----------------------------------------------------------------------------
# 2. Поиск и получение пакетов драйвера
# ----------------------------------------------------------------------------
COMMON_DEB=""
CAPT_DEB=""

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

log "Поиск локальных deb-пакетов драйвера ($COMMON_PKG, $CAPT_PKG)..."
for d in "${CANDIDATE_DIRS[@]}"; do
    if [ -z "$COMMON_DEB" ] && [ -f "$d/$COMMON_PKG" ]; then
        COMMON_DEB="$d/$COMMON_PKG"
    fi
    if [ -z "$CAPT_DEB" ] && [ -f "$d/$CAPT_PKG" ]; then
        CAPT_DEB="$d/$CAPT_PKG"
    fi
done

# Если точных имен нет, ищем любые совместимые cndrvcups*.deb нужной архитектуры
if [ -z "$COMMON_DEB" ] || [ -z "$CAPT_DEB" ]; then
    for d in "${CANDIDATE_DIRS[@]}"; do
        [ -d "$d" ] || continue
        if [ -z "$COMMON_DEB" ]; then
            c=$(find "$d" -maxdepth 2 -name "cndrvcups-common*${ARCH}*.deb" 2>/dev/null | head -1)
            [ -n "$c" ] && COMMON_DEB="$c"
        fi
        if [ -z "$CAPT_DEB" ]; then
            c=$(find "$d" -maxdepth 2 -name "cndrvcups-capt*${ARCH}*.deb" 2>/dev/null | head -1)
            [ -n "$c" ] && CAPT_DEB="$c"
        fi
    done
fi

if [ -n "$COMMON_DEB" ] && [ -n "$CAPT_DEB" ]; then
    ok "Найдены локальные deb-пакеты:"
    ok "  Common: $COMMON_DEB"
    ok "  CAPT:   $CAPT_DEB"
else
    # Скачивание с сервера dist/ (BASE_URL)
    log "Локальные пакеты не найдены в полном объеме, скачиваю с $BASE_URL ..."
    if [ -z "$COMMON_DEB" ]; then
        log "  Загрузка $COMMON_PKG ..."
        if curl -fsSL --connect-timeout 15 --max-time 300 -o "$WORK/$COMMON_PKG" "$BASE_URL/$COMMON_PKG"; then
            COMMON_DEB="$WORK/$COMMON_PKG"
        fi
    fi
    if [ -z "$CAPT_DEB" ]; then
        log "  Загрузка $CAPT_PKG ..."
        if curl -fsSL --connect-timeout 15 --max-time 300 -o "$WORK/$CAPT_PKG" "$BASE_URL/$CAPT_PKG"; then
            CAPT_DEB="$WORK/$CAPT_PKG"
        fi
    fi

    # Фолбэк на архив archive.org и официальные зеркала Canon при необходимости
    if [ -z "$COMMON_DEB" ] || [ -z "$CAPT_DEB" ]; then
        warn "Прямая загрузка .deb не удалась, пробую официальные архивы-зеркала..."
        FALLBACK_URLS=(
            "$ARCHIVE_URL"
            "https://gdlp01.c-wss.com/gds/0/0100004598/04/linux-capt-driver-v271.tar.gz"
            "https://my-cdn.canon-asia.com/OTR/2017/0309/B000885501/linux-capt-driver-v271.tar.gz"
        )
        TAR_FILE="$WORK/canon-capt.tar.gz"
        for u in "${FALLBACK_URLS[@]}"; do
            log "  Пробую зеркало: $u"
            if curl -fsSL --connect-timeout 15 --max-time 600 -o "$TAR_FILE" "$u"; then
                mkdir -p "$WORK/extracted"
                tar -xzf "$TAR_FILE" -C "$WORK/extracted" 2>/dev/null || true
                TARGET_SUBDIR="64-bit_Driver"
                [ "$ARCH" = "i386" ] && TARGET_SUBDIR="32-bit_Driver"
                EXTRACTED_DIR=$(find "$WORK/extracted" -type d -name "$TARGET_SUBDIR" | head -1)
                if [ -n "$EXTRACTED_DIR" ]; then
                    COMMON_DEB=$(find "$EXTRACTED_DIR" -name "cndrvcups-common*.deb" | head -1)
                    CAPT_DEB=$(find "$EXTRACTED_DIR" -name "cndrvcups-capt*.deb" | head -1)
                    [ -n "$COMMON_DEB" ] && [ -n "$CAPT_DEB" ] && break
                fi
            fi
        done
    fi
fi

[ -n "$COMMON_DEB" ] && [ -f "$COMMON_DEB" ] || die "Не удалось найти или скачать пакет $COMMON_PKG"
[ -n "$CAPT_DEB" ] && [ -f "$CAPT_DEB" ] || die "Не удалось найти или скачать пакет $CAPT_PKG"

# ----------------------------------------------------------------------------
# 3. Установка пакетов драйвера
# ----------------------------------------------------------------------------
log "Установка пакета cndrvcups-common..."
dpkg -i "$COMMON_DEB" 2>/dev/null || {
    log "  Доустановка зависимостей common...";
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true;
}

log "Установка пакета cndrvcups-capt..."
dpkg -i "$CAPT_DEB" 2>/dev/null || {
    log "  Доустановка зависимостей capt...";
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true;
}

command -v ccpdadmin >/dev/null 2>&1 || die "ccpdadmin не найден — пакеты драйвера не были корректно установлены"
ok "Пакеты драйвера Canon CAPT успешно установлены"

# ----------------------------------------------------------------------------
# 4. Модуль ядра usblp (создает устройство /dev/usb/lp*)
# ----------------------------------------------------------------------------
log "Настройка модуля ядра usblp..."
modprobe usblp 2>/dev/null || warn "Модуль usblp не удалось загрузить прямо сейчас (возможно, встроен в ядро)"
mkdir -p /etc/modules-load.d
echo "usblp" > /etc/modules-load.d/canon-capt.conf
ok "Модуль usblp закреплен в /etc/modules-load.d/canon-capt.conf"

# ----------------------------------------------------------------------------
# 5. Настройка службы ccpd (СТРОГО ПОСЛЕ cups.service)
# ----------------------------------------------------------------------------
log "Настройка автозапуска службы ccpd строго после cups.service..."
if [ -f /etc/init.d/ccpd ]; then
    chmod +x /etc/init.d/ccpd
    update-rc.d ccpd defaults 2>/dev/null || true
fi

# Создаем systemd unit override для соблюдения порядка запуска After=cups.service
mkdir -p /etc/systemd/system/ccpd.service.d
cat > /etc/systemd/system/ccpd.service.d/override.conf << 'EOF'
[Unit]
Description=Canon CAPT Daemon service
After=cups.service network.target
Wants=cups.service
Requires=cups.service

[Service]
Type=forking
ExecStart=/etc/init.d/ccpd start
ExecStop=/etc/init.d/ccpd stop
Restart=on-failure
RestartSec=3
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# Полноценный unit ccpd.service для надежности на systemd
if [ ! -f /etc/systemd/system/ccpd.service ]; then
    cat > /etc/systemd/system/ccpd.service << 'EOF'
[Unit]
Description=Canon CAPT Daemon service
After=cups.service network.target
Wants=cups.service
Requires=cups.service

[Service]
Type=forking
ExecStart=/etc/init.d/ccpd start
ExecStop=/etc/init.d/ccpd stop
Restart=on-failure
RestartSec=3
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable cups >/dev/null 2>&1 || true
    systemctl enable ccpd >/dev/null 2>&1 || true
    systemctl restart cups
    sleep 1
    systemctl restart ccpd 2>/dev/null || /etc/init.d/ccpd restart 2>/dev/null || true
else
    service cups restart 2>/dev/null || /etc/init.d/cups restart 2>/dev/null || true
    sleep 1
    service ccpd restart 2>/dev/null || /etc/init.d/ccpd restart 2>/dev/null || true
fi
ok "Служба ccpd настроена и связана с cups.service"

# ----------------------------------------------------------------------------
# 6. Создание очереди печати в CUPS
# ----------------------------------------------------------------------------
log "Регистрация очереди $PRINTER в CUPS..."
lpadmin -x "$PRINTER" 2>/dev/null || true

# Поиск PPD файла (в /usr/share/cups/model/ или по системе)
if [ -f "/usr/share/cups/model/$PPD" ]; then
    lpadmin -p "$PRINTER" -m "$PPD" -v ccp://localhost:59787 -E \
        || die "Не удалось создать очередь печати $PRINTER"
else
    PPD_FOUND=$(find /usr/share/cups/model /usr/share/ppd /opt -name "$PPD" 2>/dev/null | head -1)
    if [ -n "$PPD_FOUND" ]; then
        lpadmin -p "$PRINTER" -P "$PPD_FOUND" -v ccp://localhost:59787 -E \
            || die "Не удалось создать очередь печати $PRINTER с PPD $PPD_FOUND"
    else
        lpadmin -p "$PRINTER" -m "$PPD" -v ccp://localhost:59787 -E \
            || die "PPD файл $PPD не найден"
    fi
fi

# Активация очереди
cupsenable "$PRINTER" && cupsaccept "$PRINTER"
ok "Очередь печати $PRINTER создана и включена (cupsenable & cupsaccept)"

# ----------------------------------------------------------------------------
# 7. Автоопределение USB и привязка к ccpdadmin
# ----------------------------------------------------------------------------
log "Определение подключенного USB-устройства..."
LPTDEV=$(ls /dev/usb/lp* 2>/dev/null | head -1)
if [ -n "$LPTDEV" ]; then
    ok "Обнаружен USB-порт принтера: $LPTDEV"
else
    LPTDEV="/dev/usb/lp0"
    warn "Принтер сейчас не подключен по USB. Устанавливаю порт по умолчанию: $LPTDEV"
fi

ccpdadmin -x "$PRINTER" 2>/dev/null || true
ccpdadmin -p "$PRINTER" -o "$LPTDEV"
ok "Очередь $PRINTER привязана к $LPTDEV в ccpdadmin"

# ----------------------------------------------------------------------------
# 8. Создание udev-правила горячего подключения принтера
# ----------------------------------------------------------------------------
log "Настройка udev-правила для горячего подключения Canon CAPT..."
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/85-canon-capt.rules << 'EOF'
# Canon LBP2900 (CAPT) printer hotplug auto-rebind and daemon restart
ACTION=="add", SUBSYSTEM=="usblp", KERNEL=="lp[0-9]*", ATTRS{idVendor}=="04a9", RUN+="/bin/sh -c 'sleep 1; /usr/sbin/ccpdadmin -p LBP2900 -o /dev/%k; /bin/systemctl restart ccpd || /etc/init.d/ccpd restart'"
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="04a9", ATTRS{idProduct}=="110a", RUN+="/bin/sh -c 'sleep 1; DEV=$$(ls /dev/usb/lp* 2>/dev/null | head -1); [ -n \"$$DEV\" ] && /usr/sbin/ccpdadmin -p LBP2900 -o $$DEV; /bin/systemctl restart ccpd || /etc/init.d/ccpd restart'"
EOF

udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
ok "Создано udev-правило /etc/udev/rules.d/85-canon-capt.rules"

# ----------------------------------------------------------------------------
# 9. Финальный перезапуск служб и активация
# ----------------------------------------------------------------------------
log "Перезапуск CUPS и CCPD..."
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl restart cups
    sleep 1
    systemctl restart ccpd 2>/dev/null || /etc/init.d/ccpd restart 2>/dev/null || true
else
    service cups restart 2>/dev/null || /etc/init.d/cups restart 2>/dev/null || true
    sleep 1
    service ccpd restart 2>/dev/null || /etc/init.d/ccpd restart 2>/dev/null || true
fi

cupsenable "$PRINTER" 2>/dev/null || true
cupsaccept "$PRINTER" 2>/dev/null || true

# Добавление пользователя в группу lp
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    usermod -aG lp "$TARGET_USER" 2>/dev/null || true
    ok "Пользователь $TARGET_USER добавлен в группу lp"
fi

# ----------------------------------------------------------------------------
# 10. Проверка готовности
# ----------------------------------------------------------------------------
echo
log "Текущий статус очереди печати:"
lpstat -p "$PRINTER" 2>/dev/null || true

echo
echo -e "${G}================================================================${C0}"
echo -e "${G} Принтер Canon LBP2900 настроен и готов к работе!${C0}"
echo -e "   - Очередь печати: ${B}$PRINTER${C0} (PPD: $PPD)"
echo -e "   - URI порта:      ${B}ccp://localhost:59787${C0}"
echo -e "   - Привязка порта: ${B}$LPTDEV${C0}"
echo -e "   - Автоматический перезапуск при подключении USB настроен (udev)"
echo -e "   - Проверка статуса монитора Canon: ${B}captstatusui -P $PRINTER${C0}"
echo -e "   - Пробная печать: ${B}lp -d $PRINTER /usr/share/cups/data/testprint${C0}"
echo -e "${G}================================================================${C0}"
echo "Сайт проекта: https://biblioteka33.ru/linux"
