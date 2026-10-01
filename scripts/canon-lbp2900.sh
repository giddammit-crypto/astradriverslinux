#!/bin/bash
# ============================================================================
#  canon-lbp2900.sh — драйвер Canon LBP2900 для Astra Linux / Debian / Ubuntu
#
#  Что делает:
#   1) Ставит зависимости (CUPS, ghostscript, libpopt, usbutils, libglade2);
#   2) Ищёт пакеты cndrvcups-common (3.21-1) и cndrvcups-capt (2.71-1) локально
#      в dist/, скачивает с сервера biblioteka33.ru;
#   3) Устанавливает пакеты cndrvcups-common и cndrvcups-capt;
#   4) Загружает модуль ядра usblp и закрепляет его в /etc/modules-load.d/;
#   5) Создает очередь печати: lpadmin -p LBP2900 -m CNCUPSLBP2900CAPTK.ppd
#      -v ccp://localhost:59787 -E, включает cupsenable и cupsaccept;
#   6) Автоматически определяет порт USB (/dev/usb/lp*) и привязывает очередь
#      через ccpdadmin;
#   7) Создаёт udev-правило /etc/udev/rules.d/85-canon-capt.rules;
#   8) Настраивает systemd unit override и сервис ccpd, стартующий после cups;
#   9) Запускает cups и ccpd — принтер СРАЗУ готов к работе.
#
#  Запуск:  sudo bash canon-lbp2900.sh
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

[ "$(id -u)" -eq 0 ] || die "Запустите скрипт с правами суперпользователя: sudo bash $0"

PRINTER="LBP2900"
PPD="CNCUPSLBP2900CAPTK.ppd"
BASE_URL="https://biblioteka33.ru/linux/dist"
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
    i386|i686)    ARCH="i386"  ;;
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
    apt-get update -qq 2>/dev/null || warn "apt-get update не завершился успешно (офлайн?) — используем доступные пакеты"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        cups cups-client ghostscript libpopt0 usbutils \
        || warn "Некоторые базовые зависимости не установились из репозитория — продолжаем"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libglade2-0 2>/dev/null || true
else
    die "Менеджер пакетов apt-get не найден"
fi
command -v lpadmin >/dev/null 2>&1 || die "Команда lpadmin (CUPS) не найдена — проверьте установку cups"

# ----------------------------------------------------------------------------
# 2. Поиск пакетов драйвера
# ----------------------------------------------------------------------------
find_pkg() {
    local name="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || script_dir=""
    for cand in \
        "${script_dir:+$script_dir/../dist/$name}" \
        "${script_dir:+$script_dir/dist/$name}" \
        "/root/$name" \
        "$(pwd)/dist/$name" \
        "$(pwd)/$name"; do
        [ -n "$cand" ] || continue
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

fetch_pkg() {
    local name="$1"
    local dest="$WORK/$name"
    log "Загрузка $name с $BASE_URL..."
    if curl -fsSL --connect-timeout 15 --max-time 180 -o "$dest" "$BASE_URL/$name"; then
        echo "$dest"
        return 0
    fi
    return 1
}

COMMON_PATH=""
if ! COMMON_PATH=$(find_pkg "$COMMON_PKG"); then
    COMMON_PATH=$(fetch_pkg "$COMMON_PKG") || die "Не удалось найти или загрузить $COMMON_PKG"
else
    ok "Найден локальный пакет: $COMMON_PATH"
fi

CAPT_PATH=""
if ! CAPT_PATH=$(find_pkg "$CAPT_PKG"); then
    CAPT_PATH=$(fetch_pkg "$CAPT_PKG") || die "Не удалось найти или загрузить $CAPT_PKG"
else
    ok "Найден локальный пакет: $CAPT_PATH"
fi

patch_cndrv_deb() {
    local src_deb="$1"
    local out_deb="$WORK/patched_$(basename "$src_deb")"
    local tmp_dir="$WORK/unpack_$(basename "$src_deb" .deb)"
    mkdir -p "$tmp_dir"
    dpkg-deb -R "$src_deb" "$tmp_dir" 2>/dev/null || return 1
    local ctrl="$tmp_dir/DEBIAN/control"
    if [ -f "$ctrl" ]; then
        sed -i 's/libcups2 | libcupsys2/libcups2 | libcups2t64 | libcupsys2/g' "$ctrl"
        sed -i 's/libcups2 (>=/libcups2 | libcups2t64 (>=/g' "$ctrl"
        if ! apt-cache show libglade2-0 >/dev/null 2>&1; then
            sed -i 's/libglade2-0 (>= [^)]*),*//g' "$ctrl"
        fi
        sed -i 's/,[[:space:]]*,/,/g; s/Depends:[[:space:]]*,/Depends:/; s/,[[:space:]]*$//' "$ctrl"
    fi
    dpkg-deb -b "$tmp_dir" "$out_deb" >/dev/null 2>&1 || return 1
    rm -rf "$tmp_dir"
    echo "$out_deb"
}

log "Установка cndrvcups-common..."
if ! dpkg -i "$COMMON_PATH" 2>/dev/null; then
    warn "Стандартная установка не удалась — адаптация под версию ОС..."
    PATCHED_COMMON=$(patch_cndrv_deb "$COMMON_PATH") || PATCHED_COMMON="$COMMON_PATH"
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true
    dpkg -i "$PATCHED_COMMON" 2>/dev/null || dpkg -i --force-all "$PATCHED_COMMON" 2>/dev/null || true
fi

log "Установка cndrvcups-capt..."
if ! dpkg -i "$CAPT_PATH" 2>/dev/null; then
    warn "Стандартная установка не удалась — адаптация под версию ОС..."
    PATCHED_CAPT=$(patch_cndrv_deb "$CAPT_PATH") || PATCHED_CAPT="$CAPT_PATH"
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true
    dpkg -i "$PATCHED_CAPT" 2>/dev/null || dpkg -i --force-all "$PATCHED_CAPT" 2>/dev/null || true
fi

ldconfig 2>/dev/null || true
ok "Пакеты Canon CAPT успешно установлены"

# ----------------------------------------------------------------------------
# 4. Модуль ядра usblp
# ----------------------------------------------------------------------------
log "Загрузка модуля ядра usblp..."
if ! lsmod | grep -q usblp 2>/dev/null; then
    modprobe usblp 2>/dev/null || warn "Не удалось загрузить модуль usblp (нормально для некоторых систем)"
fi
echo "usblp" > /etc/modules-load.d/usblp.conf 2>/dev/null || true

for f in /etc/modprobe.d/blacklist-cups.conf /etc/modprobe.d/blacklist.conf; do
    [ -f "$f" ] || continue
    if grep -q 'blacklist usblp' "$f" 2>/dev/null; then
        [ -f "${f}.bak" ] || cp -a "$f" "${f}.bak"
        sed -i 's/^blacklist usblp/# blacklist usblp  # закомментировано installer Canon LBP2900/' "$f"
        ok "Модуль usblp разблокирован в $f"
    fi
done

# ----------------------------------------------------------------------------
# 5. Запуск CUPS
# ----------------------------------------------------------------------------
log "Запуск и активация CUPS..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable cups 2>/dev/null || true
    systemctl start  cups 2>/dev/null || service cups start 2>/dev/null || true
else
    service cups start 2>/dev/null || true
fi

for i in 1 2 3 4 5; do
    if lpstat -r 2>/dev/null | grep -q 'scheduler is running'; then
        ok "Служба CUPS запущена"
        break
    fi
    sleep 1
done

# ----------------------------------------------------------------------------
# 6. Регистрация очереди печати
# ----------------------------------------------------------------------------
log "Регистрация очереди печати $PRINTER..."
lpadmin -x "$PRINTER" 2>/dev/null || true

if lpadmin -p "$PRINTER" -m "$PPD" -v "ccp://localhost:59787" -E -o printer-is-shared=false 2>/dev/null; then
    ok "Очередь $PRINTER создана через ccpd-порт 59787"
else
    warn "Не удалось зарегистрировать очередь через lpadmin -m (PPD не найден в базе). Пробуем прямой путь..."
    PPD_PATH=$(find /usr/share/cups/model -name "$PPD" 2>/dev/null | head -1)
    if [ -n "$PPD_PATH" ]; then
        lpadmin -p "$PRINTER" -P "$PPD_PATH" -v "ccp://localhost:59787" -E -o printer-is-shared=false
    else
        err "PPD-файл $PPD не найден — очередь не создана"
    fi
fi

cupsenable  "$PRINTER" 2>/dev/null || true
cupsaccept  "$PRINTER" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 7. Определение USB-порта и настройка ccpdadmin
# ----------------------------------------------------------------------------
log "Поиск USB-порта принтера Canon..."
LP_DEV=""
for dev in /dev/usb/lp0 /dev/usb/lp1 /dev/usblp0 /dev/usblp1; do
    if [ -c "$dev" ]; then
        LP_DEV="$dev"
        ok "Обнаружен USB-порт: $LP_DEV"
        break
    fi
done

if [ -n "$LP_DEV" ]; then
    if command -v ccpdadmin >/dev/null 2>&1; then
        ccpdadmin -p "$PRINTER" -o "$LP_DEV" 2>/dev/null || warn "ccpdadmin: ошибка привязки порта (нормально при первом запуске)"
    fi
else
    warn "USB-порт принтера не обнаружен. Подключите Canon LBP2900 и перезапустите ccpd."
fi

# ----------------------------------------------------------------------------
# 8. udev-правило для горячего подключения
# ----------------------------------------------------------------------------
cat > /etc/udev/rules.d/85-canon-capt.rules << 'UDEV'
# Canon LBP2900 — автоматическая активация при подключении по USB
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="04a9", \
    RUN+="/bin/systemctl restart ccpd", \
    RUN+="/usr/sbin/cupsenable LBP2900", \
    RUN+="/usr/sbin/cupsaccept LBP2900"
UDEV
udevadm control --reload-rules 2>/dev/null || true
ok "udev-правило создано: /etc/udev/rules.d/85-canon-capt.rules"

# ----------------------------------------------------------------------------
# 9. Служба ccpd
# ----------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    log "Настройка системной службы ccpd..."
    mkdir -p /etc/systemd/system/ccpd.service.d
    cat > /etc/systemd/system/ccpd.service.d/after-cups.conf << 'UNIT'
[Unit]
After=cups.service
Requires=cups.service

[Service]
Restart=on-failure
RestartSec=3
UNIT
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable ccpd 2>/dev/null || true
    systemctl restart ccpd 2>/dev/null || {
        warn "Не удалось запустить ccpd через systemctl. Пробуем через service..."
        service ccpd restart 2>/dev/null || warn "Служба ccpd не запустилась — подключите принтер и перезагрузите систему"
    }
else
    service ccpd restart 2>/dev/null || true
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [ -n "$REAL_USER" ] && id "$REAL_USER" >/dev/null 2>&1; then
    usermod -aG lp,lpadmin "$REAL_USER" 2>/dev/null || true
    ok "Пользователь '$REAL_USER' добавлен в группы lp, lpadmin"
fi

# ----------------------------------------------------------------------------
# 10. Финальная проверка
# ----------------------------------------------------------------------------
sleep 2
echo
if lpstat -p "$PRINTER" >/dev/null 2>&1; then
    ok "Очередь '$PRINTER' зарегистрирована и готова к печати!"
    echo -e "   Тест: ${B}lp -d $PRINTER /etc/issue${C0}"
else
    warn "Очередь ещё не видна в CUPS. Перезапустите систему или выполните: sudo systemctl restart cups ccpd"
fi

echo
echo -e "${G}Готово!${C0} Canon LBP2900 полностью настроен."
echo "Сайт проекта: https://biblioteka33.ru/linux"
