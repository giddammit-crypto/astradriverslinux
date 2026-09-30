#!/bin/bash
# ============================================================================
#  nelrf-fix.sh — исправление запуска просмотрщика НЭБ РФ (ЭЛАР NEL RF)
#  для Astra Linux (1.6/1.7/1.8 Fly DE), Ubuntu (20.04–26.04) и Debian (10–13).
#
#  Запуск:   ./nelrf-fix.sh [-d /путь/к/приложению] [-y] [--no-test]
#  Сайт:     https://biblioteka33.ru/linux
# ============================================================================
set -euo pipefail

APP=""
YES=0
NOTEST=0
FIXED=0
BASE_URL="https://biblioteka33.ru/linux/dist"
RUNFILE="nebviewer-linux-x86_64.run"

C0='\033[0m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[1;34m'
if [ ! -t 1 ]; then C0=''; G=''; Y=''; R=''; B=''; fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }
die()  { err "$*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -d) APP="$2"; shift 2 ;;
        -y|--yes) YES=1; shift ;;
        --no-test) NOTEST=1; shift ;;
        -h|--help) echo "Использование: $0 [-d /путь/к/elar] [-y] [--no-test]"; exit 0 ;;
        *) err "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

# Поиск каталога установки
if [ -z "${APP:-}" ]; then
    for candidate in \
        "$HOME/.local/opt/elar" "$HOME/elar" "$HOME/.elar" \
        "/opt/elar" "/usr/local/opt/elar"; do
        if [ -d "$candidate" ]; then
            APP="$candidate"
            ok "НЭБ РФ найдена: $APP"
            break
        fi
    done
fi

# Установка НЭБ РФ если не найдена
if [ -z "${APP:-}" ] || [ ! -d "${APP:-}" ]; then
    log "Приложение НЭБ РФ не найдено. Запускаем установку..."
    RUN_PATH=""
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
    for cand in \
        "${SCRIPT_DIR:+$SCRIPT_DIR/../dist/$RUNFILE}" \
        "${SCRIPT_DIR:+$SCRIPT_DIR/$RUNFILE}" \
        "$HOME/Downloads/$RUNFILE" "$HOME/Загрузки/$RUNFILE" "$(pwd)/$RUNFILE"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { RUN_PATH="$cand"; ok "Локальный дистрибутив: $RUN_PATH"; break; } || true
    done

    if [ -z "${RUN_PATH:-}" ]; then
        log "Загрузка дистрибутива НЭБ РФ..."
        TMPRUN="$(mktemp /tmp/nebviewer-XXXXXX.run)"
        if curl -fsSL --connect-timeout 20 --max-time 600 "${BASE_URL}/${RUNFILE}" -o "$TMPRUN"; then
            RUN_PATH="$TMPRUN"; ok "Дистрибутив загружен"
        else
            rm -f "$TMPRUN" || true
            die "Не удалось загрузить ${RUNFILE}."
        fi
    fi

    APP="$HOME/.local/opt/elar"
    mkdir -p "$APP"
    chmod +x "$RUN_PATH"
    log "Установка НЭБ РФ в $APP ..."
    INSTALL_DIR="$APP" bash "$RUN_PATH" --noexec --keep --target "$APP" 2>/dev/null \
        || bash "$RUN_PATH" 2>/dev/null \
        || warn "Автоматическая установка завершилась с предупреждением"
fi

[ -d "${APP:-}" ] || die "Каталог аппликации АНЭ РФ не найден. Укажите путь: $0 -d /путь/к/elar"
log "Работаем с каталогом: $APP"

# 1. Лаунчер
BIN_DIR="$APP/bin"; mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/nelrfviewer-launcher.sh"
cat > "$LAUNCHER" << LAUNCHER_SCRIPT
#!/bin/bash
export LD_LIBRARY_PATH="$APP/lib:\${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="$APP/bin"
export QT_QPA_PLATFORM=xcb
export QT_SCALE_FACTOR=1
cd "$APP"
if [ -x "$APP/bin/elar-nelrfviewer" ]; then exec "$APP/bin/elar-nelrfviewer" "\$@"
elif [ -x "$APP/elar-nelrfviewer" ]; then exec "$APP/elar-nelrfviewer" "\$@"
elif [ -f "$APP/elar-nelrfviewer.sh" ]; then exec bash "$APP/elar-nelrfviewer.sh" "\$@"
else echo "Ошибка: исполняемый файл НЭБ РФ не найден в $APP" >&2; exit 1
fi
LAUNCHER_SCRIPT
chmod +x "$LAUNCHER"
ok "Лаунчер: $LAUNCHER"; FIXED=$((FIXED+1))

# 2. Исправление elar-nelrfviewer.sh
if [ -f "$APP/elar-nelrfviewer.sh" ]; then
    [ -f "$APP/elar-nelrfviewer.sh.bak" ] || cp -a "$APP/elar-nelrfviewer.sh" "$APP/elar-nelrfviewer.sh.bak"
    sed -i "s|^APP=.*|APP=\"$APP\"|" "$APP/elar-nelrfviewer.sh" 2>/dev/null || true
    ok "elar-nelrfviewer.sh обновлён"; FIXED=$((FIXED+1))
fi

# 3. Библиотеки
LIBDIR="$APP/lib"; mkdir -p "$LIBDIR"
if [ ! -f "$LIBDIR/libxml2.so.2" ]; then
    SYS_XML2=$(find /usr/lib/x86_64-linux-gnu /usr/lib /lib -name 'libxml2.so.2*' -type f 2>/dev/null | head -1) || true
    [ -n "${SYS_XML2:-}" ] && cp "$SYS_XML2" "$LIBDIR/libxml2.so.2" && ok "libxml2.so.2 скопирована" && FIXED=$((FIXED+1)) || true
fi
if [ ! -f "$LIBDIR/libssl.so.1.0.0" ] && [ ! -f "$LIBDIR/libssl.so.10" ]; then
    SSL10=$(find /usr/lib/x86_64-linux-gnu /usr/lib /lib -name 'libssl.so.1.0.*' -o -name 'libssl.so.10' 2>/dev/null | head -1) || true
    [ -n "${SSL10:-}" ] && cp "$SSL10" "$LIBDIR/" && ok "OpenSSL 1.0: $(basename "$SSL10")" && FIXED=$((FIXED+1)) || true
fi

# 4. Иконка
ICON_SRC=$(find "$APP" -name '*.png' -path '*/icons/*' 2>/dev/null | head -1) || true
if [ -n "${ICON_SRC:-}" ]; then
    ICON_DST="$HOME/.local/share/icons/hicolor/128x128/apps"
    mkdir -p "$ICON_DST"
    cp "$ICON_SRC" "$ICON_DST/elar-nelrfviewer.png" 2>/dev/null || true
    ok "Иконка установлена"
fi

# 5. Ярлыки
DESKTOP_CONTENT="[Desktop Entry]
Version=1.0
Type=Application
Name=НЭБ РФ
Name[ru]=НЭБ РФ
GenericName=Просмотрщик НЭБ РФ
Comment=Национальная электронная библиотека (ЭЛАР)
Exec=bash $LAUNCHER %F
Icon=elar-nelrfviewer
Terminal=false
Categories=Office;Viewer;
MimeType=application/x-neb;
StartupNotify=true
"
APPS_DIR="$HOME/.local/share/applications"; mkdir -p "$APPS_DIR"
echo "$DESKTOP_CONTENT" > "$APPS_DIR/elar-nelrfviewer.desktop"
chmod +x "$APPS_DIR/elar-nelrfviewer.desktop" 2>/dev/null || true
command -v gio >/dev/null 2>&1 && gio set "$APPS_DIR/elar-nelrfviewer.desktop" metadata::trusted true 2>/dev/null || true
ok "Ярлык в меню: $APPS_DIR/elar-nelrfviewer.desktop"

for desktop_dir in "$HOME/Рабочий стол" "$HOME/Desktop" "$HOME/Рабочий_стол"; do
    if [ -d "$desktop_dir" ]; then
        echo "$DESKTOP_CONTENT" > "$desktop_dir/elar-nelrfviewer.desktop"
        chmod +x "$desktop_dir/elar-nelrfviewer.desktop" 2>/dev/null || true
        command -v gio >/dev/null 2>&1 && gio set "$desktop_dir/elar-nelrfviewer.desktop" metadata::trusted true 2>/dev/null || true
        ok "Ярлык на рабочем столе: $desktop_dir"; break
    fi
done
FIXED=$((FIXED+1))

# 6. Тестовый запуск
if [ "$NOTEST" -eq 0 ]; then
    log "Тестовый запуск НЭБ РФ..."
    EXIT_CODE=0
    timeout 5 bash "$LAUNCHER" --version 2>/dev/null || EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 0 ] || [ "$EXIT_CODE" -eq 124 ]; then
        ok "Приложение запускается корректно"
    else
        warn "Тест вернул $EXIT_CODE. Запустите вручную: bash $LAUNCHER"
    fi
fi

echo
echo -e "${G}Готово!${C0} НЭБ РФ настроен."
echo -e "   Исправлений/действий: ${B}$FIXED${C0}"
echo -e "   Запуск: bash $LAUNCHER"
echo    "   Сайт: https://biblioteka33.ru/linux"
