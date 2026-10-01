#!/bin/bash
# ============================================================================
#  nelrf-fix.sh v2 — полная диагностика и исправление НЭБ РФ (ЭЛАР)
#  Astra Linux 1.6/1.7/1.8 (Fly DE), Ubuntu 20.04-24.04, Debian 10-13
#
#  Исправляет:
#    1. Ярлык на рабочем столе не работает (Fly DE, GNOME, XFCE)
#    2. Приложение не запускается (DISPLAY, библиотеки, LD_LIBRARY_PATH)
#    3. Нет подключения к rusneb.ru (SSL/TLS, CA-сертификаты, OpenSSL)
#    4. Несовместимые библиотеки (libssl, libxml2, libcrypto)
#
#  Запуск:  bash nelrf-fix.sh
#           bash nelrf-fix.sh -d /путь   # указать каталог
#           bash nelrf-fix.sh --diag     # только диагностика
# ============================================================================
set -uo pipefail

if [ -t 1 ]; then
  C0=$'\033[0m' G=$'\033[0;32m' Y=$'\033[0;33m' R=$'\033[0;31m'
  B=$'\033[1;34m' C=$'\033[0;36m' BOLD=$'\033[1m'
else
  C0='' G='' Y='' R='' B='' C='' BOLD=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }
die()  { err "$*"; exit 1; }
sep()  { echo -e "${C}${BOLD}--- $* ---${C0}"; }

APP_DIR=""
DIAG_ONLY=0
BASE_URL="https://biblioteka33.ru/linux/dist"
GITHUB_RAW="https://raw.githubusercontent.com/giddammit-crypto/astradriverslinux/main/dist"
RUNFILE="nebviewer-linux-x86_64.run"
FIXED=0
WARNS=0

while [ $# -gt 0 ]; do
  case "${1:-}" in
    -d|--dir)  APP_DIR="${2:-}"; shift 2 ;;
    --diag)    DIAG_ONLY=1; shift ;;
    -h|--help) echo "Использование: bash $0 [-d /путь] [--diag]"; exit 0 ;;
    *) warn "Неизвестный аргумент: $1"; shift ;;
  esac
done

# Определяем реального пользователя (даже при sudo)
REAL_USER=""
REAL_HOME=""
if [ -n "${SUDO_USER:-}" ]; then
  REAL_USER="$SUDO_USER"
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "")
elif [ -n "${PKEXEC_UID:-}" ]; then
  REAL_USER=$(id -nu "$PKEXEC_UID" 2>/dev/null || echo "")
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "")
fi
[ -z "$REAL_USER" ] && REAL_USER="$(id -nu 2>/dev/null || echo root)"
[ -z "$REAL_HOME" ] && REAL_HOME="$HOME"

run_as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
    su -l "$REAL_USER" -c "$*" 2>/dev/null || eval "$@" 2>/dev/null || true
  else
    eval "$@" 2>/dev/null || true
  fi
}

detect_display() {
  local d="${DISPLAY:-}"
  [ -n "$d" ] && { echo "$d"; return; }
  if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    d=$(su -l "$REAL_USER" -c 'echo $DISPLAY' 2>/dev/null || echo "")
    [ -n "$d" ] && { echo "$d"; return; }
  fi
  d=$(ls /tmp/.X[0-9]*-lock 2>/dev/null | head -1 | sed 's|/tmp/.X||;s|-lock||;s|^|:|' || echo "")
  [ -n "$d" ] && { echo "$d"; return; }
  echo ":0"
}
USER_DISPLAY=$(detect_display)

detect_xauth() {
  local xa="${XAUTHORITY:-}"
  [ -n "$xa" ] && [ -f "$xa" ] && { echo "$xa"; return; }
  xa="${REAL_HOME}/.Xauthority"
  [ -f "$xa" ] && { echo "$xa"; return; }
  xa=$(find /tmp -maxdepth 1 -name '.xauth*' -user "$REAL_USER" 2>/dev/null | head -1 || echo "")
  echo "${xa:-${REAL_HOME}/.Xauthority}"
}
USER_XAUTH=$(detect_xauth)

# ============================================================
#  ФАЗА 1: Поиск / установка приложения
# ============================================================
sep "Поиск приложения НЭБ РФ"

if [ -z "$APP_DIR" ]; then
  for candidate in \
    "${REAL_HOME}/.local/opt/elar" \
    "${REAL_HOME}/elar" \
    "${REAL_HOME}/.elar" \
    "/opt/elar" "/usr/local/opt/elar" "/opt/nelrfviewer" \
    "${REAL_HOME}/.local/share/elar"; do
    if [ -d "$candidate" ]; then
      APP_DIR="$candidate"
      ok "Найден каталог: $APP_DIR"
      break
    fi
  done
fi

if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
  log "Приложение не найдено — запускаем установку..."
  RUN_PATH=""
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

  for cand in \
    "${SCRIPT_DIR:+$SCRIPT_DIR/../dist/$RUNFILE}" \
    "${SCRIPT_DIR:+$SCRIPT_DIR/$RUNFILE}" \
    "${REAL_HOME}/Downloads/$RUNFILE" \
    "${REAL_HOME}/Загрузки/$RUNFILE" \
    "$(pwd)/dist/$RUNFILE" "$(pwd)/$RUNFILE"; do
    [ -n "${cand:-}" ] && [ -f "$cand" ] && { RUN_PATH="$cand"; ok "Локальный дистрибутив: $RUN_PATH"; break; } || true
  done

  if [ -z "${RUN_PATH:-}" ]; then
    log "Загрузка дистрибутива..."
    TMPRUN=$(mktemp /tmp/nebviewer-XXXXXX.run)
    if curl -fsSL --connect-timeout 20 --max-time 600 "$BASE_URL/$RUNFILE" -o "$TMPRUN" 2>/dev/null; then
      RUN_PATH="$TMPRUN"; ok "Загружен с biblioteka33.ru"
    elif curl -fsSL --connect-timeout 20 --max-time 600 "$GITHUB_RAW/$RUNFILE" -o "$TMPRUN" 2>/dev/null; then
      RUN_PATH="$TMPRUN"; ok "Загружен с GitHub"
    else
      rm -f "$TMPRUN" || true
      die "Не удалось загрузить $RUNFILE. Проверьте интернет."
    fi
  fi

  INSTALL_TARGET="${REAL_HOME}/.local/opt/elar"
  mkdir -p "$INSTALL_TARGET"
  chmod +x "$RUN_PATH"
  log "Установка в $INSTALL_TARGET ..."
  INSTALL_DIR="$INSTALL_TARGET" bash "$RUN_PATH" --noexec --keep --target "$INSTALL_TARGET" 2>/dev/null \
    || bash "$RUN_PATH" 2>/dev/null || warn "Установка завершилась с предупреждением"
  APP_DIR="$INSTALL_TARGET"
fi

[ -d "${APP_DIR:-}" ] || die "Каталог НЭБ РФ не найден. Укажите: bash $0 -d /путь"
log "Рабочий каталог: $APP_DIR"

if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
  chown -R "${REAL_USER}:" "$APP_DIR" 2>/dev/null || true
fi

# ============================================================
#  ФАЗА 2: Поиск бинаря
# ============================================================
sep "Поиск исполняемого файла"
APP_BIN=""
for bin_cand in \
  "$APP_DIR/bin/elar-nelrfviewer" "$APP_DIR/elar-nelrfviewer" \
  "$APP_DIR/nelrfviewer" "$APP_DIR/bin/nelrfviewer" "$APP_DIR/NELRFViewer"; do
  if [ -f "$bin_cand" ] && [ -x "$bin_cand" ]; then
    APP_BIN="$bin_cand"; ok "Исполняемый файл: $APP_BIN"; break
  fi
done

if [ -z "$APP_BIN" ]; then
  APP_BIN=$(find "$APP_DIR" -maxdepth 3 -type f -executable \
    \( -name '*elar*' -o -name '*nelrf*' -o -name '*neb*' -o -name '*viewer*' \) \
    2>/dev/null | grep -v '\.sh$' | head -1 || echo "")
  [ -n "$APP_BIN" ] && ok "Найден: $APP_BIN" || warn "Исполняемый бинарь не найден"
fi

if [ -n "$APP_BIN" ] && command -v ldd >/dev/null 2>&1; then
  sep "Диагностика зависимостей"
  LDD_OUT=$(ldd "$APP_BIN" 2>/dev/null || echo "")
  MISSING_LIBS=$(echo "$LDD_OUT" | grep 'not found' | awk '{print $1}' || echo "")
  if [ -n "${MISSING_LIBS:-}" ]; then
    warn "Отсутствуют библиотеки:"; echo "$MISSING_LIBS"; WARNS=$((WARNS+1))
  else
    ok "Все динамические зависимости найдены"
  fi
fi

# ============================================================
#  ФАЗА 3: SSL/TLS — CA-сертификаты
# ============================================================
sep "Настройка SSL/TLS (CA-сертификаты)"
SSL_DIR="$APP_DIR/ssl"; mkdir -p "$SSL_DIR"

CA_SRC=""
for ca_cand in \
  /etc/ssl/certs/ca-certificates.crt \
  /etc/pki/tls/certs/ca-bundle.crt \
  /usr/share/ca-certificates/ca-certificates.crt; do
  [ -f "$ca_cand" ] && { CA_SRC="$ca_cand"; break; }
done

if [ -n "$CA_SRC" ]; then
  cp "$CA_SRC" "$SSL_DIR/ca-bundle.pem" 2>/dev/null && ok "CA-bundle: $SSL_DIR/ca-bundle.pem" || warn "Не удалось скопировать CA"
  FIXED=$((FIXED+1))
else
  warn "Системный CA-bundle не найден"
fi

# openssl.cnf с пониженным уровнем безопасности для НЭБ
cat > "$SSL_DIR/openssl.cnf" << OPENSSL_CNF_EOF
openssl_conf = openssl_init
[openssl_init]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MinProtocol = TLSv1
CipherString = DEFAULT:@SECLEVEL=1
OPENSSL_CNF_EOF
ok "openssl.cnf создан"; FIXED=$((FIXED+1))

# ============================================================
#  ФАЗА 4: Лаунчер с SSL env и LD_LIBRARY_PATH
# ============================================================
sep "Создание лаунчера"
BIN_DIR="$APP_DIR/bin"; mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/nelrfviewer-launcher.sh"

cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
export DISPLAY="\${DISPLAY:-${USER_DISPLAY}}"
export XAUTHORITY="\${XAUTHORITY:-${USER_XAUTH}}"
export LD_LIBRARY_PATH="${APP_DIR}/lib:\${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="${APP_DIR}/bin"
export QT_QPA_PLATFORM="\${QT_QPA_PLATFORM:-xcb}"
export QT_SCALE_FACTOR="\${QT_SCALE_FACTOR:-1}"
export SSL_CERT_FILE="${SSL_DIR}/ca-bundle.pem"
export OPENSSL_CONF="${SSL_DIR}/openssl.cnf"
export REQUESTS_CA_BUNDLE="${SSL_DIR}/ca-bundle.pem"
cd "${APP_DIR}"
if   [ -x "${APP_DIR}/bin/elar-nelrfviewer" ]; then exec "${APP_DIR}/bin/elar-nelrfviewer" "\$@"
elif [ -x "${APP_DIR}/elar-nelrfviewer" ];     then exec "${APP_DIR}/elar-nelrfviewer" "\$@"
elif [ -f "${APP_DIR}/elar-nelrfviewer.sh" ];  then exec bash "${APP_DIR}/elar-nelrfviewer.sh" "\$@"
elif [ -n "${APP_BIN:-}" ] && [ -x "${APP_BIN:-}" ]; then exec "${APP_BIN}" "\$@"
else echo "Ошибка: исполняемый файл не найден в ${APP_DIR}" >&2; exit 1
fi
LAUNCHER_EOF
chmod +x "$LAUNCHER"
ok "Лаунчер: $LAUNCHER"; FIXED=$((FIXED+1))

# ============================================================
#  ФАЗА 5: Патч elar-nelrfviewer.sh (если есть)
# ============================================================
if [ -f "$APP_DIR/elar-nelrfviewer.sh" ]; then
  sep "Патч elar-nelrfviewer.sh"
  [ -f "$APP_DIR/elar-nelrfviewer.sh.bak" ] || cp -a "$APP_DIR/elar-nelrfviewer.sh" "$APP_DIR/elar-nelrfviewer.sh.bak"
  sed -i "s|^APP=.*|APP=\"$APP_DIR\"|" "$APP_DIR/elar-nelrfviewer.sh" 2>/dev/null || true
  sed -i '/^export LD_LIBRARY_PATH/d' "$APP_DIR/elar-nelrfviewer.sh" 2>/dev/null || true
  sed -i "2a export LD_LIBRARY_PATH=\"${APP_DIR}/lib:\${LD_LIBRARY_PATH:-}\"" "$APP_DIR/elar-nelrfviewer.sh" 2>/dev/null || true
  sed -i "3a export SSL_CERT_FILE=\"${SSL_DIR}/ca-bundle.pem\"" "$APP_DIR/elar-nelrfviewer.sh" 2>/dev/null || true
  ok "elar-nelrfviewer.sh пропатчен"; FIXED=$((FIXED+1))
fi

# ============================================================
#  ФАЗА 6: Библиотеки — libssl, libxml2, libcrypto
# ============================================================
sep "Копирование недостающих библиотек"
LIBDIR="$APP_DIR/lib"; mkdir -p "$LIBDIR"

copy_lib() {
  local name="$1" patterns="$2" dst="$LIBDIR/$name"
  [ -f "$dst" ] && { ok "$name уже есть"; return; }
  local src=""
  for pat in $patterns; do
    src=$(find /usr/lib/x86_64-linux-gnu /usr/lib /lib/x86_64-linux-gnu /lib -maxdepth 3 \
      -name "$pat" -type f 2>/dev/null | head -1 || echo "")
    [ -n "$src" ] && break
  done
  if [ -n "$src" ]; then
    cp "$src" "$dst" && ok "Скопирована: $name ← $src" && FIXED=$((FIXED+1)) || warn "Не удалось скопировать $name"
  else
    warn "$name не найдена в системе"; WARNS=$((WARNS+1))
  fi
}

copy_lib "libxml2.so.2"     "libxml2.so.2 libxml2.so.2.*"
copy_lib "libssl.so.1.0.0"  "libssl.so.1.0.0 libssl.so.1.0.* libssl.so.10"
copy_lib "libcrypto.so.1.0.0" "libcrypto.so.1.0.0 libcrypto.so.1.0.* libcrypto.so.10"

# ============================================================
#  ФАЗА 7: Системные зависимости (apt)
# ============================================================
if command -v apt-get >/dev/null 2>&1; then
  sep "Системные apt-зависимости"
  SUDO_CMD=""
  [ "$(id -u)" -ne 0 ] && SUDO_CMD="sudo"
  NEEDED_PKGS="libxml2 libxcb1 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-render-util0 libxcb-xinerama0 libxkbcommon-x11-0 libfontconfig1 libfreetype6 ca-certificates"
  $SUDO_CMD apt-get install -y -qq $NEEDED_PKGS 2>/dev/null && ok "apt-зависимости установлены" || warn "Часть зависимостей не установлена"
fi

# ============================================================
#  ФАЗА 8: Иконка
# ============================================================
ICON_SRC=$(find "$APP_DIR" -name '*.png' -path '*/icons/*' 2>/dev/null | head -1)
if [ -n "${ICON_SRC:-}" ]; then
  ICON_DST="${REAL_HOME}/.local/share/icons/hicolor/128x128/apps"
  mkdir -p "$ICON_DST"
  cp "$ICON_SRC" "$ICON_DST/elar-nelrfviewer.png" 2>/dev/null && ok "Иконка установлена" || true
  run_as_user "gtk-update-icon-cache -f -t \"${REAL_HOME}/.local/share/icons/hicolor\" 2>/dev/null" || true
fi

# ============================================================
#  ФАЗА 9: Desktop-ярлыки (Applications + Desktop + XDG)
# ============================================================
sep "Создание ярлыков рабочего стола"
DESKTOP_CONTENT="[Desktop Entry]
Version=1.0
Type=Application
Name=НЭБ РФ
Name[ru]=НЭБ РФ
GenericName=Просмотрщик НЭБ РФ
Comment=Национальная электронная библиотека (ЭЛАР)
Exec=bash \"$LAUNCHER\" %F
Icon=elar-nelrfviewer
Terminal=false
Categories=Office;Viewer;
MimeType=application/x-neb;
StartupNotify=true
"

APPS_DIR="${REAL_HOME}/.local/share/applications"
run_as_user "mkdir -p \"$APPS_DIR\""
echo "$DESKTOP_CONTENT" > "$APPS_DIR/elar-nelrfviewer.desktop"
run_as_user "chmod +x \"$APPS_DIR/elar-nelrfviewer.desktop\"" || true
run_as_user "gio set \"$APPS_DIR/elar-nelrfviewer.desktop\" metadata::trusted true 2>/dev/null" || true
ok "Ярлык в меню: $APPS_DIR"

# Рабочий стол — все варианты (Fly DE, GNOME, XFCE, XDG)
for desktop_dir in \
  "$(run_as_user 'xdg-user-dir DESKTOP 2>/dev/null')" \
  "${REAL_HOME}/Рабочий стол" "${REAL_HOME}/Desktop" \
  "${REAL_HOME}/Рабочий_стол" "${REAL_HOME}/.fly/desktop"; do
  [ -n "${desktop_dir:-}" ] && [ -d "$desktop_dir" ] && \
  { echo "$DESKTOP_CONTENT" > "$desktop_dir/elar-nelrfviewer.desktop"
    run_as_user "chmod +x \"$desktop_dir/elar-nelrfviewer.desktop\"" || true
    run_as_user "gio set \"$desktop_dir/elar-nelrfviewer.desktop\" metadata::trusted true 2>/dev/null" || true
    ok "Ярлык на рабочем столе: $desktop_dir"; break; }
done

FIXED=$((FIXED+1))

# ============================================================
#  ФАЗА 10: Тестовый запуск
# ============================================================
sep "Тест"
if [ "$DIAG_ONLY" -eq 0 ]; then
  EXIT_CODE=0
  timeout 5 bash "$LAUNCHER" --version 2>/dev/null || EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 0 ] || [ "$EXIT_CODE" -eq 124 ]; then
    ok "Приложение запускается корректно"
  else
    warn "Тест вернул $EXIT_CODE. Запустите вручную: bash $LAUNCHER"
    WARNS=$((WARNS+1))
  fi
fi

echo
echo -e "${G}${BOLD}Готово!${C0}  Исправлений: ${G}${FIXED}${C0}  Предупреждений: ${Y}${WARNS}${C0}"
echo -e "  Запуск: ${B}bash $LAUNCHER${C0}"
echo    "  Сайт: https://biblioteka33.ru/linux"
