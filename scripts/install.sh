#!/bin/bash
# install.sh v3 - консольный установщик Космо
# https://biblioteka33.ru/linux
set -uo pipefail

VERSION="2.2.0"
BASE="https://biblioteka33.ru/linux/scripts"
GH_RAW="https://raw.githubusercontent.com/giddammit-crypto/astradriverslinux/main"
GH_API="https://api.github.com/repos/giddammit-crypto/astradriverslinux/commits/main"

if [ -t 1 ]; then
  C0=$'\033[0m' G=$'\033[0;32m' Y=$'\033[0;33m' B=$'\033[1;34m'
  DIM=$'\033[2m' BOLD=$'\033[1m' R=$'\033[0;31m' C=$'\033[0;36m'
else
  C0='' G='' Y='' B='' DIM='' BOLD='' R='' C=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }

SCRIPT_DIR=""
[ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ] && \
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true

# ============================================================
#  ПРОВЕРКА ЗАВИСИМОСТЕЙ: python3, curl, GTK3
# ============================================================
check_deps() {
  local missing="" sudo_cmd=""
  [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
  log "Проверка зависимостей..."

  command -v curl    >/dev/null 2>&1 || missing="$missing curl"
  command -v bash    >/dev/null 2>&1 || missing="$missing bash"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"

  if command -v apt-get >/dev/null 2>&1; then
    if ! python3 -c "import gi" 2>/dev/null; then
      missing="$missing python3-gi python3-gi-cairo gir1.2-gtk-3.0 libgtk-3-0"
    fi
    if [ -n "${missing:-}" ]; then
      warn "Отсутствуют:${missing}. Устанавливаю..."
      $sudo_cmd apt-get update -qq 2>/dev/null || true
      $sudo_cmd apt-get install -y -qq $missing 2>/dev/null && \
        ok "Зависимости установлены" || warn "Не удалось установить часть зависимостей"
    else
      ok "Все зависимости в порядке"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"
    python3 -c "import gi" 2>/dev/null || missing="$missing python3-gobject gtk3"
    [ -n "${missing:-}" ] && $sudo_cmd dnf install -y $missing 2>/dev/null && ok "OK" || true
  elif command -v yum >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || missing="$missing python3"
    [ -n "${missing:-}" ] && $sudo_cmd yum install -y $missing 2>/dev/null && ok "OK" || true
  else
    command -v python3 >/dev/null 2>&1 && ok "python3 найден" || \
      warn "Установите python3 вручную через менеджер пакетов"
  fi
}
check_deps

# ============================================================
#  АВТООБНОВЛЕНИЕ С GITHUB
# ============================================================
auto_update() {
  log "Проверка обновлений..."
  local LOCAL_SHA REMOTE_SHA
  LOCAL_SHA=""
  for vj in \
    "${SCRIPT_DIR:+$SCRIPT_DIR/../.version.json}" \
    "${SCRIPT_DIR:+$SCRIPT_DIR/.version.json}" \
    "$(pwd)/.version.json"; do
    [ -n "${vj:-}" ] && [ -f "$vj" ] && \
      LOCAL_SHA=$(sed -nE 's/.*"(sha|commit)":[[:space:]]*"([a-f0-9]{40})".*/\2/p' "$vj" 2>/dev/null | head -1 || echo "") && \
      [ -n "$LOCAL_SHA" ] && break || true
  done

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
  echo -e "${C}${BOLD}✨ Доступно обновление!${C0}  ${DIM}${LOCAL_SHA:0:8}${C0} → ${G}${REMOTE_SHA:0:8}${C0}"

  local APPLY="y"
  [ -e /dev/tty ] && [ -r /dev/tty ] && read -rp "Обновить? [Y/n] " APPLY </dev/tty || true
  case "${APPLY:-y}" in n|N|н|Н) return 0 ;; esac

  local TMP
  TMP=$(mktemp /tmp/cosmo-upd-XXXXXX.sh)
  if curl -fsSL --connect-timeout 15 --max-time 120 "$GH_RAW/scripts/install.sh" -o "$TMP" 2>/dev/null; then
    chmod +x "$TMP"
    ok "Обновлено. Перезапуск..."
    exec bash "$TMP" "$@"
  else
    rm -f "$TMP" || true
    warn "Не удалось загрузить обновление"
  fi
}
auto_update "$@" 2>/dev/null || true

# ============================================================
#  МЕНЮ
# ============================================================
clear
echo -e "${B}${BOLD}┌──────────────────────────────────────────────────────┐${C0}"
echo -e "${B}${BOLD}│  Космо — установщик библиотеки  v${VERSION}              │${C0}"
echo -e "${B}${BOLD}│  biblioteka33.ru/linux  ·  github: astradriverslinux  │${C0}"
echo -e "${B}${BOLD}└──────────────────────────────────────────────────────┘${C0}"
echo
echo -e "  ${BOLD}Выберите компонент:${C0}"
echo
echo -e "  ${G}1${C0}  🖨️  Canon LBP2900   — драйвер + очередь печати"
echo -e "  ${G}2${C0}  🎨  Epson L800      — драйвер + СНПЧ + PDF-фикс"
echo -e "  ${G}3${C0}  📄  Epson L132      — драйвер 201401w"
echo -e "  ${G}4${C0}  📚  НЭБ РФ          — запуск + SSL + ярлыки"
echo -e "  ${G}5${C0}  📅  OnlyOffice      — редактор .docx/.xlsx/.pptx"
echo
echo -e "  ${G}6${C0}  🚀  Всё сразу       — пункты 1-5"
echo
echo -e "  ${G}7${C0}  🔄  Проверить обновления"
echo -e "  ${G}0${C0}  ❌  Выход"
echo

choice=""
for arg in "$@"; do
  case "$arg" in 0|1|2|3|4|5|6|7) choice="$arg"; break ;; esac
done

if [ -z "${choice:-}" ]; then
  if [ -e /dev/tty ] && [ -r /dev/tty ]; then
    read -rp "Выберите [0-7]: " choice </dev/tty
  else
    read -rp "Выберите [0-7]: " choice
  fi
fi

# ============================================================
#  Загрузка + запуск скрипта
# ============================================================
fetch() {
  local script_name="$1" need_root="${2:-user}" script_file="" tmp=""
  if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/$script_name" ]; then
    script_file="$SCRIPT_DIR/$script_name"
  else
    tmp=$(mktemp /tmp/astra-XXXXXX.sh)
    log "Скачиваю $script_name..."
    curl -fsSL --connect-timeout 15 --max-time 300 "$BASE/$script_name" -o "$tmp" 2>/dev/null || \
    curl -fsSL --connect-timeout 15 --max-time 300 "$GH_RAW/scripts/$script_name" -o "$tmp" 2>/dev/null || \
    { warn "Не удалось скачать $script_name"; rm -f "$tmp"; return 1; }
    script_file="$tmp"
  fi
  echo -e "${DIM}──── $script_name ────${C0}"
  local rc=0
  if [ "$need_root" = "sudo" ]; then
    [ "$(id -u)" -eq 0 ] && bash "$script_file" || rc=$? || sudo bash "$script_file" || rc=$?
  else
    bash "$script_file" || rc=$?
  fi
  [ -n "${tmp:-}" ] && rm -f "$tmp" || true
  return $rc
}

# ============================================================
#  OnlyOffice: apt-репозиторий или .deb напрямую
# ============================================================
install_onlyoffice() {
  echo -e "${C}${BOLD}--- OnlyOffice Desktop Editors ---${C0}"

  if dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1; then
    ok "OnlyOffice уже установлен!"; return 0
  fi

  local SUDOCMD=""
  [ "$(id -u)" -ne 0 ] && SUDOCMD="sudo"

  $SUDOCMD apt-get install -y -qq apt-transport-https ca-certificates gnupg curl 2>/dev/null || true

  log "Добавляю GPG-ключ OnlyOffice..."
  local KEYRING="/usr/share/keyrings/onlyoffice.gpg"
  if ! curl -fsSL --connect-timeout 15 --max-time 60 \
      https://download.onlyoffice.com/repo/debian/onlyoffice.key 2>/dev/null \
      | $SUDOCMD gpg --dearmor -o "$KEYRING"; then
    warn "Не удалось получить GPG-ключ"; return 1
  fi
  $SUDOCMD chmod 644 "$KEYRING" 2>/dev/null || true

  log "Добавляю репозиторий OnlyOffice..."
  echo "deb [signed-by=$KEYRING] https://download.onlyoffice.com/repo/debian squeeze main" | \
    $SUDOCMD tee /etc/apt/sources.list.d/onlyoffice.list >/dev/null

  $SUDOCMD apt-get update -qq 2>/dev/null || true

  if ! $SUDOCMD apt-get install -y onlyoffice-desktopeditors 2>/dev/null; then
    warn "apt-установка не удалась — скачиваю .deb напрямую с GitHub"
    local ARCH OO_VER OO_VER_CLEAN DEB_URL TMP_DEB
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    OO_VER=$(curl -fsSL --max-time 15 \
      https://api.github.com/repos/ONLYOFFICE/DesktopEditors/releases/latest \
      2>/dev/null | grep -oP '(?<="tag_name":"?)[^"]+' | head -1 || echo "v8.2.0")
    OO_VER_CLEAN="${OO_VER#v}"
    DEB_URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/download/${OO_VER}/onlyoffice-desktopeditors_${OO_VER_CLEAN}_${ARCH}.deb"
    TMP_DEB=$(mktemp /tmp/onlyoffice-XXXXXX.deb)
    log "Загружаю $DEB_URL ..."
    if curl -fsSL --connect-timeout 20 --max-time 600 -L "$DEB_URL" -o "$TMP_DEB" 2>/dev/null; then
      $SUDOCMD dpkg -i "$TMP_DEB" 2>/dev/null || $SUDOCMD apt-get install -f -y 2>/dev/null || true
      rm -f "$TMP_DEB"
    else
      rm -f "$TMP_DEB"
      warn "Не удалось скачать. Ссылка: https://www.onlyoffice.com/download-desktop.aspx"
      return 1
    fi
  fi

  dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1 && ok "OnlyOffice установлен!" || warn "Проверьте установку вручную"
}

# ============================================================
#  Обработка выбора
# ============================================================
case "${choice:-}" in
  1) fetch canon-lbp2900.sh sudo ;;
  2) fetch epson-l800.sh    sudo ;;
  3) fetch epson-l132.sh    sudo ;;
  4) fetch nelrf-fix.sh     user ;;
  5) install_onlyoffice ;;
  6)
    fetch canon-lbp2900.sh sudo
    fetch epson-l800.sh    sudo
    fetch epson-l132.sh    sudo
    fetch nelrf-fix.sh     user
    install_onlyoffice
    ;;
  7) auto_update "$@" || true ;;
  0) echo "До свидания!"; exit 0 ;;
  *) err "Неверный выбор: ${choice}"; exit 1 ;;
esac

echo
echo -e "${G}${BOLD}Готово!${C0}  Поддержка: https://biblioteka33.ru/linux"
