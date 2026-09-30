# astradriverslinux — Онлайн-инсталлятор оборудования и системы НЭБ РФ

[![GitHub repo](https://img.shields.io/badge/GitHub-astradriverslinux-blue?logo=github)](https://github.com/giddammit-crypto/astradriverslinux)
[![OS: Astra Linux](https://img.shields.io/badge/Astra_Linux-1.6%20%7C%201.7%20%7C%201.8%20(Fly)-red)](https://astralinux.ru/)
[![OS: Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20--%2026.04-orange?logo=ubuntu)](https://ubuntu.com/)
[![OS: Debian](https://img.shields.io/badge/Debian-10%20--%2013-crimson?logo=debian)](https://debian.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Современный комплекс автоматической настройки принтеров и защищенного просмотрщика Национальной электронной библиотеки (НЭБ РФ) для **Astra Linux (с графической оболочкой Fly)**, **Ubuntu** и **Debian**.

Разработано специально для библиотек, архивов, музеев и школ:
- **Принтеры работают сразу из коробки** — пользователю не нужно открывать веб-интерфейс CUPS, искать принтер или вручную настраивать порты. Очереди создаются, активируются и привязываются автоматически.
- **Стильный графический мастер (Wizard)** с дружелюбным маскотом **Космо** в стиле классических и понятных Windows-инсталляторов (Inno Setup / Modern Wizard).
- **Реальный прогресс-бар и лог** вместо слепого ожидания.
- **Полноценная интеграция НЭБ РФ** с созданием проверенного ярлыка на Рабочем столе и в меню программ, а также устранением сбоев библиотек (`libxml2.so.2`, `ICU`, `OpenSSL 1.0` для защищенного подключения к `rusneb.ru`).
- **Встроенная система автообновления** сайта и скриптов с GitHub.

---

## Быстрый запуск одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/giddammit-crypto/astradriverslinux/main/scripts/setup.sh | bash
```
или через веб-сервер проекта:
```bash
curl -fsSL https://biblioteka33.ru/linux/scripts/setup.sh | bash
```

> **Примечание:** Если графический сервер ($DISPLAY) доступен, автоматически запустится дружелюбный графический мастер установки. При запуске через SSH или на сервере без монитора скрипт мгновенно переключится в удобное интерактивное консольное меню.

---

## Поддерживаемое оборудование и программы

| Оборудование / ПО | Скрипт | Особенности |
|---|---|---|
| **Canon LBP2900** | `scripts/canon-lbp2900.sh` | Драйвер Canon CAPT 2.71 (amd64 / i386), модуль `usblp`, автоочередь `LBP2900`, служба `ccpd`, правило udev горячего подключения. |
| **Epson L800** | `scripts/epson-l800.sh` | Фотопринтер с СНПЧ, официальный PPD Seiko Epson, автоочередь `Epson-L800`, снятие ограничений ImageMagick policy для печати PDF. |
| **Epson L132** | `scripts/epson-l132.sh` | Четырехцветный струйный принтер со встроенной СНПЧ, официальный 64-битный драйвер Epson 201401w, автоочередь `Epson-L132`, udev hotplug. |
| **НЭБ РФ (ЭЛАР)** | `scripts/nelrf-fix.sh` | Установка без root в `~/.local/opt/elar`, бинарный лаунчер, экспорт SSL CA корневых сертификатов для входа в `access.rusneb.ru`, ярлыки на Рабочем столе (`.desktop` с `chmod +x` и меткой `gio trusted`). |

---

## Структура репозитория

```
astradriverslinux/
├── index.html                   # Веб-портал с карточками оборудования и маскотом Космо
├── installer_gui.py             # Графический мастер установки на Python 3 + GTK 3 (с CLI fallback)
├── .version.json                # Метаданные текущей версии релиза
├── .gitignore                   # Исключения git (кэш, временные файлы)
├── assets/                      # Изображения, иконки и клиентские скрипты
│   ├── hero-cosmo.png           # Круглый бейдж маскота «Космо»
│   ├── canon-lbp2900.jpg        # Фото принтера Canon LBP2900
│   ├── epson-l800.png           # Рендер фотопринтера Epson
│   └── updater.js               # Клиентский модуль проверки и применения обновлений с GitHub
├── api/                         # Бэкенд самообновления
│   ├── config.php               # Конфигурация GitHub репозитория и веток
│   └── updater.php              # REST API автообновления сайта и скриптов (git pull / zipball)
├── dist/                        # Готовые deb-пакеты драйверов и инсталлятор НЭБ РФ
│   ├── cndrvcups-common_3.21-1_amd64.deb
│   ├── cndrvcups-capt_2.71-1_amd64.deb
│   ├── epson-inkjet-printer-l800_1.0.1-1_amd64.deb
│   ├── epson-inkjet-printer-201401w_1.0.0-1lsb3.2_amd64.deb
│   └── nebviewer-linux-x86_64.run
└── scripts/                     # Скрипты автоматической установки
    ├── setup.sh                 # Главная точка входа мастера установки «Космо»
    ├── install.sh               # Интерактивное консольное меню
    ├── canon-lbp2900.sh         # Установщик Canon LBP2900
    ├── epson-l800.sh            # Установщик Epson L800
    ├── epson-l132.sh            # Установщик Epson L132
    ├── nelrf-fix.sh             # Установщик и фикс ридера НЭБ РФ
    └── SHA256SUMS               # Контрольные суммы SHA-256
```

---

## Система обновления с GitHub

В проект интегрирована система сквозного обновления с GitHub (по образцу архитектуры Aurora):

1. **Серверный бэкенд (`api/updater.php`):**
   - Проверяет свежие коммиты через GitHub REST API.
   - Поддерживает безопасное применение обновлений через `git pull` либо загрузку zipball репозитория.

2. **Веб-интерфейс (`index.html` + `assets/updater.js`):**
   - Автоматически проверяет статус репозитория на GitHub.
   - Отображает бейдж версии и уведомление при появлении новых обновлений.
   - Предоставляет кнопку «Обновить сайт и скрипты».

3. **Консольный и графический установщик (`installer_gui.py`):**
   - Поддерживает команду синхронизации: `python3 installer_gui.py --update`
   - В графическом окне мастера доступна кнопка «🔄 Обновить с GitHub».

---

## Лицензия

Проект распространяется под лицензией MIT. Разработано для библиотек и учреждений культуры.
Сайт проекта: [biblioteka33.ru/linux](https://biblioteka33.ru/linux)
Репозиторий: [github.com/giddammit-crypto/astradriverslinux](https://github.com/giddammit-crypto/astradriverslinux)
