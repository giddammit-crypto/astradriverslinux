#!/bin/bash
# setup.sh v3 - Космо installer entry point
# https://biblioteka33.ru/linux
set -uo pipefail
VERSION="2.2.0"
BASE_URL="https://biblioteka33.ru/linux"
GH_RAW="https://raw.githubusercontent.com/giddammit-crypto/astradriverslinux/main"
GH_API="https://api.github.com/repos/giddammit-crypto/astradriverslinux/commits/main"

if [ -t 1 ]; then
  C0=$'\033[0m' G=$'\033[0;32m' Y=$'\033[0;33m' B=$'\033[1;34m' DIM=$'\033[2m' BOLD=$'\033[1m' R=$'\033[0;31m'
else
  C0='' G='' Y='' B='' DIM='' BOLD='' R=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }

# =========================================================
#  ФАЗА 1: проверка/установка зависимостей
#  python3, GTK3, gi — всё необходимое для GUI
# =========================================================
check_and_install_deps() {
  log "Проверка зависимостей..."
  local missing="" sudo_cmd=""
  [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"

  if command -v apt-get >/dev/null 2>&1; then
    command -v curl    >/dev/null 2>&1 || missing="$missing curl"
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"

    # GTK3 + python3-gi для GUI
    if ! python3 -c "import gi" 2>/dev/null; then
      missing="$missing python3-gi python3-gi-cairo gir1.2-gtk-3.0 libgtk-3-0"
    elif ! python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null; then
      missing="$missing python3-gi-cairo gir1.2-gtk-3.0 libgtk-3-0"
    fi

    if [ -n "${missing:-}" ]; then
      warn "Отсутствуют:${missing}. Устанавливаю..."
      $sudo_cmd apt-get update -qq 2>/dev/null || true
      $sudo_cmd apt-get install -y -qq $missing 2>/dev/null && \
        ok "Зависимости установлены" || warn "Не удалось установить часть зависимостей"
    else
      ok "Все зависимости в порядке"
    fi

  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    local pm; command -v dnf >/dev/null 2>&1 && pm="dnf" || pm="yum"
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"
    python3 -c "import gi" 2>/dev/null || missing="$missing python3-gobject gtk3 python3-cairo"
    if [ -n "${missing:-}" ]; then
      warn "Устанавливаю:$missing"
      $sudo_cmd $pm install -y $missing 2>/dev/null && ok "Установлено" || true
    fi
  else
    command -v python3 >/dev/null 2>&1 && ok "python3 найден" || \
      warn "Установите python3 вручную через менеджер пакетов"
  fi
}

# =========================================================
#  ФАЗА 2: авто-обновление с GitHub
# =========================================================
check_and_self_update() {
  # Пропускаем проверку обновлений при pipe-запуске (curl | bash)
  if [ ! -f "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "bash" ] || [ "${BASH_SOURCE[0]:-}" = "-" ]; then
    return 0
  fi

  log "Проверка обновлений с GitHub..."
  local SELF_DIR LOCAL_SHA REMOTE_SHA
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  LOCAL_SHA=""
  if command -v git >/dev/null 2>&1 && [ -d "$SELF_DIR/../.git" ]; then
    LOCAL_SHA=$(git -C "$SELF_DIR/.." rev-parse HEAD 2>/dev/null || echo "")
  elif command -v git >/dev/null 2>&1 && [ -d "$SELF_DIR/.git" ]; then
    LOCAL_SHA=$(git -C "$SELF_DIR" rev-parse HEAD 2>/dev/null || echo "")
  fi
  if [ -z "${LOCAL_SHA:-}" ]; then
    for vj in "$SELF_DIR/../.version.json" "$SELF_DIR/.version.json"; do
      [ -f "$vj" ] && LOCAL_SHA=$(sed -nE 's/.*"(sha|commit)":[[:space:]]*"([a-f0-9]{40})".*/\2/p' "$vj" 2>/dev/null | head -1) && \
        [ -n "$LOCAL_SHA" ] && break || true
    done
  fi

  REMOTE_SHA=""
  if command -v git >/dev/null 2>&1; then
    REMOTE_SHA=$(git ls-remote --heads "https://github.com/giddammit-crypto/astradriverslinux.git" main 2>/dev/null | awk '{print $1}' | head -1 || echo "")
  fi
  if [ -z "${REMOTE_SHA:-}" ]; then
    REMOTE_SHA=$(curl -fsSL --connect-timeout 8 --max-time 15 "$GH_API" 2>/dev/null \
      | sed -nE 's/.*"sha":[[:space:]]*"([a-f0-9]{40})".*/\1/p' | head -1 || echo "")
  fi

  [ -z "${REMOTE_SHA:-}" ] && { warn "Нет связи с GitHub"; return 0; }
  [ -n "${LOCAL_SHA:-}" ] && [ "$LOCAL_SHA" = "$REMOTE_SHA" ] && \
    { ok "Установщик актуален (${REMOTE_SHA:0:8})"; return 0; }

  echo
  echo -e "${G}${BOLD}✨ Доступно обновление установщика!${C0}"
  [ -n "${LOCAL_SHA:-}" ] && \
    echo -e "  Текущий:  ${DIM}${LOCAL_SHA:0:8}${C0}" || \
    echo -e "  Текущий:  ${DIM}(новая установка)${C0}"
  echo -e "  Новый:    ${G}${REMOTE_SHA:0:8}${C0}"
  echo

  local APPLY="y"
  [ -e /dev/tty ] && [ -r /dev/tty ] && \
    read -rp "Обновить установщик сейчас? [Y/n] " APPLY </dev/tty || true
  case "${APPLY:-y}" in n|N|н|Н) log "Обновление отложено."; return 0 ;; esac

  local TMP_SELF
  TMP_SELF=$(mktemp /tmp/cosmo-update-XXXXXX.sh)
  if curl -fsSL --connect-timeout 15 --max-time 120 \
      "$GH_RAW/scripts/setup.sh" -o "$TMP_SELF" 2>/dev/null; then
    chmod +x "$TMP_SELF"
    cp -f "$TMP_SELF" "${BASH_SOURCE[0]}" 2>/dev/null || true
    printf '{"version":"%s","sha":"%s","updated":"%s"}\n' \
      "$VERSION" "$REMOTE_SHA" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      > "$SELF_DIR/../.version.json" 2>/dev/null || true
    ok "Установщик обновлён — перезапуск..."
    exec bash "$TMP_SELF" "$@"
  else
    warn "Не удалось скачать обновление — продолжаем"
    rm -f "$TMP_SELF" || true
  fi
}

# --- запуск проверок ---
check_and_install_deps
check_and_self_update "$@" 2>/dev/null || true

# =========================================================
#  Определяем рабочую папку
# =========================================================
LOCAL_REPO=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
  [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/../installer_gui.py" ] && LOCAL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
  [ -z "${LOCAL_REPO:-}" ] && [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/installer_gui.py" ] && LOCAL_REPO="$SCRIPT_DIR"
fi

if [ -n "${LOCAL_REPO:-}" ]; then
  WORK_DIR="$LOCAL_REPO"
  log "Запуск из локального репозитория: $WORK_DIR"
else
  WORK_DIR=$(mktemp -d /tmp/cosmo-setup-XXXXXX)
  trap 'rm -rf "$WORK_DIR"' EXIT
  log "Загрузка компонентов Космо v${VERSION}..."
  mkdir -p "$WORK_DIR/scripts" "$WORK_DIR/assets"

  dl() {
    local rel="$1"
    local dst="$WORK_DIR/$rel"
    mkdir -p "$(dirname "$dst")"

    # Приоритет 1: GitHub Raw (всегда актуальный и корректный plain text)
    # Приоритет 2: зеркало сайта biblioteka33.ru
    if ! curl -fsSL --connect-timeout 10 --max-time 120 "$GH_RAW/$rel" -o "$dst" 2>/dev/null; then
      curl -fsSL --connect-timeout 10 --max-time 120 "$BASE_URL/$rel" -o "$dst" 2>/dev/null || \
      { warn "Не удалось загрузить $rel"; return 1; }
    fi

    # Защита от поврежденных/base64 файлов (если сервер отдал base64 вместо текста)
    if [ -f "$dst" ] && [ -s "$dst" ]; then
      local first_line
      first_line=$(head -n 1 "$dst" 2>/dev/null || echo "")
      if [[ "$first_line" == IyEv* ]] || [[ "$first_line" =~ ^[A-Za-z0-9+/=]{60,}$ ]]; then
        local tmp_dec
        tmp_dec=$(mktemp "${dst}.dec.XXXXXX")
        if base64 -d "$dst" > "$tmp_dec" 2>/dev/null && [ -s "$tmp_dec" ]; then
          mv -f "$tmp_dec" "$dst"
        else
          rm -f "$tmp_dec"
        fi
      fi
    fi
  }

  dl ".version.json"            || true
  dl "installer_gui.py"         || true
  dl "assets/hero-cosmo.png"    || true
  dl "scripts/install.sh"       || true
  dl "scripts/canon-lbp2900.sh" || true
  dl "scripts/epson-l800.sh"    || true
  dl "scripts/epson-l132.sh"    || true
  dl "scripts/nelrf-fix.sh"     || true
  dl "scripts/onlyoffice.sh"    || true
fi

export COSMO_PARENT=1

chmod +x "$WORK_DIR/installer_gui.py" 2>/dev/null || true
chmod +x "$WORK_DIR/scripts/"*.sh     2>/dev/null || true

# =========================================================
#  Запуск GUI или консоли
# =========================================================
HAS_DISPLAY=0
{ [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; } && HAS_DISPLAY=1 || true
CAN_RUN_GUI=0
# Проверка валидности installer_gui.py (защита от повреждения или base64)
if [ -f "$WORK_DIR/installer_gui.py" ] && command -v python3 >/dev/null 2>&1; then
  if ! python3 -m py_compile "$WORK_DIR/installer_gui.py" >/dev/null 2>&1; then
    if head -n 1 "$WORK_DIR/installer_gui.py" 2>/dev/null | grep -q "^IyEv"; then
      tmp_py=$(mktemp "${WORK_DIR}/installer_gui-XXXXXX.py")
      base64 -d "$WORK_DIR/installer_gui.py" > "$tmp_py" 2>/dev/null && mv -f "$tmp_py" "$WORK_DIR/installer_gui.py" || rm -f "$tmp_py"
    fi
    if ! python3 -m py_compile "$WORK_DIR/installer_gui.py" >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 10 --max-time 60 "$GH_RAW/installer_gui.py" -o "$WORK_DIR/installer_gui.py" 2>/dev/null || true
    fi
  fi
fi

if [ "$HAS_DISPLAY" -eq 1 ] && [ -f "$WORK_DIR/installer_gui.py" ] && command -v python3 >/dev/null 2>&1; then
  python3 -c \
    "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk; exit(0 if Gtk.init_check()[0] else 1)" \
    2>/dev/null && CAN_RUN_GUI=1 || true
fi

if [ "$CAN_RUN_GUI" -eq 1 ] && [ "${1:-}" != "--cli" ]; then
  log "Запуск графического мастера..."
  xhost +si:localuser:root >/dev/null 2>&1 || true
  if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    [ -c /dev/tty ] && sudo -v </dev/tty 2>/dev/null || true
  fi
  exec python3 "$WORK_DIR/installer_gui.py" "$@"
else
  [ "$HAS_DISPLAY" -eq 0 ]     && log "Графическое окружение не обнаружено. Консольный режим..."
  [ "${1:-}" = "--cli" ]        && log "Консольный режим (--cli)"
  [ "$CAN_RUN_GUI" -eq 0 ] && [ "$HAS_DISPLAY" -eq 1 ] && \
    warn "GTK3 недоступен. Переход в консольный режим..."

  if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    [ -c /dev/tty ] && sudo -v </dev/tty 2>/dev/null || true
  fi

  if [ -f "$WORK_DIR/scripts/install.sh" ]; then
    exec bash "$WORK_DIR/scripts/install.sh" "$@"
  elif [ -f "$WORK_DIR/installer_gui.py" ]; then
    exec python3 "$WORK_DIR/installer_gui.py" --cli "$@"
  else
    err "Установщик не найден в $WORK_DIR"; exit 1
  fi
fi
