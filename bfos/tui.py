"""ANSI terminal interface for the bfos operator console.

Two presentations, one contract:

  * **simple mode** (default): one screen with three numbered actions —
    ``1) Kur``, ``2) Durum``, ``3) Çıkış`` — plus a single shortcut that opens
    the detailed mode. A beginner is never shown 21 playbooks, wave tooling or
    central preparation,
  * **detailed mode** (``--full`` or the ``d`` shortcut): the five categories of
    the bash console — Kurulum, Cihaz işlemleri, Merkez hazırlığı, Araçlar,
    Cihaz bilgisi.

Rules:
  * every screen ends with ``0) Geri`` and ``q) Çıkış``,
  * every operator message is Turkish, every code identifier stays English,
  * colours are pure ANSI escapes written by hand (no textual/rich/curses),
  * input is validated; a wrong answer gets a polite Turkish warning instead of
    a traceback or a silent default,
  * rendering is a pure function of the screen description, so the menu
    contract can be unit-tested without a terminal.
"""

from __future__ import annotations

import io  # noqa: F401 - kept for callers that build an in-memory Console
import sys
from dataclasses import dataclass
from typing import Callable, Iterable, List, Optional, Sequence, Tuple

from . import config

# Values returned by :meth:`Console.ask_run`. They match
# bfos.runner.RUN_MODE_* on purpose (asserted by the test suite).
RUN = "run"
CHECK = "check"
CANCEL = "cancel"

# Outcomes of :func:`interpret_menu_choice`.
CHOICE_QUIT = "quit"
CHOICE_BACK = "back"
CHOICE_ITEM = "item"
CHOICE_INVALID = "invalid"

ENTRY_ITEM = "item"
ENTRY_SHORTCUT = "shortcut"
ENTRY_SECTION = "section"


# ---------------------------------------------------------------------------
# Colour handling
# ---------------------------------------------------------------------------
def color_enabled(no_color: bool = False, mode: str = "auto", is_tty: bool = True) -> bool:
    """Decide whether ANSI colour may be written to the stream."""
    if no_color:
        return False
    if mode == "never":
        return False
    if mode == "always":
        return True
    return is_tty and not bool(_env("NO_COLOR"))


def _env(name: str) -> str:
    import os

    return os.environ.get(name, "")


def stream_is_tty(stream) -> bool:
    try:
        return bool(stream.isatty())
    except (AttributeError, ValueError):
        return False


# ---------------------------------------------------------------------------
# Screen description (pure data, unit-testable)
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Entry:
    """One line of a screen.

    ``kind=ENTRY_ITEM`` is numbered by its position among the items;
    ``kind=ENTRY_SHORTCUT`` carries its own key (``d``) and is rendered next to
    the footer; ``kind=ENTRY_SECTION`` is a heading.
    """

    kind: str
    label: str = ""
    description: str = ""
    key: str = ""


@dataclass(frozen=True)
class Screen:
    title: str
    subtitle: str = ""
    entries: Tuple[Entry, ...] = ()
    notes: Tuple[str, ...] = ()

    def items(self) -> Tuple[Tuple[str, Entry], ...]:
        """(key, entry) for every numbered item, key = "1", "2", ... """
        numbered = [entry for entry in self.entries if entry.kind == ENTRY_ITEM]
        return tuple((str(index + 1), entry) for index, entry in enumerate(numbered))

    def shortcuts(self) -> Tuple[Entry, ...]:
        return tuple(entry for entry in self.entries if entry.kind == ENTRY_SHORTCUT)

    def keys(self) -> Tuple[str, ...]:
        """Every selectable key: numbered items first, then shortcuts."""
        return tuple(key for key, _ in self.items()) + tuple(
            entry.key for entry in self.shortcuts()
        )


def item(label: str, description: str = "") -> Entry:
    return Entry(ENTRY_ITEM, label=label, description=description)


def shortcut(key: str, label: str, description: str = "") -> Entry:
    return Entry(ENTRY_SHORTCUT, label=label, description=description, key=key)


def section(label: str) -> Entry:
    return Entry(ENTRY_SECTION, label=label)


# ---------------------------------------------------------------------------
# The menus
# ---------------------------------------------------------------------------
def simple_menu() -> Screen:
    """Default view: exactly three basic actions, nothing else.

    The only extra key is the ``d`` shortcut that opens the detailed mode; it is
    rendered next to the numbered actions as a clearly-marked advanced entry, so
    a beginner is never dropped into 21 playbooks and wave tooling by accident.
    """
    return Screen(
        title=config.SIMPLE_MENU_TITLE,
        subtitle=config.SIMPLE_MENU_SUBTITLE,
        entries=(
            item(config.SIMPLE_ITEM_INSTALL_LABEL, config.SIMPLE_ITEM_INSTALL_DESC),
            item(config.SIMPLE_ITEM_STATUS_LABEL, config.SIMPLE_ITEM_STATUS_DESC),
            item(config.SIMPLE_ITEM_EXIT_LABEL, config.SIMPLE_ITEM_EXIT_DESC),
            shortcut("d", config.SIMPLE_ADVANCED_LABEL, config.SIMPLE_ADVANCED_DESC),
        ),
        notes=(config.MSG_SIMPLE_MODE_HINT,),
    )


def detailed_menu() -> Screen:
    """Detailed mode: the five categories of the bash console."""
    return Screen(
        title=config.FULL_MENU_TITLE,
        subtitle=config.FULL_MENU_SUBTITLE,
        entries=(
            section("Kategoriler"),
            item(config.CAT_INSTALL, "Bu cihazı yerel olarak kur ve doğrula"),
            item(config.CAT_DEVICES, "Filo playbook'ları, her zaman açık hedefle"),
            item(config.CAT_CENTRAL, "Merkez entegrasyonunu doğrula ve hazırla"),
            item(config.CAT_TOOLS, "Depo ve yerel yardımcı araçlar"),
            item(config.CAT_INFO, "Salt okunur bilgi ekranları"),
            shortcut("s", "Basit mod", "Yalnız Kur / Durum / Çıkış"),
        ),
        notes=(config.MSG_FULL_MODE_HINT,),
    )


def install_menu(items: Sequence[Tuple[str, str]]) -> Screen:
    """Kurulum category (this device only)."""
    return Screen(
        title="{0} — {1}".format(config.CAT_INSTALL, "bu cihaz"),
        subtitle="Yalnız bu cihaz kurulur; hiçbir filo cihazına dokunulmaz",
        entries=(section("Yerel kurulum"),) + tuple(item(label, desc) for label, desc in items),
    )


def devices_menu(report_count: int, maintenance_count: int) -> Screen:
    return Screen(
        title=config.CAT_DEVICES,
        subtitle="Yalnızca depodaki mevcut playbook'lar, her zaman açık hedefle",
        entries=(
            section("Filo işlemleri"),
            item("Salt okunur raporlar", "{0} işlem, hiçbir cihazı değiştirmez".format(report_count)),
            item("Bakım işlemleri", "{0} işlem; yıkıcı olanlar iki kez onay ister".format(maintenance_count)),
            item("Envanter hedeflerini göster", "dalgalar, gruplar ve cihaz sayıları"),
        ),
    )


def central_menu() -> Screen:
    return Screen(
        title=config.CAT_CENTRAL,
        subtitle="Merkez entegrasyonunu doğrular ve hazırlar; merkez sunucu kurmaz",
        entries=(
            section("Hazırlık ve doğrulama"),
            item("Merkez hazırlık durumu", "envanter, yer tutucular, yönetici anahtarı"),
            item("Merkez uç noktalarını göster", "WireGuard hub, izleme, paket aynası"),
            item("Merkez uç noktalarını dene", "DNS + TCP, salt okunur"),
            item("Dalga geçiş kapısı durumu", "dalga başına cihaz sayısı ve kapı kuralı"),
            item("Merkez hazırlık listesi", "kayıt öncesi gerekenler"),
        ),
    )


def tools_menu() -> Screen:
    return Screen(
        title=config.CAT_TOOLS,
        subtitle="Yerel yardımcılar; ISO derleme bu konsolun kapsamı dışındadır",
        entries=(
            section("Depo"),
            item("Depoyu güncelle", "git pull --ff-only"),
            item("Ortam ve sürüm bilgisi", "yollar, sürümler, çözümlenen ayarlar"),
            item("İşlem kataloğunu göster", "--list çıktısı"),
            section("Bu cihazın araçları"),
            item("Yerel çevrimdışı kapı", "bf-check-local"),
            item("Kayıt (enrollment) kapısı", "bf-check-enrollment"),
            item("Hazır (READY) kapısı", "bf-check-ready"),
            item("Derin tanılama", "bf-diagnostics (yoksa bf-status)"),
            item("Canlı donanım / OS kontrolü", "bf-live-hw-check, salt okunur"),
            item("Uzak erişim kanalları", "bf-remote-status --check"),
            item("Field OS sürüm kimliği", "bf-release"),
            item("Donanım envanteri", "bf-hardware-inventory.sh"),
            item("Destek paketi", "bf-support-bundle --out-dir"),
            section("Bu konsol"),
            item("Konsol denetim kaydını göster", "denetim kaydının son 40 satırı"),
        ),
    )


def info_menu() -> Screen:
    return Screen(
        title=config.CAT_INFO,
        subtitle="Salt okunur: buradaki hiçbir işlem cihazı değiştirmez",
        entries=(
            section("Bu cihaz"),
            item("Kimlik", "ana makine adı, cihaz kimliği, bayi numarası"),
            item("Sağlık özeti", "bf-status"),
            item("Kurulum ve kayıt durumu", "state.json beyaz listesi"),
            item("Ağ", "adresler, rota, DNS, WireGuard eş sayısı"),
            item("Disk, bellek, CPU", "df, free, yük"),
            item("Kurulu sabit paketler", "dpkg-query"),
            item("Servis durumu", "ssh, xrdp, rustdesk, docker, wg"),
            item("Son journal hataları", "journalctl -p err"),
            section("Filo"),
            item("Envanter özeti", "dalgalar, gruplar, sayılar"),
            item("Hedefi çözümle", "bayi numarası veya grubu doğrula"),
        ),
    )


def target_menu() -> Screen:
    return Screen(
        title="Hedef seçimi",
        subtitle="Hedef sorulmadan hiçbir komut üretilmez",
        entries=(
            item("Tek cihaz (bayi numarası)", "8 hane, örn. 12010101"),
            item("Grup / dalga", ", ".join(config.WAVES)),
            item("Filo geneli", "dalga kapsamlı playbook'lar dalga dalga sorar"),
            item("Hedefi doğrudan yaz", "bayi numarası, grup ya da 'all'"),
        ),
    )


def yes_no_suffix(default_yes: bool = False) -> str:
    return "[e/H]" if not default_yes else "[E/h]"


# ---------------------------------------------------------------------------
# Rendering (pure functions)
# ---------------------------------------------------------------------------
def horizontal_rule(char: str = "-", width: int = config.CONSOLE_WIDTH) -> str:
    return char * width


def render_item(key: str, label: str, description: str = "", palette: Optional[config.Palette] = None) -> str:
    palette = palette or config.Palette(False)
    head = "   {0:>2}) {1:<46}".format(key, label)
    if description:
        return head + " " + palette.paint(description, "dim")
    return head.rstrip()


def render_screen(screen: Screen, palette: Optional[config.Palette] = None, width: int = config.CONSOLE_WIDTH) -> str:
    """The complete text of one screen (banner, items, footer)."""
    palette = palette or config.Palette(False)
    lines: List[str] = [""]
    lines.append(palette.paint(horizontal_rule("=", width), "dim"))
    lines.append("  " + palette.paint(screen.title, "bold", "cyan"))
    if screen.subtitle:
        lines.append("  " + palette.paint(screen.subtitle, "dim"))
    lines.append(palette.paint(horizontal_rule("=", width), "dim"))
    lines.append("")

    item_keys = dict((entry, key) for key, entry in screen.items())
    for entry in screen.entries:
        if entry.kind == ENTRY_SECTION:
            lines.append("")
            lines.append("   " + palette.paint(entry.label, "magenta"))
        elif entry.kind == ENTRY_ITEM:
            lines.append(render_item(item_keys[entry], entry.label, entry.description, palette))
    for entry in screen.shortcuts():
        lines.append(render_item(entry.key, entry.label, entry.description, palette))

    for note in screen.notes:
        lines.append("")
        lines.append("   " + palette.paint(note, "dim"))

    lines.append("")
    lines.append(palette.paint(horizontal_rule("-", width), "dim"))
    footer = "   {0:>2}) {1:<46} {2:>2}) {3}".format(
        "0", config.MSG_BACK, "q", config.MSG_QUIT_ITEM
    )
    lines.append(footer)
    lines.append(palette.paint(horizontal_rule("-", width), "dim"))
    lines.append("")
    return "\n".join(lines)


def interpret_menu_choice(choice: str, keys: Sequence[str]) -> Tuple[str, str]:
    """Classify what the operator typed on a menu screen.

    ``""``/``0`` -> back, ``q``/``Q`` -> quit, a known key -> item, everything
    else -> invalid (the caller prints a polite Turkish warning).
    """
    value = (choice or "").strip()
    if value == "" or value == "0":
        return CHOICE_BACK, ""
    if value.lower() == "q":
        return CHOICE_QUIT, ""
    for key in keys:
        if value == key:
            return CHOICE_ITEM, key
    return CHOICE_INVALID, value


# ---------------------------------------------------------------------------
# Console I/O
# ---------------------------------------------------------------------------
class Console:
    """Thin ANSI console: writes to a stream, reads lines, validates input.

    ``reader`` can be injected (a callable taking the prompt and returning a
    line, or ``None`` for EOF) which is how the console is tested without a
    terminal.
    """

    def __init__(
        self,
        out=None,
        inp=None,
        palette: Optional[config.Palette] = None,
        interactive: Optional[bool] = None,
        reader: Optional[Callable[[str], Optional[str]]] = None,
        clear: bool = True,
    ) -> None:
        self.out = out if out is not None else sys.stdout
        self.inp = inp if inp is not None else sys.stdin
        self.reader = reader
        tty = stream_is_tty(self.inp) and stream_is_tty(self.out)
        self.interactive = tty if interactive is None else interactive
        self.palette = palette or config.Palette(False)
        self.clear = clear

    # -- output ------------------------------------------------------------
    def write(self, text: str = "") -> None:
        self.out.write(text + "\n")

    def paint(self, text: str, *names: str) -> str:
        return self.palette.paint(text, *names)

    def section(self, label: str) -> None:
        self.write("")
        self.write("   " + self.paint(label, "magenta"))

    def kv(self, key: str, value: str) -> None:
        self.write("   {0:<24} {1}".format(key, value))

    def note(self, text: str) -> None:
        self.write(self.paint(text, "dim"))

    def info(self, text: str) -> None:
        self.write("{0} {1}".format(self.paint("[i]", "cyan"), text))

    def ok(self, text: str) -> None:
        self.write("{0} {1}".format(self.paint("[OK]", "green"), text))

    def warn(self, text: str) -> None:
        for line in str(text).splitlines() or [""]:
            self.write("{0} {1}".format(self.paint("[UYARI]", "yellow"), line))

    def error(self, text: str) -> None:
        for line in str(text).splitlines() or [""]:
            self.write("{0} {1}".format(self.paint("[HATA]", "red"), line))

    def banner(self, title: str, subtitle: str = "") -> None:
        self.write(render_screen(Screen(title=title, subtitle=subtitle), self.palette))

    def screen(self, screen: Screen) -> None:
        if self.interactive and self.clear:
            self.out.write("\033[H\033[2J")
        self.write(render_screen(screen, self.palette))

    def show_lines(self, lines: Iterable[str]) -> None:
        for line in lines:
            self.write(line)

    def exception(self, refused) -> None:
        """Report a :class:`bfos.operations.Refused` nicely."""
        self.error(refused.message)
        if getattr(refused, "detail", ""):
            for line in refused.detail.splitlines():
                self.note("   " + line)

    # -- input -------------------------------------------------------------
    def read(self, prompt: str = "") -> Optional[str]:
        """Read one line; ``None`` means EOF (stdin closed / non-interactive)."""
        if self.reader is not None:
            self.out.write(prompt)
            return self.reader(prompt)
        self.out.write(prompt)
        self.out.flush()
        try:
            line = self.inp.readline()
        except (ValueError, OSError):
            return None
        if line == "":
            return None
        return line.rstrip("\n")

    def ask(self, prompt: str, allow_empty: bool = False) -> Optional[str]:
        """Read a non-empty answer; re-asks politely on an empty line."""
        while True:
            value = self.read(prompt)
            if value is None:
                return None
            value = value.strip()
            if value or allow_empty:
                return value
            self.warn(config.MSG_REQUIRED)

    def ask_with_default(self, prompt: str, default: str) -> Optional[str]:
        value = self.read(prompt)
        if value is None:
            return None
        value = value.strip()
        return value or default

    def confirm(self, question: str, default_yes: bool = False) -> Optional[bool]:
        """Turkish yes/no question. Only an explicit yes proceeds."""
        while True:
            value = self.read("{0} {1}: ".format(question, yes_no_suffix(default_yes)))
            if value is None:
                return None
            answer = value.strip().lower()
            if answer in ("e", "evet", "y", "yes"):
                return True
            if answer in ("h", "hayir", "hayır", "n", "no"):
                return False
            if answer == "":
                return default_yes
            self.warn(config.MSG_INVALID_INPUT.format(value=value))

    def confirm_token(self, message: str, token: str, prompt: str) -> Optional[bool]:
        """The operator must type TOKEN exactly (highest-risk confirmations)."""
        if message:
            self.warn(message)
        value = self.read(prompt)
        if value is None:
            return None
        return value.strip() == token

    def ask_run(self, question: str = config.MSG_RUN_ASK) -> str:
        """y = run, c = run with --check, anything else = cancel."""
        value = self.read(question)
        if value is None:
            return CANCEL
        answer = value.strip().lower()
        if answer in ("y", "yes", "e", "evet"):
            return RUN
        if answer in ("c", "check"):
            return CHECK
        return CANCEL

    def pause(self, message: str = config.MSG_PRESS_ENTER) -> None:
        if self.interactive:
            self.read(self.paint(message + " ", "dim"))

    def ask_menu_choice(self, screen: Screen) -> Tuple[str, str]:
        """Read and classify a menu answer, warning on invalid input."""
        value = self.read(config.MSG_PROMPT_CHOICE)
        if value is None:
            return CHOICE_QUIT, ""
        outcome, payload = interpret_menu_choice(value, screen.keys())
        if outcome == CHOICE_INVALID:
            self.warn(config.MSG_UNKNOWN_CHOICE.format(choice=payload))
            self.write("   " + config.MSG_MENU_RANGE.format(max=len(screen.items())))
            return CHOICE_INVALID, payload
        return outcome, payload
