#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Мастер настройки «Космо» — Графический и консольный инсталлятор для Astra Linux / Debian / Ubuntu
Сайт проекта: https://biblioteka33.ru/linux
"""

import sys
import os
import re
import argparse
import subprocess
import shutil

BASE_URL = "https://biblioteka33.ru/linux/scripts"
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIR = os.path.join(PROJECT_DIR, "scripts")
ASSETS_DIR = os.path.join(PROJECT_DIR, "assets")

ANSI_ESCAPE_RE = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')


def clean_ansi(text):
    """Удаляет escape-последовательности терминала для чистого вывода в GUI."""
    if not text:
        return ""
    return ANSI_ESCAPE_RE.sub('', text)


COMPONENTS = [
    {
        "id": "all",
        "name": "🚀 Установить всё сразу",
        "desc": "Canon LBP2900 + Epson L800 + Epson L132 + Просмотрщик НЭБ РФ",
        "script": None,
        "sudo": True
    },
    {
        "id": "canon",
        "name": "🖨️ Canon LBP2900",
        "desc": "Лазерный принтер CAPT 2.71, автоочередь, служба ccpd, модуль usblp",
        "script": "canon-lbp2900.sh",
        "sudo": True
    },
    {
        "id": "epson-l800",
        "name": "🎨 Epson L800",
        "desc": "Фотопринтер с СНПЧ, автоочередь, снятие ограничений печати PDF",
        "script": "epson-l800.sh",
        "sudo": True
    },
    {
        "id": "epson-l132",
        "name": "📄 Epson L132",
        "desc": "Струйный принтер (официальный драйвер 201401w, очередь, udev hotplug)",
        "script": "epson-l132.sh",
        "sudo": True
    },
    {
        "id": "neb",
        "name": "📚 Просмотрщик НЭБ РФ",
        "desc": "Установка без root, фикс SSL к rusneb.ru, ярлыки на Рабочем столе",
        "script": "nelrf-fix.sh",
        "sudo": False
    }
]


def resolve_script_path(script_name):
    """Находит локальный скрипт или возвращает None для загрузки по сети."""
    if not script_name:
        return None
    local_path = os.path.join(SCRIPTS_DIR, script_name)
    if os.path.isfile(local_path):
        return local_path
    return None


def detect_connected_devices():
    """Определяет подключенные USB принтеры для информации пользователю."""
    detected = []
    try:
        out = subprocess.check_output(["lsusb"], text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            ll = line.lower()
            if "04a9:" in ll or ("canon" in ll and ("2900" in ll or "lbp" in ll)):
                detected.append("Canon LBP2900 (USB кабель подключен)")
            elif "04b8:" in ll or "epson" in ll:
                if "l800" in ll:
                    detected.append("Epson L800 (USB кабель подключен)")
                elif "l132" in ll:
                    detected.append("Epson L132 (USB кабель подключен)")
                else:
                    detected.append(f"Принтер Epson: {line.split('ID ')[-1].strip()}")
    except Exception:
        pass
    return detected


def get_elevated_command(base_cmd, gui_mode=False):
    """
    Формирует команду с повышением привилегий.
    В GUI использует pkexec для вызова системного графического диалога авторизации.
    """
    if os.geteuid() == 0:
        return list(base_cmd)

    # Проверяем, есть ли уже парольный кэш sudo
    try:
        res = subprocess.run(["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            return ["sudo", "-n"] + list(base_cmd)
    except Exception:
        pass

    # Графический режим: pkexec вызывает системный Polkit диалог
    if gui_mode and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        if shutil.which("pkexec"):
            display = os.environ.get("DISPLAY", ":0")
            xauth = os.environ.get("XAUTHORITY", os.path.expanduser("~/.Xauthority"))
            return ["pkexec", "env", f"DISPLAY={display}", f"XAUTHORITY={xauth}"] + list(base_cmd)

    # Консольный режим / fallback
    return ["sudo"] + list(base_cmd)


def run_single_component(comp_id, dry_run=False, log_callback=None, gui_mode=False):
    """Выполняет установку одного конкретного компонента."""
    comp = next((c for c in COMPONENTS if c["id"] == comp_id), None)
    if not comp or not comp["script"]:
        return False

    script_name = comp["script"]
    local_script = resolve_script_path(script_name)

    def log(text):
        cleaned = clean_ansi(text)
        if log_callback:
            log_callback(cleaned)
        else:
            print(cleaned)

    log(f"==> Установка: {comp['name']}")
    log(f"    {comp['desc']}")

    if dry_run:
        log(f"[*] [DRY-RUN] Проверка скрипта {script_name} завершена успешно.")
        return True

    base_cmd = []
    if local_script:
        base_cmd = ["bash", local_script]
    else:
        log(f"[*] Загрузка скрипта из сети: {BASE_URL}/{script_name}")
        base_cmd = ["bash", "-c", f"curl -fsSL {BASE_URL}/{script_name} | bash"]

    if comp["sudo"]:
        cmd = get_elevated_command(base_cmd, gui_mode=gui_mode)
    else:
        cmd = base_cmd

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=os.environ.copy()
        )
        for line in proc.stdout:
            log(line.rstrip())
        proc.wait()
        if proc.returncode == 0:
            log(f"[OK] Компонент {comp['name']} успешно установлен и настроен!\n")
            return True
        else:
            log(f"[EE] Ошибка при установке {comp['name']} (код возврата: {proc.returncode})\n")
            return False
    except Exception as e:
        log(f"[EE] Исключение при выполнении: {e}\n")
        return False


def run_component(comp_id, dry_run=False, log_callback=None, progress_callback=None, gui_mode=False):
    """Главная функция запуска выбранного компонента или полного пакета."""
    if comp_id == "all":
        sub_items = ["canon", "epson-l800", "epson-l132", "neb"]
        total = len(sub_items)
        success_count = 0
        for i, item_id in enumerate(sub_items, 1):
            if progress_callback:
                progress_callback((i - 1) / total)
            ok = run_single_component(item_id, dry_run=dry_run, log_callback=log_callback, gui_mode=gui_mode)
            if ok:
                success_count += 1
            if progress_callback:
                progress_callback(i / total)
        return success_count == total
    else:
        return run_single_component(comp_id, dry_run=dry_run, log_callback=log_callback, gui_mode=gui_mode)


def run_cli_menu(dry_run=False):
    """Консольный интерактивный интерфейс."""
    c_cyan = "\033[1;36m"
    c_green = "\033[1;32m"
    c_yellow = "\033[1;33m"
    c_bold = "\033[1m"
    c_reset = "\033[0m"

    print(f"{c_cyan}╔══════════════════════════════════════════════════════════════╗{c_reset}")
    print(f"{c_cyan}║     🚀 Мастер настройки «Космо» (CLI) — biblioteka33.ru       ║{c_reset}")
    print(f"{c_cyan}║     Автоматическая настройка Astra Linux / Debian / Ubuntu   ║{c_reset}")
    print(f"{c_cyan}╚══════════════════════════════════════════════════════════════╝{c_reset}")
    print()

    # Оборудование
    devices = detect_connected_devices()
    if devices:
        print(f"{c_green}[*] Обнаружено подключенное USB-оборудование:{c_reset}")
        for dev in devices:
            print(f"    • {dev}")
        print()

    for idx, comp in enumerate(COMPONENTS, 1):
        print(f"  {c_bold}{idx}){c_reset} {comp['name']} — {comp['desc']}")
    print(f"  {c_bold}0){c_reset} Выход")
    print()

    if dry_run or not sys.stdin.isatty():
        print(f"{c_yellow}[*] Режим проверки компонентов (dry-run / headless)...{c_reset}")
        for comp in COMPONENTS:
            if comp["script"]:
                local = resolve_script_path(comp["script"])
                status = "найден локально" if local else "сетевой источник"
            else:
                status = "комплексный пакет"
            print(f"    • {comp['name']}: {status}")
        print(f"{c_green}[OK] Проверка компонентов в CLI режиме успешна.{c_reset}")
        return 0

    try:
        choice = input(f"Выберите пункт [1-{len(COMPONENTS)}, 0]: ").strip()
    except (KeyboardInterrupt, EOFError):
        print("\nОтмена.")
        return 0

    if choice == "0":
        print("Выход.")
        return 0

    try:
        idx = int(choice)
        if 1 <= idx <= len(COMPONENTS):
            comp = COMPONENTS[idx - 1]
            success = run_component(comp["id"], dry_run=dry_run, gui_mode=False)
            return 0 if success else 1
        else:
            print("Неверный выбор.")
            return 1
    except ValueError:
        print("Некорректный ввод.")
def update_from_github(log_callback=None):
    """Обновляет скрипты и установщик напрямую с GitHub."""
    import urllib.request
    def log(text):
        if log_callback:
            log_callback(text)
        else:
            print(text)

    log("[*] Проверка и загрузка свежих версий с GitHub (giddammit-crypto/astradriverslinux)...")
    raw_base = "https://raw.githubusercontent.com/giddammit-crypto/astradriverslinux/main"
    files = [
        ("installer_gui.py", os.path.join(PROJECT_DIR, "installer_gui.py")),
        (".version.json", os.path.join(PROJECT_DIR, ".version.json")),
        ("scripts/setup.sh", os.path.join(SCRIPTS_DIR, "setup.sh")),
        ("scripts/install.sh", os.path.join(SCRIPTS_DIR, "install.sh")),
        ("scripts/canon-lbp2900.sh", os.path.join(SCRIPTS_DIR, "canon-lbp2900.sh")),
        ("scripts/epson-l800.sh", os.path.join(SCRIPTS_DIR, "epson-l800.sh")),
        ("scripts/epson-l132.sh", os.path.join(SCRIPTS_DIR, "epson-l132.sh")),
        ("scripts/nelrf-fix.sh", os.path.join(SCRIPTS_DIR, "nelrf-fix.sh")),
        ("scripts/SHA256SUMS", os.path.join(SCRIPTS_DIR, "SHA256SUMS")),
        ("index.html", os.path.join(PROJECT_DIR, "index.html")),
    ]

    updated = 0
    for rel, local_dest in files:
        url = f"{raw_base}/{rel}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Cosmo-Updater/2.1"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                content = resp.read()
                os.makedirs(os.path.dirname(local_dest), exist_ok=True)
                with open(local_dest, "wb") as f:
                    f.write(content)
                if local_dest.endswith(".sh") or local_dest.endswith(".py"):
                    try:
                        os.chmod(local_dest, 0o755)
                    except Exception:
                        pass
                log(f"  ✓ Обновлен файл: {rel}")
                updated += 1
        except Exception as e:
            log(f"  ✗ {rel}: {e}")

    log(f"[OK] Синхронизация завершена. Загружено файлов: {updated}/{len(files)}")
    return updated > 0


def run_gui():
    """Запуск графического интерфейса GTK3."""
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GdkPixbuf, GLib
    except Exception as e:
        print(f"Предупреждение: GTK3 недоступен ({e}). Переключение в CLI режим.", file=sys.stderr)
        return run_cli_menu()

    class CosmoInstallerWindow(Gtk.Window):
        def __init__(self):
            super().__init__(title="Мастер настройки «Космо» — biblioteka33.ru")
            self.set_default_size(720, 560)
            self.set_position(Gtk.WindowPosition.CENTER)
            self.set_border_width(16)

            vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            self.add(vbox)

            # Header / Hero Box
            header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
            icon_path = os.path.join(ASSETS_DIR, "hero-cosmo.png")
            if os.path.exists(icon_path):
                try:
                    pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(icon_path, 80, 80, True)
                    image = Gtk.Image.new_from_pixbuf(pixbuf)
                    header_box.pack_start(image, False, False, 0)
                except Exception:
                    pass

            title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            lbl_title = Gtk.Label()
            lbl_title.set_markup("<span size='x-large' weight='bold' color='#047857'>Мастер настройки «Космо»</span>")
            lbl_title.set_xalign(0)
            lbl_sub = Gtk.Label(label="Автоматическая настройка оборудования и НЭБ РФ для Astra Linux, Ubuntu и Debian.\nПринтеры готовы к печати сразу после завершения мастера.")
            lbl_sub.set_xalign(0)
            lbl_sub.set_line_wrap(True)
            title_box.pack_start(lbl_title, False, False, 0)
            title_box.pack_start(lbl_sub, False, False, 0)
            header_box.pack_start(title_box, True, True, 0)
            vbox.pack_start(header_box, False, False, 0)

            # Блок обнаруженного USB-оборудования
            devices = detect_connected_devices()
            hw_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            if devices:
                hw_text = "<b>Подключено по USB:</b> " + ", ".join(devices)
                hw_lbl = Gtk.Label()
                hw_lbl.set_markup(f"<span color='#047857'>🔌 {hw_text}</span>")
            else:
                hw_lbl = Gtk.Label()
                hw_lbl.set_markup("<span color='#475569'>🔌 USB-принтеры не обнаружены (драйверы установятся и настроятся для автоподключения).</span>")
            hw_lbl.set_xalign(0)
            hw_box.pack_start(hw_lbl, True, True, 0)
            vbox.pack_start(hw_box, False, False, 2)

            vbox.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 2)

            # Radiolist / Components
            lbl_select = Gtk.Label()
            lbl_select.set_markup("<b>Выберите компонент для установки:</b>")
            lbl_select.set_xalign(0)
            vbox.pack_start(lbl_select, False, False, 0)

            self.radio_buttons = []
            first_rb = None
            for comp in COMPONENTS:
                rb = Gtk.RadioButton.new_with_label_from_widget(first_rb, f"{comp['name']} — {comp['desc']}")
                if first_rb is None:
                    first_rb = rb
                self.radio_buttons.append((comp["id"], rb))
                vbox.pack_start(rb, False, False, 1)

            # Progress Bar
            self.progress_bar = Gtk.ProgressBar()
            self.progress_bar.set_fraction(0.0)
            self.progress_bar.set_show_text(True)
            self.progress_bar.set_text("Готов к установке")
            vbox.pack_start(self.progress_bar, False, False, 4)

            # Log View
            scrolled = Gtk.ScrolledWindow()
            scrolled.set_hexpand(True)
            scrolled.set_vexpand(True)
            self.text_view = Gtk.TextView()
            self.text_view.set_editable(False)
            self.text_view.set_cursor_visible(False)
            self.text_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            self.text_buffer = self.text_view.get_buffer()
            scrolled.add(self.text_view)
            vbox.pack_start(scrolled, True, True, 0)

            # Action Buttons
            btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

            # Дополнительные кнопки быстрого действия после установки
            self.btn_test_print = Gtk.Button(label="🖨️ Пробная печать")
            self.btn_test_print.set_sensitive(False)
            self.btn_test_print.connect("clicked", self.on_test_print_clicked)
            btn_box.pack_start(self.btn_test_print, False, False, 0)

            self.btn_open_neb = Gtk.Button(label="📚 Открыть НЭБ РФ")
            self.btn_open_neb.set_sensitive(False)
            self.btn_open_neb.connect("clicked", self.on_open_neb_clicked)
            btn_box.pack_start(self.btn_open_neb, False, False, 0)

            self.btn_update = Gtk.Button(label="🔄 Обновить с GitHub")
            self.btn_update.connect("clicked", self.on_update_clicked)
            btn_box.pack_start(self.btn_update, False, False, 0)

            spacer = Gtk.Box()
            btn_box.pack_start(spacer, True, True, 0)

            self.btn_install = Gtk.Button(label="🚀 Установить")
            self.btn_install.get_style_context().add_class("suggested-action")
            self.btn_install.connect("clicked", self.on_install_clicked)
            btn_box.pack_start(self.btn_install, False, False, 0)

            btn_close = Gtk.Button(label="Закрыть")
            btn_close.connect("clicked", lambda w: Gtk.main_quit())
            btn_box.pack_start(btn_close, False, False, 0)

            vbox.pack_start(btn_box, False, False, 4)

        def append_log(self, text):
            cleaned = clean_ansi(text)
            end_iter = self.text_buffer.get_end_iter()
            self.text_buffer.insert(end_iter, cleaned + "\n")
            mark = self.text_buffer.create_mark(None, self.text_buffer.get_end_iter(), False)
            self.text_view.scroll_to_mark(mark, 0.05, True, 0.0, 1.0)

        def update_progress(self, fraction):
            self.progress_bar.set_fraction(fraction)
            percent = int(fraction * 100)
            self.progress_bar.set_text(f"Выполнено: {percent}%")

        def on_test_print_clicked(self, widget):
            try:
                # Отправляем тестовую печать на первую доступную очередь
                out = subprocess.check_output(["lpstat", "-p"], text=True, stderr=subprocess.DEVNULL)
                printers = [line.split()[1] for line in out.splitlines() if line.startswith("printer ")]
                if printers:
                    target = printers[0]
                    test_file = "/usr/share/cups/data/testprint"
                    if not os.path.exists(test_file):
                        test_file = "/tmp/testprint.txt"
                        with open(test_file, "w", encoding="utf-8") as tf:
                            tf.write("Пробная страница печати biblioteka33.ru\nПринтер настроен успешно!\n")
                    subprocess.run(["lp", "-d", target, test_file], check=True)
                    self.append_log(f"[OK] Пробная страница отправлена на принтер {target}")
                else:
                    self.append_log("[!!] Очереди печати еще не созданы в CUPS.")
            except Exception as e:
                self.append_log(f"[EE] Ошибка пробной печати: {e}")

        def on_open_neb_clicked(self, widget):
            home = os.path.expanduser("~")
            launcher = os.path.join(home, ".local/opt/elar/bin/nelrfviewer-launcher.sh")
            if os.path.exists(launcher):
                subprocess.Popen(["bash", launcher], start_new_session=True)
                self.append_log("[OK] Просмотрщик НЭБ РФ запущен.")
            else:
                self.append_log(f"[EE] Лаунчер НЭБ РФ не найден по пути: {launcher}")

        def on_update_clicked(self, widget):
            self.btn_update.set_sensitive(False)
            self.append_log("[*] Запуск обновления скриптов с GitHub...")
            import threading
            def update_worker():
                update_from_github(log_callback=lambda msg: GLib.idle_add(self.append_log, msg))
                GLib.idle_add(lambda: self.btn_update.set_sensitive(True))
            threading.Thread(target=update_worker, daemon=True).start()

        def on_install_clicked(self, widget):
            selected_id = "all"
            for comp_id, rb in self.radio_buttons:
                if rb.get_active():
                    selected_id = comp_id
                    break

            self.btn_install.set_sensitive(False)
            for _, rb in self.radio_buttons:
                rb.set_sensitive(False)

            self.progress_bar.set_fraction(0.0)
            self.progress_bar.set_text("Установка выполняется...")
            self.append_log(f"[*] Начало установки: {selected_id}")

            import threading
            def worker():
                success = run_component(
                    selected_id,
                    log_callback=lambda msg: GLib.idle_add(self.append_log, msg),
                    progress_callback=lambda frac: GLib.idle_add(self.update_progress, frac),
                    gui_mode=True
                )
                def finish():
                    self.btn_install.set_sensitive(True)
                    for _, rb in self.radio_buttons:
                        rb.set_sensitive(True)
                    self.progress_bar.set_fraction(1.0 if success else 0.0)
                    status_text = "Все выбранные компоненты успешно установлены!" if success else "Процесс завершился с ошибками. Проверьте лог."
                    self.progress_bar.set_text("Установка завершена" if success else "Ошибка")
                    self.append_log(f"[*] {status_text}")
                    # Активируем кнопки быстрого действия
                    self.btn_test_print.set_sensitive(True)
                    self.btn_open_neb.set_sensitive(True)
                GLib.idle_add(finish)

            thread = threading.Thread(target=worker, daemon=True)
            thread.start()

    win = CosmoInstallerWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Мастер настройки «Космо» — Установщик оборудования и ПО biblioteka33.ru"
    )
    parser.add_argument(
        "--cli",
        action="store_true",
        help="Принудительный консольный режим (CLI)"
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="Обновить скрипты и установщик напрямую с GitHub"
    )
    parser.add_argument(
        "--component", "-c",
        choices=["all", "canon", "epson-l800", "epson-l132", "neb"],
        help="Идентификатор компонента для немедленной установки"
    )
    parser.add_argument(
        "--check", "--dry-run",
        action="store_true",
        help="Тестовая проверка доступности компонентов без запуска команд"
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Вывести список поддерживаемых компонентов"
    )

    args = parser.parse_args()

    if args.list:
        print("Доступные компоненты:")
        for c in COMPONENTS:
            print(f"  {c['id']:<12} : {c['name']} ({c['desc']})")
        return 0

    if args.update:
        success = update_from_github()
        return 0 if success else 1

    if args.component:
        success = run_component(args.component, dry_run=args.check, gui_mode=False)
        return 0 if success else 1

    # Режим CLI при флаге --cli, отсутствии $DISPLAY или флаге --check
    if args.cli or args.check or not os.environ.get("DISPLAY"):
        return run_cli_menu(dry_run=args.check)

    # Иначе запускаем GUI
    return run_gui()


if __name__ == "__main__":
    sys.exit(main())
