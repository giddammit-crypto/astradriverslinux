#!/bin/bash
# onlyoffice.sh — установка OnlyOffice Desktop Editors
# https://biblioteka33.ru/linux
set -uo pipefail

if [ -t 1 ]; then
  C0=$'\033[0m' G=$'\033[0;32m' Y=$'\033[0;33m' B=$'\033[1;34m' R=$'\033[0;31m' BOLD=$'\033[1m'
else
  C0='' G='' Y='' B='' R='' BOLD=''
fi
log()  { echo -e "${B}[*]${C0} $*"; }
ok()   { echo -e "${G}[OK]${C0} $*"; }
warn() { echo -e "${Y}[!!]${C0} $*"; }
err()  { echo -e "${R}[EE]${C0} $*" >&2; }

SUDOCMD=""
[ "$(id -u)" -ne 0 ] && SUDOCMD="sudo"

echo -e "${B}${BOLD}==============================${C0}"
echo -e "${B}${BOLD}  OnlyOffice Desktop Editors  ${C0}"
echo -e "${B}${BOLD}==============================${C0}"
echo

if dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1; then
  ok "OnlyOffice уже установлен!"
  exit 0
fi

log "Установка вспомогательных пакетов..."
$SUDOCMD apt-get install -y -qq apt-transport-https ca-certificates gnupg curl 2>/dev/null || true

KEYRING="/usr/share/keyrings/onlyoffice.gpg"
log "Добавляю GPG-ключ OnlyOffice..."
if curl -fsSL --connect-timeout 15 --max-time 60 \
    https://download.onlyoffice.com/repo/debian/onlyoffice.key 2>/dev/null \
    | $SUDOCMD gpg --dearmor -o "$KEYRING"; then
  $SUDOCMD chmod 644 "$KEYRING" 2>/dev/null || true
  ok "GPG-ключ добавлен"
else
  warn "Не удалось получить GPG-ключ — пробую без проверки подписи"
fi

log "Добавляю apt-репозиторий OnlyOffice..."
if [ -f "$KEYRING" ]; then
  echo "deb [signed-by=$KEYRING] https://download.onlyoffice.com/repo/debian squeeze main" | \
    $SUDOCMD tee /etc/apt/sources.list.d/onlyoffice.list >/dev/null
else
  echo "deb https://download.onlyoffice.com/repo/debian squeeze main" | \
    $SUDOCMD tee /etc/apt/sources.list.d/onlyoffice.list >/dev/null
fi

$SUDOCMD apt-get update -qq 2>/dev/null || true

log "Устанавливаю onlyoffice-desktopeditors..."
if $SUDOCMD apt-get install -y onlyoffice-desktopeditors 2>/dev/null; then
  ok "OnlyOffice установлен через apt!"
  exit 0
fi

warn "apt-установка не удалась — скачиваю .deb напрямую с GitHub Releases..."

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
case "$ARCH" in amd64|x86_64) ARCH="amd64" ;; arm64|aarch64) ARCH="arm64" ;; *) ARCH="amd64" ;; esac

OO_VER=$(curl -fsSL --connect-timeout 10 --max-time 20 \
  https://api.github.com/repos/ONLYOFFICE/DesktopEditors/releases/latest 2>/dev/null \
  | grep -oP '(?<="tag_name":")[^"]+' | head -1)
OO_VER=${OO_VER:-v8.2.0}
OO_VER_CLEAN=${OO_VER#v}

DEB_URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/download/${OO_VER}/onlyoffice-desktopeditors_${OO_VER_CLEAN}_${ARCH}.deb"
TMP_DEB=$(mktemp /tmp/onlyoffice-XXXXXX.deb)
log "Скачиваю: $DEB_URL"
if curl -fsSL --connect-timeout 20 --max-time 600 -L "$DEB_URL" -o "$TMP_DEB" 2>/dev/null \
    && [ -s "$TMP_DEB" ]; then
  $SUDOCMD dpkg -i "$TMP_DEB" 2>/dev/null || true
  $SUDOCMD apt-get install -f -y -qq 2>/dev/null || true
  rm -f "$TMP_DEB"
  dpkg -s onlyoffice-desktopeditors >/dev/null 2>&1 && ok "OnlyOffice установлен!" || \
    err "Не удалось установить. Ссылка: https://www.onlyoffice.com/download-desktop.aspx"
else
  rm -f "$TMP_DEB" || true
  err "Не удалось скачать .deb"
  echo "Скачайте вручную: https://www.onlyoffice.com/download-desktop.aspx"
  exit 1
fi