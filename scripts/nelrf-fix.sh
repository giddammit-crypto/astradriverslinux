#!/bin/bash
# ============================================================================
#  nelrf-fix.sh — исправление запуска просмотрщика НЭБ РФ (ЭЛАР NEL RF)
#  для Astra Linux (1.6/1.7/1.8 Fly DE), Ubuntu (20.04/22.04/24.04/26.04) и Debian (10/11/12/13).
#
#  Что делает:
#   0) Если приложение еще не установлено — находит nebviewer-linux-x86_64.run
#      (локально в dist/, рядом со скриптом, в Загрузках или на biblioteka33.ru)
#      и устанавливает программу в ~/.local/opt/elar БЕЗ прав root;
#   1) Создает надежный бинарный лаунчер bin/nelrfviewer-launcher.sh
#      (экспорт LD_LIBRARY_PATH="$APP/lib:$LD_LIBRARY_PATH", QT_PLUGIN_PATH="$APP/bin",
#      QT_QPA_PLATFORM=xcb) и исправляет ошибки путей в elar-nelrfviewer.sh;
#   2) Ищет недостающие динамические библиотеки (libxml2.so.2, ICU, OpenSSL 1.0)
#      и докладывает их в lib/ приложения без изменения системных пакетов;
#   3) Устанавливает иконки в ~/.local/share/icons/hicolor/128x128/apps/;
#   4) Создает корректные ярлыки «НЭБ РФ» с точным путем к иконке и правами запуска:
#      - ~/Рабочий стол/elar-nelrfviewer.desktop (для русскоязычной Astra Linux Fly DE)
#      - ~/Desktop/elar-nelrfviewer.desktop (для Ubuntu / Debian)
#      - ~/.local/share/applications/elar-nelrfviewer.desktop (меню «Пуск» / приложений)
#      Выставляет chmod +x и gio set metadata::trusted true;
#   5) Выполняет контрольный тестовый запуск.
#
#  Запуск:   ./nelrf-fix.sh [-d /путь/к/приложению] [-y] [--no-test]
#  Сайт:     https://biblioteka33.ru/linux
# ============================================================================
set -o pipefail

APP=""          # каталог приложения (переопределяется ключом -d)
YES=0           # -y: не спрашивать подтверждения
NOTEST=0        # --no-test: пропустить тестовый запуск
MANUAL=()       # библиотеки, которые не удалось получить автоматически
FIXED=0
BASE_URL="https://biblioteka33.ru/linux/dist"   # URL дистрибутивов
RUNFILE="nebviewer-linux-x86_64.run"

C0='\033[0m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[1;34m'
if [ ! -t 1 ]; then
    C0=''; G=''; Y=''; R=''; B=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }
die()  { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# Разбор аргументов командной строки
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -d) APP="$2"; shift 2 ;;
        -y|--yes) YES=1; shift ;;
        --no-test) NOTEST=1; shift ;;
        -h|--help)
            echo "Использование: $0 [-d /путь/к/elar] [-y] [--no-test]"
            exit 0
            ;;
        *) err "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

# Определение пользователя для ярлыков и каталога установки
TARGET_USER="${SUDO_USER:-$USER}"
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
        if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
            HOME="$TARGET_HOME"
            log "Скрипт запущен через sudo. Настройка для пользователя: $TARGET_USER (домашний каталог: $HOME)"
        fi
    else
        warn "Скрипт запущен от root без SUDO_USER. Ярлыки будут созданы в /root/."
        warn "Для создания ярлыков на рабочем столе пользователя рекомендуется запуск БЕЗ sudo."
    fi
fi

# Определение дистрибутива
. /etc/os-release 2>/dev/null || true
if grep -qiE "astra" /etc/os-release 2>/dev/null; then
    log "Обнаружена Astra Linux: ${PRETTY_NAME:-Astra Linux}"
else
    log "Дистрибутив: ${PRETTY_NAME:-неизвестный}"
fi

# ----------------------------------------------------------------------------
# 1. Поиск существующего каталога приложения
# ----------------------------------------------------------------------------
desktop_scan() {
    # Извлечение пути к каталогу приложения из существующих .desktop файлов
    local f tok dir
    for f in "$HOME/.local/share/applications/"*elar*.desktop \
             "$HOME/Рабочий стол/"*.desktop \
             "$HOME/Desktop/"*.desktop \
             /usr/share/applications/*elar*.desktop; do
        [ -f "$f" ] || continue
        grep -qi "nelrfviewer" "$f" || continue
        tok=$(grep -m1 "^Exec=" "$f" | sed 's/^Exec=//; s/ %u.*//; s/ %U.*//')
        [ -n "$tok" ] || continue
        tok="${tok%% *}"
        [ -e "$tok" ] || continue
        dir=$(dirname "$(readlink -f "$tok")")   # .../bin
        if [ -x "$dir/nelrfviewer" ]; then
            echo "$(dirname "$dir")"
            return 0
        fi
    done
    return 1
}

if [ -z "$APP" ]; then
    for d in "$HOME/.local/opt/elar" \
             "$HOME/.local/opt/elar/elar-nelrfviewer-deployed" \
             /opt/elar/nelrfviewer \
             /opt/elar/nelrfviewer-deployed \
             /opt/elar-nelrfviewer-deployed \
             "$HOME/Загрузки/elar-nelrfviewer-deployed" \
             "$HOME/Downloads/elar-nelrfviewer-deployed"; do
        [ -x "$d/bin/nelrfviewer" ] && APP="$d" && break
    done
    [ -z "$APP" ] && APP=$(desktop_scan)
fi

# ----------------------------------------------------------------------------
# 2. Установка из nebviewer-linux-x86_64.run, если приложение не найдено
# ----------------------------------------------------------------------------
install_from_run() {
    local src="" cand target
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

    CANDIDATES=(
        "$script_dir/../dist/$RUNFILE"
        "$script_dir/dist/$RUNFILE"
        "$script_dir/$RUNFILE"
        "/home/astra/vint2/linux/dist/$RUNFILE"
        "$(pwd)/dist/$RUNFILE"
        "$(pwd)/$RUNFILE"
        "$HOME/Загрузки/$RUNFILE"
        "$HOME/Downloads/$RUNFILE"
    )

    for cand in "${CANDIDATES[@]}"; do
        if [ -f "$cand" ]; then
            src="$cand"
            break
        fi
    done

    if [ -z "$src" ]; then
        target="$HOME/.cache/astra-helper/$RUNFILE"
        mkdir -p "$(dirname "$target")"
        log "Скачиваю установщик НЭБ РФ: $BASE_URL/$RUNFILE ..."
        if curl -fSL --connect-timeout 15 --max-time 1800 -o "$target.part" "$BASE_URL/$RUNFILE" \
           && mv "$target.part" "$target"; then
            src="$target"
        else
            rm -f "$target.part"
            return 1
        fi
    fi

    ok "Установщик найден: $src"
    target="$HOME/.local/opt/elar"
    mkdir -p "$target"
    log "Распаковка в $target (без root)..."
    # --nox11: предотвращает открытие xterm; --noexec: ярлыки и лаунчер настраиваем сами ниже
    sh "$src" --nox11 --target "$target" --noexec >/dev/null 2>&1 || return 1
    [ -x "$target/bin/nelrfviewer" ] || return 1
    APP="$target"
    ok "Приложение успешно распаковано: $APP"
    INSTALLED=1
    return 0
}

INSTALLED=0
if [ -z "$APP" ] || [ ! -x "$APP/bin/nelrfviewer" ]; then
    log "Приложение НЭБ РФ не найдено — выполняю установку..."
    if ! install_from_run; then
        die "Не удалось установить НЭБ РФ автоматически. Скачайте $RUNFILE и укажите: $0 -d /путь/к/приложению"
    fi
fi

BIN="$APP/bin"
LIB="$APP/lib"
mkdir -p "$BIN" "$LIB"
ok "Каталог приложения: $APP"

# ----------------------------------------------------------------------------
# 3. Создание надежного бинарного лаунчера bin/nelrfviewer-launcher.sh
#    (Экспорт LD_LIBRARY_PATH, QT_PLUGIN_PATH, QT_QPA_PLATFORM=xcb)
# ----------------------------------------------------------------------------
log "Создание бинарного лаунчера bin/nelrfviewer-launcher.sh..."
cat > "$BIN/nelrfviewer-launcher.sh" << 'EOF'
#!/bin/bash
# ============================================================================
#  nelrfviewer-launcher.sh — надежный запуск просмотрщика НЭБ РФ
# ============================================================================
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Библиотеки приложения имеют приоритет
export LD_LIBRARY_PATH="$APP_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Плагины Qt лежат в каталоге bin/ (platforms, imageformats, etc.)
export QT_PLUGIN_PATH="$APP_DIR/bin"

# Принудительное использование X11 (xcb) для полной совместимости с Fly DE и Wayland/XWayland
export QT_QPA_PLATFORM=xcb

# Экспорт системных сертификатов CA для OpenSSL 1.0.0
# Без этого авторизация и подключение к https://access.rusneb.ru и https://relar.rsl.ru завершаются ошибкой SSL
if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
elif [ -f /etc/pki/tls/certs/ca-bundle.crt ]; then
    export SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
fi
if [ -d /etc/ssl/certs ]; then
    export SSL_CERT_DIR=/etc/ssl/certs
fi
export OPENSSL_DIR=/etc/ssl

exec "$APP_DIR/bin/nelrfviewer" "$@"
EOF
chmod +x "$BIN/nelrfviewer-launcher.sh"
WRAPPER="$BIN/nelrfviewer-launcher.sh"

# Симлинк для обратной совместимости
ln -sf "nelrfviewer-launcher.sh" "$BIN/nelrfviewer-launch.sh"

# Исправление elar-nelrfviewer.sh (в оригинале проверял несуществующий ../plugins)
if [ -f "$BIN/elar-nelrfviewer.sh" ]; then
    cp -a "$BIN/elar-nelrfviewer.sh" "$BIN/elar-nelrfviewer.sh.bak" 2>/dev/null || true
    sed -i 's|QT5_PLUGINS_DIR=.*|QT5_PLUGINS_DIR="${START_PATH}"|g' "$BIN/elar-nelrfviewer.sh"
    grep -q "QT_QPA_PLATFORM" "$BIN/elar-nelrfviewer.sh" || sed -i '/export QT_PLUGIN_PATH/a export QT_QPA_PLATFORM=xcb' "$BIN/elar-nelrfviewer.sh"
    grep -q "SSL_CERT_FILE" "$BIN/elar-nelrfviewer.sh" || sed -i '/export QT_QPA_PLATFORM/a [ -f /etc/ssl/certs/ca-certificates.crt ] && export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt; [ -d /etc/ssl/certs ] && export SSL_CERT_DIR=/etc/ssl/certs; export OPENSSL_DIR=/etc/ssl' "$BIN/elar-nelrfviewer.sh"
    chmod +x "$BIN/elar-nelrfviewer.sh"
    ok "Исправлены пути к плагинам и SSL в $BIN/elar-nelrfviewer.sh"
fi

# Исправление integrate-to-DE.sh (в оригинале прописывал путь к nelrfviewer без библиотек)
if [ -f "$BIN/integrate-to-DE.sh" ]; then
    sed -i 's|/nelrfviewer %u|/nelrfviewer-launcher.sh %u|g' "$BIN/integrate-to-DE.sh"
    sed -i 's|/nelrfviewer"|/nelrfviewer-launcher.sh"|g' "$BIN/integrate-to-DE.sh"
fi

# Настройка qt.conf в bin/
cat > "$BIN/qt.conf" << 'EOF'
[Paths]
Prefix=.
Plugins=.
EOF
ok "Создан конфигурационный файл Qt: $BIN/qt.conf"

# ----------------------------------------------------------------------------
# 4. Диагностика и восстановление разделяемых библиотек в lib/
# ----------------------------------------------------------------------------
export LD_LIBRARY_PATH="$LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

missing_of() {
    ldd "$1" 2>/dev/null | grep -iE "not found|не найден" | awk '{print $1}' | sort -u
}

guess_pkg() {
    case "$1" in
        libxml2.so.*)                   echo "libxml2" ;;
        libicu*.so.*)                   echo "libicu${1##*.so.}" ;;
        libssl.so.1.1|libcrypto.so.1.1) echo "libssl1.1" ;;
        libssl.so.1.0*|libcrypto.so.1.0*) echo "libssl1.0.0" ;;
        libpng16.so.*)                  echo "libpng16-16" ;;
        libjpeg.so.8)                   echo "libjpeg8" ;;
        *)                              echo "" ;;
    esac
}

install_deb_into_lib() {
    local deb_path="$1"
    local t extra=""
    case "$SONAME" in
        libssl.so.*)  extra="libcrypto.so.${SONAME#libssl.so.}" ;;
        libicu*.so.*) extra="libicu*.so.${SONAME##*.so.}" ;;
    esac

    t=$(mktemp -d /tmp/deb-extract-XXXXXX)
    if ! dpkg-deb -x "$deb_path" "$t" 2>/dev/null; then
        rm -rf "$t"
        return 1
    fi

    # Копируем и обычные файлы, и симлинки
    find "$t" \( -type f -o -type l \) \( -name "$SONAME" -o -name "$SONAME.*" \
        ${extra:+-o -name "$extra" -o -name "$extra.*"} \) \
        -exec cp -a {} "$LIB/" \; 2>/dev/null

    # Исправление относительных битых симлинков внутри $LIB
    for link in "$LIB/$SONAME" ${extra:+"$LIB/$extra"}; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            local tgt; tgt=$(readlink "$link")
            local base_tgt; base_tgt=$(basename "$tgt")
            if [ -f "$LIB/$base_tgt" ]; then
                ln -sf "$base_tgt" "$link"
            fi
        fi
    done

    rm -rf "$t"
    [ -e "$LIB/$SONAME" ]
}

fetch_lib() {
    local soname="$1"
    SONAME="$soname"
    local pkg deb
    pkg=$(guess_pkg "$SONAME")
    log "Поиск и восстановление библиотеки $SONAME (пакет: ${pkg:-неизвестен})..."

    # 1. Поиск в локальных каталогах dist/
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    for d in "$script_dir/../dist" "$script_dir/dist" "/home/astra/vint2/linux/dist" "$(pwd)/dist" "$(pwd)"; do
        [ -d "$d" ] || continue
        # Проверяем готовые .so файлы
        local found_so
        found_so=$(find "$d" -name "$SONAME*" 2>/dev/null | head -1)
        if [ -n "$found_so" ]; then
            cp -a "$found_so" "$LIB/" && [ -e "$LIB/$SONAME" ] && return 0
        fi
        # Проверяем .deb файлы
        if [ -n "$pkg" ]; then
            local found_deb
            found_deb=$(find "$d" -name "${pkg}*.deb" 2>/dev/null | head -1)
            if [ -n "$found_deb" ]; then
                install_deb_into_lib "$found_deb" && return 0
            fi
        fi
    done

    # 2. Попытка apt-get download (локальный репозиторий / диск Astra)
    if [ -n "$pkg" ] && command -v apt-get >/dev/null 2>&1; then
        local dl_tmp
        dl_tmp=$(mktemp -d /tmp/apt-dl-XXXXXX)
        if (cd "$dl_tmp" && apt-get download "$pkg" >/dev/null 2>&1); then
            local got=0
            for f in "$dl_tmp"/*.deb; do
                [ -f "$f" ] || continue
                if install_deb_into_lib "$f"; then got=1; fi
            done
            rm -rf "$dl_tmp"
            [ "$got" -eq 1 ] && return 0
        else
            rm -rf "$dl_tmp"
        fi
    fi

    # 3. Скачивание пакета с зеркал
    case "$pkg" in
        libxml2)
            for url in \
                "$BASE_URL/libxml2_2.9.13+dfsg-1build1_amd64.deb" \
                "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.13+dfsg-1build1_amd64.deb" \
                "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.10+dfsg-5_amd64.deb" \
                "http://security.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_amd64.deb"; do
                deb=$(mktemp /tmp/libxml2-XXXXXX.deb)
                if curl -fsSL --connect-timeout 10 --max-time 60 -o "$deb" "$url" && install_deb_into_lib "$deb"; then
                    rm -f "$deb"; return 0
                fi
                rm -f "$deb"
            done
            ;;
        libicu66)
            for url in \
                "$BASE_URL/libicu66_66.1-2ubuntu2_amd64.deb" \
                "http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu66_66.1-2ubuntu2_amd64.deb"; do
                deb=$(mktemp /tmp/libicu66-XXXXXX.deb)
                if curl -fsSL --connect-timeout 10 --max-time 60 -o "$deb" "$url" && install_deb_into_lib "$deb"; then
                    rm -f "$deb"; return 0
                fi
                rm -f "$deb"
            done
            ;;
        libicu70)
            for url in \
                "$BASE_URL/libicu70_70.1-2_amd64.deb" \
                "http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu70_70.1-2_amd64.deb"; do
                deb=$(mktemp /tmp/libicu70-XXXXXX.deb)
                if curl -fsSL --connect-timeout 10 --max-time 60 -o "$deb" "$url" && install_deb_into_lib "$deb"; then
                    rm -f "$deb"; return 0
                fi
                rm -f "$deb"
            done
            ;;
        libssl1.0.0)
            for url in \
                "$BASE_URL/libssl1.0.0_1.0.2n-1ubuntu6.2_amd64.deb" \
                "http://old-releases.ubuntu.com/ubuntu/pool/main/o/openssl1.0/libssl1.0.0_1.0.2n-1ubuntu6.2_amd64.deb" \
                "http://archive.ubuntu.com/ubuntu/pool/main/o/openssl1.0/libssl1.0.0_1.0.2n-1ubuntu5.3_amd64.deb" \
                "http://snapshot.debian.org/archive/debian/20190123T033924Z/pool/main/o/openssl1.0/libssl1.0.0_1.0.2r-1~deb9u1_amd64.deb"; do
                deb=$(mktemp /tmp/libssl100-XXXXXX.deb)
                if curl -fsSL --connect-timeout 10 --max-time 60 -o "$deb" "$url" && install_deb_into_lib "$deb"; then
                    rm -f "$deb"; return 0
                fi
                rm -f "$deb"
            done
            ;;
    esac

    # 4. Поиск по всему каталогу приложения
    local alt
    alt=$(find "$APP" -name "$SONAME*" -not -path "*/lib/*" 2>/dev/null | head -1)
    if [ -n "$alt" ]; then
        cp -a "$alt" "$LIB/" && return 0
    fi

    MANUAL+=("$SONAME")
    return 1
}

# Доустановка отсутствующих библиотек (в несколько проходов для зависимостей второго уровня)
log "Проверка зависимостей приложения..."
for pass in 1 2 3; do
    MISSING=$(missing_of "$BIN/nelrfviewer")
    if [ -f "$BIN/platforms/libqxcb.so" ]; then
        M2=$(missing_of "$BIN/platforms/libqxcb.so")
        [ -n "$M2" ] && MISSING=$(printf '%s\n%s\n' "$MISSING" "$M2" | sort -u | sed '/^$/d')
    fi
    [ -z "$MISSING" ] && break

    [ "$pass" -gt 1 ] && log "Проход $pass: проверка появившихся вторичных зависимостей..."
    while read -r so; do
        [ -n "$so" ] || continue
        if fetch_lib "$so"; then
            ok "Библиотека $so успешно добавлена в $LIB"
            FIXED=$((FIXED+1))
        else
            warn "Библиотеку $so не удалось получить автоматически"
        fi
    done <<< "$MISSING"
done

# Особая обработка OpenSSL 1.0 (Qt Network загружает через dlopen, ldd его не видит)
if [ ! -e "$LIB/libssl.so.1.0.0" ] && [ ! -e /usr/lib/x86_64-linux-gnu/libssl.so.1.0.0 ]; then
    log "Проверка OpenSSL 1.0 (требуется для HTTPS в просмотрщике НЭБ)..."
    if fetch_lib "libssl.so.1.0.0"; then
        ok "Библиотеки OpenSSL 1.0 (libssl/libcrypto) добавлены в $LIB"
    else
        warn "OpenSSL 1.0 не найден — возможна ошибка «Не удается подключиться к серверу» при загрузке книг"
    fi
fi

# Создание симлинков libssl.so / libcrypto.so при необходимости
if [ -f "$LIB/libssl.so.1.0.0" ]; then
    ln -sf "libssl.so.1.0.0" "$LIB/libssl.so"
    ln -sf "libssl.so.1.0.0" "$LIB/libssl.so.10"
fi
if [ -f "$LIB/libcrypto.so.1.0.0" ]; then
    ln -sf "libcrypto.so.1.0.0" "$LIB/libcrypto.so"
    ln -sf "libcrypto.so.1.0.0" "$LIB/libcrypto.so.10"
fi

# ----------------------------------------------------------------------------
# 5. Установка иконок приложения
# ----------------------------------------------------------------------------
log "Установка иконок приложения..."
ICON_TARGET_DIR="$HOME/.local/share/icons/hicolor/128x128/apps"
mkdir -p "$ICON_TARGET_DIR"

# Поиск лучшей иконки 128x128
SRC_ICON=""
for icand in "$APP/share/elar-nelrfviewer-128.png" \
            "$APP/share/elar-nelrfviewer.png" \
            "$APP/share/elar-nelrfviewer-64.png"; do
    if [ -f "$icand" ]; then
        SRC_ICON="$icand"
        break
    fi
done

if [ -n "$SRC_ICON" ]; then
    cp -a "$SRC_ICON" "$ICON_TARGET_DIR/elar-nelrfviewer.png"
    ICON_FILE="$ICON_TARGET_DIR/elar-nelrfviewer.png"
    ok "Иконка скопирована в $ICON_FILE"
else
    ICON_FILE="elar-nelrfviewer"
    warn "Исходная иконка в $APP/share не найдена, используем системное имя"
fi

# Установка иконок других размеров, если имеются
if [ -d "$APP/share" ]; then
    for size in 16 32 48 64 128; do
        if [ -f "$APP/share/elar-nelrfviewer-${size}.png" ]; then
            mkdir -p "$HOME/.local/share/icons/hicolor/${size}x${size}/apps"
            cp -a "$APP/share/elar-nelrfviewer-${size}.png" "$HOME/.local/share/icons/hicolor/${size}x${size}/apps/elar-nelrfviewer.png"
        fi
    done
fi

if command -v xdg-icon-resource >/dev/null 2>&1 && [ -f "$ICON_TARGET_DIR/elar-nelrfviewer.png" ]; then
    xdg-icon-resource install --context apps --size 128 "$ICON_TARGET_DIR/elar-nelrfviewer.png" elar-nelrfviewer 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 6. Создание ярлыков на Рабочем столе и в меню приложений
# ----------------------------------------------------------------------------
log "Создание ярлыков запуска..."

# Шаблон содержимого .desktop файла с точным путем к иконке и лаунчеру
DESKTOP_CONTENT="[Desktop Entry]
Type=Application
Version=1.0
Name=НЭБ РФ
Name[ru]=НЭБ РФ
GenericName=Просмотрщик книг из НЭБ РФ
GenericName[ru]=Просмотрщик книг из НЭБ РФ
Comment=Просмотр книг из Национальной Электронной Библиотеки РФ
Comment[ru]=Просмотр книг из Национальной Электронной Библиотеки РФ
TryExec=$WRAPPER
Exec=$WRAPPER %u
Icon=$ICON_FILE
Terminal=false
MimeType=x-scheme-handler/spd;application/vnd.elar.viewer.spd;
Categories=Qt;Office;Education;
Keywords=Elar;viewer;library;Элар;просмотрщик;библиотека;НЭБ;
StartupNotify=true
X-Fly-WindowType=normal
"

# Список целевых каталогов (Astra Linux Fly DE, Ubuntu, Debian, меню приложений)
TARGET_DIRS=(
    "$HOME/Рабочий стол"
    "$HOME/Desktop"
    "$HOME/.local/share/applications"
)

# Проверяем также путь через xdg-user-dir
if command -v xdg-user-dir >/dev/null 2>&1; then
    XDG_DESK=$(xdg-user-dir DESKTOP 2>/dev/null || echo "")
    if [ -n "$XDG_DESK" ] && [ -d "$XDG_DESK" ]; then
        TARGET_DIRS+=("$XDG_DESK")
    fi
fi

for tdir in "${TARGET_DIRS[@]}"; do
    mkdir -p "$tdir"
    target_desktop="$tdir/elar-nelrfviewer.desktop"
    echo "$DESKTOP_CONTENT" > "$target_desktop"
    chmod +x "$target_desktop"
    
    # Доверие в Astra Linux Fly DE, Ubuntu и GNOME
    if command -v gio >/dev/null 2>&1; then
        gio set "$target_desktop" metadata::trusted true 2>/dev/null || true
        gio set "$target_desktop" "metadata::xfce-exe-checksum" "$(sha256sum "$target_desktop" | awk '{print $1}')" 2>/dev/null || true
    fi
    ok "Ярлык создан и доверен: $target_desktop"
done

# Обновляем кэш базы данных десктоп-файлов
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi

# Коррекция прав доступа, если скрипт выполнялся через sudo
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$APP" "$ICON_TARGET_DIR" 2>/dev/null || true
    for d in "$HOME/.local/share/applications" "$HOME/Рабочий стол" "$HOME/Desktop"; do
        [ -d "$d" ] && chown -R "$SUDO_USER:$SUDO_USER" "$d" 2>/dev/null || true
    done
fi

# ----------------------------------------------------------------------------
# 7. Контрольный тестовый запуск
# ----------------------------------------------------------------------------
if [ "$NOTEST" -eq 1 ]; then
    log "Тестовый запуск пропущен (--no-test)."
else
    log "Тестовый запуск приложения (5 секунд)..."
    before=$(pgrep -f 'nelrfviewer' | sort | tr '\n' ' ')
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        su - "$SUDO_USER" -c "env DISPLAY='${DISPLAY:-:0}' '$WRAPPER' >/dev/null 2>&1 &"
    else
        env DISPLAY="${DISPLAY:-:0}" "$WRAPPER" >/dev/null 2>&1 &
    fi
    sleep 5
    new=$(pgrep -f 'nelrfviewer' | sort)
    running=0
    for p in $new; do
        echo "$before" | grep -qw "$p" || running=$((running+1))
    done
    if [ "$running" -gt 0 ]; then
        ok "Приложение успешно запустилось в фоновом режиме!"
        for p in $new; do
            echo "$before" | grep -qw "$p" || kill "$p" 2>/dev/null || true
        done
    else
        # Если графического сервера нет прямо сейчас (например, сборка в консоли/SSH), проверяем ldd
        STILL_MISSING=$(missing_of "$BIN/nelrfviewer")
        if [ -z "$STILL_MISSING" ]; then
            ok "Динамическая линковка nelrfviewer полностью разрешена."
        else
            warn "Остались неразрешенные библиотеки: $STILL_MISSING"
        fi
    fi
fi

# ----------------------------------------------------------------------------
# Итоги
# ----------------------------------------------------------------------------
echo
echo -e "${G}================================================================${C0}"
if [ ${#MANUAL[@]} -eq 0 ]; then
    echo -e "${G} Приложение НЭБ РФ (ЭЛАР) полностью настроено и готово к работе!${C0}"
    echo -e "   - Бинарный лаунчер: ${B}$WRAPPER${C0}"
    echo -e "   - Ярлыки на Рабочем столе: ${B}«НЭБ РФ»${C0}"
    echo -e "   - Иконка: ${B}$ICON_FILE${C0}"
    rc=0
else
    echo -e "${Y} Настройка выполнена ЧАСТИЧНО. Не найдены библиотеки:${C0}"
    for so in "${MANUAL[@]}"; do
        echo -e "     - ${R}$so${C0}"
    done
    echo -e " Поместите недостающие .deb пакеты в каталог dist/ или $LIB/ и повторите запуск."
    rc=2
fi
echo -e "${G}================================================================${C0}"
echo "Сайт проекта: https://biblioteka33.ru/linux"
exit $rc
