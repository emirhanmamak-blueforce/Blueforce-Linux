"""bfos/ui_gui.py -- Blueforce Field OS Turkce masaustu arayuzu (tkinter).

Ne yapar
--------
`admin/bf-menu` terminal konsolunun yaptigi isi ayni is mantigi uzerinden bir
gercek pencereye tasir:

  * basit mod  : uc buyuk buton -- Kur / Durum / Cikis (+ "Detayli mod"),
  * detayli mod: kategori sekmeleri -- Kurulum, Cihaz islemleri, Merkez
    hazirligi, Araclar, Cihaz bilgisi,
  * hedef secimi: bayi no alani (^[0-9]{8}$ dogrulamali) + dalga grubu listesi,
  * her komut CALISTIRILMADAN ONCE gosterilir ve onay ister; yikici islemlerde
    AYRICA ikinci onay istenir, production dalgasi icin "production" yazilir,
  * komut ciktisi canli olarak kaydirilabilir bir metin kutusuna akar,
  * ekran yoksa (SSH/headless) veya tkinter kurulu degilse net TURKCE hata
    verir ve terminal menusunu onerir.

======================================================================
SOZLESME -- backend arareyuzu (bfos/operations.py ve bfos/runner.py icin)
======================================================================
Bu dosya is mantigini TAKLIT ETMEZ; onu bir "backend adapter" uzerinden
kullanir. Gercek moduller (bfos.operations, bfos.runner) yazildiginda asagidaki
sozlesmeyi saglamalari yeterlidir; ui_gui.py onlari otomatik olarak adapte eder.

Sozlesme (bu dosyada tanimli veri tipleriyle ayni alan adlari):

1) Operasyon listesi
   list_operations() -> Sequence[Operation]
   ya da OPERATIONS / OPS / OPERATION_CATALOGUE isimli bir dizi.
   Operation alanlari: id (str, tekil), label (str, TURKCE ad),
   category (str, su bes kategoriden biri: "Kurulum", "Cihaz islemleri",
   "Merkez hazirligi", "Araclar", "Cihaz bilgisi"), destructive (bool),
   scope ("local"|"simple"|"wave"|"release"), description (str),
   playbook (str, sadece filo islemleri icin "bf-*.yml" adi).

2) Hedef secimi
   Target(kind="dealer"|"group"|"all", value="12010193"|"pilot_1"|"all")
   - dealer -> Ansible --limit bf-<8 hane>, insan kimligi BF-<8 hane>
   - group  -> dalga/grup adi; wave/release kapsamli islemler SADECE onayli
     bir dalga grubu kabul eder (lab, pilot_1, pilot_2, wave_1, wave_2,
     production); release kapsamli islemler tek cihaz veya "all" KABUL ETMEZ.

3) Komut uretimi (calistirmadan)
   build_command(operation, target, options, grants=None, check_mode=False)
   -> CommandPlan
   CommandPlan:
     * commands    : her biri bir argv olan demet (satir listesi
                     `CommandPlan.lines` uzerinden shlex ile uretilir),
     * report_lines: SALT-OKUNUR rapor satirlari; commands bos ise hicbir sey
                     calistirilmaz, satirlar dogrudan gosterilir,
     * destructive / requires_root / operation_id / target_label / notes,
     * dry_run / check_mode.
   options   : {secenek_adi: str} (bkz. Operation.options)
   grants    : {"wave_gate_confirmed"|"production_override"|
                "allow_production_reboot"|"fleet_wide": bool} -- operatorun
               ACIK onaylari. Bir kapi bayragi yalniz onay verildiginde ve
               playbook o degiskeni kullaniyorsa komuta eklenir.
   check_mode: True ise komut --check ile uretilir (degisiklik uygulanmaz).

4) Kapi onaylari (acik onay adimlari)
   gate_steps(operation, target) -> Sequence[GateStepInfo]
   GateStepInfo(kind="token"|"approval", key, prompt, message, token, unlocks)
   - "token"    : operator kutulara `token` sozcugunu yazmak zorundadir
                  (dalga adi, "production", "GATE", "all"),
   - "approval" : evet/hayir onayi (yikici ikinci onay dahil),
   - unlocks    : onay verilince build_command'a gecirilecek grant adlari.
   Arayuz onaylarin TAMAMINI sorar; hicbir kapi sessizce gecilmez.

5) Komut calistirma (cikti + cikis kodu)
   run(plan, on_line=None, cancel=None) -> RunResult(exit_code, ok, output)
   on_line(str) her cikti satirinda cagrilir (canli akis icin);
   cancel threading.Event ile calisan komut sonlandirilir.

Uyumluluk icin adapter su adlari da dener (sirayla):
   katalog : catalogue_rows | ALL_OPERATIONS | list_operations | operations |
             get_operations | OPERATIONS | OPS
   komut   : build_command | build_plan | command_for | build_ansible_cmd
   kosum   : run | run_plan | run_command | execute
ve donus degerlerini (dict / dataclass / object) normalize eder.

bfos.operations ve bfos.runner MEVCUTSA (bu repodaki gercek moduller) arayuz
dogrudan onlari kullanir; hicbir kural kopyalanmaz:
   katalog        : catalogue_rows() / ALL_OPERATIONS
   envanter/hedef : Repository + Inventory.load_repository + resolve_target
   komut uretimi  : build_ansible_command / build_install_command /
                    build_tool_command / build_extra_vars
   kapilar        : confirmation_plan + GatesGranted
   denetim kaydi  : runner.AuditLog (+ runner.redact)
   salt-okunur ekranlar: targets_lines / central_*_lines / identity_lines /
                    state_lines / environment_lines
Gercek moduller yoksa dosya kendi YERLESIK KATALOG'unu kullanir: bu katalog
admin/bf-menu'nun tablosuyla (id, playbook, kapsam, yikici, ek degisken
kurallari) birebir ayni kurallara ve ayni komut uretimine dayanir.
======================================================================

Kullanim:
    python3 -m bfos.ui_gui             # basit mod
    python3 -m bfos.ui_gui --full      # dogrudan detayli mod
    python3 -m bfos.ui_gui --list      # pencere acmadan katalogu yazdir
    python3 -m bfos.ui_gui --dry-run   # komutlari goster, calistirma

Notlar:
  * tkinter Ubuntu'da hazir gelir (paket: python3-tk); indirme gerekmez.
  * Bu dosya tkinter olmadan da ice aktarilabilir: yardimci fonksiyonlar
    (dogrulama, komut onizleme, yikici siniflama, headless tespiti) tkinter'siz
    calisir, bu yuzden statik testler pencere ACMADAN kosar.
"""

from __future__ import annotations

import argparse
import os
import queue
import re
import shlex
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

# ---------------------------------------------------------------------------
# Sabitler -- kullanicinin gordugu TUM metinler Turkce
# ---------------------------------------------------------------------------
WINDOW_TITLE = "Blueforce Field OS — Yönetim"
APP_SUBTITLE = "Blueforce saha cihazı yönetimi (Kur / Durum / Bakım)"

# Basit modda gorunen uc buyuk buton (sira onemli).
SIMPLE_MODE_BUTTONS: tuple[str, ...] = ("Kur", "Durum", "Çıkış")
SIMPLE_MODE_LABEL = "Detaylı mod"
SIMPLE_MODE_BACK_LABEL = "Basit moda dön"

# Detayli moddaki kategori sekmeleri (docs/33 §9.2 ile ayni bes kategori).
CATEGORIES: tuple[str, ...] = (
    "Kurulum",
    "Cihaz işlemleri",
    "Merkez hazırlığı",
    "Araçlar",
    "Cihaz bilgisi",
)

# Onayli dalga sirasi (docs/10; admin/lib/targets.sh BF_WAVES ile ayni).
WAVES: tuple[str, ...] = ("lab", "pilot_1", "pilot_2", "wave_1", "wave_2", "production")
PRODUCTION_WAVE = "production"
GATE_TOKEN_RELEASE = "GATE"

DEALER_PATTERN = re.compile(r"^[0-9]{8}$")
SCOPE_LABELS: Mapping[str, str] = {
    "local": "yerel — bu cihaz",
    "simple": "filo — tek cihaz/grup (salt-okunur)",
    "wave": "filo — dalga kapılı",
    "release": "filo — sürüm kapılı (onaylı dalga)",
}

# admin/lib/targets.sh + admin/bf-menu ile ayni kurallar.
SERVICE_ALLOWLIST: tuple[str, ...] = (
    "blueforce-agent",
    "docker",
    "ssh",
    "sshd",
    "systemd-journald",
    "cron",
)
SCRIPT_DIRS: tuple[str, ...] = ("/opt/blueforce/bin", "/usr/local/sbin")
MODULE_PATTERN = re.compile(r"^[0-9]{2}-[a-z0-9][a-z0-9._-]*$")
PACKAGE_PIN_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.:-]*=.+$")
HOST_PATTERN = re.compile(r"^bf-[0-9]{8}$")
STATE_JSON_PATH = "/var/lib/blueforce/state.json"
STATE_ALLOWED_KEYS: tuple[str, ...] = (
    "phase",
    "enrollment_status",
    "fleet_status",
    "device_id",
    "provisioning_id",
)
INSTALL_STATE_PATH = "/var/lib/blueforce/install-state"
INSTALL_LOG_PATH = "/var/log/blueforce-install.log"

#: --check eklenebilecek yerel komutlar (kurulum betigi ve kapi araclari).
CHECK_CAPABLE_LOCAL_OPS: tuple[str, ...] = (
    "install-preflight",
    "install-local",
    "install-resume",
    "install-module",
    "tools-gate-local",
    "tools-gate-enrollment",
    "tools-gate-ready",
)
DEFAULT_CONSOLE_LOG = "/var/log/blueforce-console.log"
INSTALLER_REL = "scripts/install/blueforce-install.sh"
PLAYBOOK_DIR_REL = "ansible/playbooks"
MENU_REL = "admin/bf-menu"

TK_PACKAGE_HINT = "sudo apt install -y python3-tk"
TERMINAL_MENU_HINT = "sudo bf-menu"

# ---------------------------------------------------------------------------
# tkinter -- opsiyonel ice aktarma
# ---------------------------------------------------------------------------
class _MissingTk:
    """tkinter yoksa: kullanildigi anda Turkce hata veren yer tutucu.

    Amac iki yonlu: (1) modul tkinter'siz de ice aktarilabilir kalsin,
    (2) GUI kodundaki `tk.X`/`ttk.X` tip denetimi gecerli bir nesne gordugu
    icin None uzerinden gelen yanlis uyarilar uretilmesin.
    """

    def __getattr__(self, name: str):
        raise RuntimeError(
            "tkinter kurulu değil (" + TK_IMPORT_ERROR + "). "
            f"Kurmak için: {TK_PACKAGE_HINT}"
        )


try:  # pragma: no cover - ortama bagli
    import tkinter as tk
    from tkinter import messagebox, ttk
    from tkinter import scrolledtext

    HAVE_TKINTER = True
    TK_IMPORT_ERROR = ""
except Exception as _tk_exc:  # pragma: no cover - ortama bagli
    HAVE_TKINTER = False
    TK_IMPORT_ERROR = str(_tk_exc)
    tk = ttk = messagebox = scrolledtext = _MissingTk()  # type: ignore[assignment]



# ---------------------------------------------------------------------------
# Veri tipleri (backend sozlesmesi)
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class OptionSpec:
    """Bir islemin ek parametresi (bf-menu'deki -e degiskenleri)."""

    name: str
    label: str
    kind: str = "text"  # text | int | bool | choice
    default: str = ""
    choices: tuple[str, ...] = ()
    hint: str = ""
    required: bool = False
    validator: Callable[[str], "str | None"] | None = None


@dataclass(frozen=True)
class Operation:
    """Operasyon katalogu kaydi (sozlesme: bkz. dosya basligi)."""

    id: str
    label: str
    category: str
    destructive: bool = False
    scope: str = "local"  # local | simple | wave | release
    description: str = ""
    playbook: str = ""
    options: tuple[OptionSpec, ...] = ()
    requires_root: bool = False
    needs_dealer: bool = False

    @property
    def is_fleet(self) -> bool:
        return self.scope in ("simple", "wave", "release")


@dataclass(frozen=True)
class Target:
    """Hedef secimi: bayı no, dalga/grup adi ya da tum filo."""

    kind: str  # dealer | group | all
    value: str

    @property
    def limit(self) -> str:
        if self.kind == "dealer":
            return dealer_to_host(self.value)
        return self.value

    @property
    def label(self) -> str:
        if self.kind == "dealer":
            return f"cihaz {dealer_to_device_id(self.value)} ({dealer_to_host(self.value)})"
        if self.kind == "all":
            return "tüm filo (envanterdeki her cihaz)"
        if is_wave(self.value):
            return f"dalga '{self.value}'"
        return f"grup '{self.value}'"


@dataclass(frozen=True)
class GateStepInfo:
    """Calistirmadan once gereken ACIK operator onayi (sozlesme eki).

    kind : "token" (yazilarak) | "approval" (evet/hayir)
    token: kind == "token" ise yazilmasi gereken sozcuk
    unlocks: onay verilince backend'e gecirilecek bayrak adlari
             (or. "wave_gate_confirmed", "production_override")
    """

    kind: str
    key: str
    prompt: str
    message: str = ""
    token: str = ""
    unlocks: tuple[str, ...] = ()


@dataclass(frozen=True)
class CommandPlan:
    """Calistirilacak komutlar + ekranda gosterilecek satir listesi.

    `report_lines` dolu ve `commands` bos oldugunda plan HICBIR SEY calistirmaz:
    rapor satirlari (bfos.operations icindeki salt-okunur ekranlar) dogrudan
    gosterilir.
    """

    commands: tuple[tuple[str, ...], ...] = ()
    destructive: bool = False
    requires_root: bool = False
    operation_id: str = ""
    target_label: str = ""
    notes: tuple[str, ...] = ()
    report_lines: tuple[str, ...] = ()
    dry_run: bool = False
    check_mode: bool = False

    @property
    def lines(self) -> tuple[str, ...]:
        """Kopyala/yapistir edilebilir komut satirlari (bf-menu %q ile ayni fikir)."""
        return tuple(shlex.join(argv) for argv in self.commands if argv)

    @property
    def is_empty(self) -> bool:
        return not any(self.commands) and not self.report_lines

    @property
    def is_report_only(self) -> bool:
        return not any(self.commands) and bool(self.report_lines)


@dataclass
class RunResult:
    """Komut calistirma sonucu: cikti + cikis kodu (sozlesme maddesi 4)."""

    exit_code: int
    ok: bool
    output: str = ""


class BackendUnavailable(RuntimeError):
    """Gercek backend modulu var ama sozlesmeye uymuyor."""


class CommandError(RuntimeError):
    """Komut uretilemedi / secenek gecersiz (TURKCE mesaj tasir)."""


def _as_int(value: Any, default: int = 1) -> int:
    """Farkli backend'lerin cikis kodu tiplerini (int/str/None) guvenle cevirir."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# Saf yardimcilar: birim testleri bunlari pencere ACMADAN kullanir
# ---------------------------------------------------------------------------
def validate_dealer(value: str) -> bool:
    """Bayi no kapisi: ^[0-9]{8}$ (docs/02, K-12)."""
    return bool(DEALER_PATTERN.match(value or ""))


def dealer_error(value: str) -> str | None:
    """Gecerli ise None, degilse Turkce hata metni."""
    if validate_dealer(value):
        return None
    if not value:
        return "Bayi numarası boş olamaz. Tam 8 hane, yalnız rakam girin (örn. 12010193)."
    if not value.isdigit():
        return "Bayi numarası yalnız rakam içermelidir (harf, boşluk ve işaret kullanılamaz)."
    return (
        f"Geçersiz bayi numarası '{value}': tam 8 hane olmalıdır "
        f"(verilen uzunluk: {len(value)}). Örnek: 12010193"
    )


def dealer_to_host(dealer: str) -> str:
    return f"bf-{dealer}"


def dealer_to_device_id(dealer: str) -> str:
    return f"BF-{dealer}"


def host_to_dealer(host: str) -> str | None:
    return host[3:] if HOST_PATTERN.match(host or "") else None


def is_wave(name: str) -> bool:
    return name in WAVES


def validate_wave(value: str) -> str | None:
    """Dalga adini dogrular; gecerliyse None doner."""
    if value in WAVES:
        return None
    return (
        f"Geçersiz dalga '{value}'. Onaylı dalgalar (sırayla): {', '.join(WAVES)}."
    )


def validate_disk_pct(value: str) -> str | None:
    if value == "":
        return None
    if not value.isdigit() or not (1 <= int(value) <= 100):
        return "Eşik 1 ile 100 arasında bir tam sayı olmalıdır."
    return None


def validate_grace(value: str) -> str | None:
    if value == "":
        return None
    if not value.isdigit():
        return "Bekleme süresi saniye cinsinden bir tam sayı olmalıdır (örn. 300)."
    return None


def validate_log_lines(value: str) -> str | None:
    if value == "":
        return None
    if not value.isdigit() or int(value) < 1:
        return "Satır sayısı pozitif bir tam sayı olmalıdır (örn. 500)."
    return None


def validate_service_name(value: str) -> str | None:
    if value in SERVICE_ALLOWLIST:
        return None
    return (
        f"'{value}' izinli servis listesinde değil. İzinli olanlar: "
        f"{', '.join(SERVICE_ALLOWLIST)}."
    )


def validate_script_path(value: str) -> str | None:
    if not value:
        return "Script yolu boş olamaz."
    if not value.startswith("/"):
        return "Script yolu mutlak olmalıdır (örn. /opt/blueforce/bin/kontrol.sh)."
    if not any(value == d or value.startswith(d + "/") for d in SCRIPT_DIRS):
        return (
            "Script yolu izinli dizinlerin dışında. İzinli dizinler: "
            f"{', '.join(SCRIPT_DIRS)}."
        )
    return None


def validate_package_pins(value: str) -> str | None:
    if not value.strip():
        return "En az bir paket sürümü gerekir (biçim: paket=sürüm)."
    for pin in value.split(","):
        pin = pin.strip()
        if not pin:
            continue
        if not PACKAGE_PIN_PATTERN.match(pin):
            return (
                f"Geçersiz pin '{pin}': 'paket=sürüm' biçiminde olmalıdır "
                "(örn. docker-ce=5:27.0.3-1~ubuntu.24.04~noble)."
            )
    return None


def validate_module_name(value: str) -> str | None:
    if not value:
        return "Modül numarası boş olamaz (örn. 01-precheck)."
    if not MODULE_PATTERN.match(value):
        return (
            f"Geçersiz modül '{value}': '01-precheck' biçiminde olmalıdır "
            "(iki hane, tire, küçük harfli ad)."
        )
    return None


def validate_expected_version(value: str) -> str | None:
    if value == "":
        return None
    if any(ch.isspace() for ch in value):
        return "Sürüm boşluk içermemelidir (örn. 1.0.0)."
    return None


# ---------------------------------------------------------------------------
# Headless / tkinter hatalari -- net TURKCE yonlendirme
# ---------------------------------------------------------------------------
def headless_error(env: Mapping[str, str] | None = None) -> str | None:
    """Ekran yoksa Turkce aciklama doner; ekran varsa None.

    Sadece DISPLAY / WAYLAND_DISPLAY ortam degiskenlerine bakar, boylece
    pencere acmadan test edilebilir.
    """
    data = os.environ if env is None else env
    if data.get("DISPLAY") or data.get("WAYLAND_DISPLAY"):
        return None
    return (
        "Grafik ekran bulunamadı (DISPLAY ve WAYLAND_DISPLAY tanımlı değil).\n"
        "\n"
        "SSH veya başsız (headless) bir oturumda masaüstü penceresi açılamaz.\n"
        "Bu durumda terminal menüsünü kullanın:\n"
        f"\n    {TERMINAL_MENU_HINT}\n"
        "\n"
        "Yerel ekranda çalıştırmak için oturum açık bir makinede deneyin:\n"
        "    python3 -m bfos.ui_gui\n"
    )


def tkinter_missing_message(error: str = "") -> str:
    """tkinter kurulu degilse Turkce hata + kurulum ipucu."""
    detail = f" (teknik ayrıntı: {error})" if error else ""
    return (
        "tkinter bulunamadı; masaüstü arayüzü başlatılamıyor"
        f"{detail}.\n"
        "\n"
        "Bu, minimal kurulumlarda sık görülür: tkinter ayrı bir sistem paketidir.\n"
        "Ubuntu/Debian üzerinde kurmak için:\n"
        f"\n    {TK_PACKAGE_HINT}\n"
        "    sudo apt update && sudo apt install -y python3-tk\n"
        "\n"
        f"tkinter kurmak istemiyorsanız terminal menüsünü kullanın: {TERMINAL_MENU_HINT}\n"
    )


def window_start_error(exc: BaseException) -> str:
    """Tk() acilamazsa (DISPLAY var ama X/Wayland erisilemiyor) Turkce mesaj."""
    return (
        "Pencere açılamadı; grafik oturumuna erişilemiyor.\n"
        f"Teknik ayrıntı: {exc}\n"
        "\n"
        "Muhtemel nedenler:\n"
        "  * SSH oturumundasınız ve X yönlendirmesi (ssh -X) yok,\n"
        "  * ekran kilitli veya grafik oturum kapalı,\n"
        "  * başka bir kullanıcının X sunucusuna bağlanmaya çalışıyorsunuz.\n"
        f"\nTerminal menüsünü kullanın: {TERMINAL_MENU_HINT}\n"
    )


# ---------------------------------------------------------------------------
# Onizleme metni (onay pencereleri ve kayit icin tek kaynak)
# ---------------------------------------------------------------------------
def preview_text(
    plan: CommandPlan,
    *,
    operation: Operation | None = None,
    target: Target | None = None,
) -> str:
    """Calistirilacak komutu gosteren Turkce onay metni."""
    parts: list[str] = []
    if plan.is_report_only:
        parts.append("Bu ekran komut çalıştırmaz; salt-okunur rapor gösterir:")
        parts.append("")
        for line in plan.report_lines:
            parts.append(f"    {line}")
        parts.append("")
    else:
        parts.append("Çalıştırılacak komut(lar):")
        parts.append("")
        if plan.is_empty:
            parts.append("    (komut üretilemedi)")
        for line in plan.lines:
            parts.append(f"    {line}")
        parts.append("")
    if operation is not None:
        parts.append(f"İşlem  : {operation.label}  [{operation.id}]")
        parts.append(f"Kapsam : {SCOPE_LABELS.get(operation.scope, operation.scope)}")
        if operation.description:
            parts.append(f"Açıklama: {operation.description}")
    if target is not None:
        parts.append(f"Hedef  : {target.label}")
    elif plan.target_label:
        parts.append(f"Hedef  : {plan.target_label}")
    if plan.requires_root:
        parts.append("Yetki  : root gerekir — konsolu sudo ile açın.")
    if plan.check_mode:
        parts.append("Kip    : --check (deneme) — hiçbir değişiklik uygulanmaz.")
    if plan.dry_run:
        parts.append("Kip    : DENEME (--dry-run) — komut çalıştırılmaz, yalnız gösterilir.")
    if plan.destructive:
        parts.append("")
        parts.append("UYARI: Bu YIKICI bir işlemdir; seçili hedefte değişiklik yapar.")
    for note in plan.notes:
        parts.append(f"Not    : {note}")
    return "\n".join(parts)


def destructive_operations(
    operations: Sequence[Operation] | None = None,
) -> tuple[str, ...]:
    """Yikici isaretli operasyonlarin id'leri."""
    ops = OPERATIONS if operations is None else operations
    return tuple(op.id for op in ops if op.destructive)


def operation_is_destructive(operation_id: str) -> bool:
    op = operation_by_id(operation_id)
    return bool(op and op.destructive)


# ---------------------------------------------------------------------------
# Yerlesik katalog -- admin/bf-menu tablosuyla ayni id/kapsam/yikici degerleri
# (kaynak: admin/bf-menu BF_OPS_REPORT / BF_OPS_MAINTENANCE)
# ---------------------------------------------------------------------------
_FLEET_OPTIONS: Mapping[str, tuple[OptionSpec, ...]] = {
    "disk": (
        OptionSpec(
            "disk_warn_pct",
            "Uyarı eşiği (%)",
            kind="int",
            default="",
            hint="Boş = playbook varsayılanı (80)",
            validator=validate_disk_pct,
        ),
    ),
    "fieldos-version": (
        OptionSpec(
            "fieldos_expected_version",
            "Beklenen Field OS sürümü",
            default="",
            hint="Boş = drift denetimi atlanır",
            validator=validate_expected_version,
        ),
    ),
    "service-restart": (
        OptionSpec(
            "service_name",
            "Servis adı",
            kind="choice",
            choices=SERVICE_ALLOWLIST,
            required=True,
            hint="Yalnız izinli servis adları",
            validator=validate_service_name,
        ),
    ),
    "run-script": (
        OptionSpec(
            "script_path",
            "Script yolu",
            required=True,
            hint=f"İzinli dizinler: {', '.join(SCRIPT_DIRS)}",
            validator=validate_script_path,
        ),
        OptionSpec("script_args", "Script argümanları", default="", hint="İsteğe bağlı"),
    ),
    "collect-logs": (
        OptionSpec(
            "log_lines",
            "Cihaz başına journal satırı",
            kind="int",
            default="500",
            validator=validate_log_lines,
        ),
    ),
    "reboot": (
        OptionSpec(
            "reboot_grace_seconds",
            "Yeniden başlatma bekleme süresi (saniye)",
            kind="int",
            default="300",
            validator=validate_grace,
        ),
    ),
    "deploy-update": (
        OptionSpec(
            "update_packages",
            "Paket pinleri (paket=sürüm, virgülle)",
            required=True,
            hint="Örn. docker-ce=5:27.0.3-1~ubuntu.24.04~noble",
            validator=validate_package_pins,
        ),
    ),
}

OPERATIONS: tuple[Operation, ...] = (
    # --- Kurulum (bu cihaz; filo cihazina DOKUNMAZ) ------------------------
    Operation(
        "install-preflight",
        "Kurulum ön kontrolü (--check)",
        "Kurulum",
        destructive=False,
        scope="local",
        description="Hiçbir şey yazmadan kurulum ön koşullarını raporlar.",
        needs_dealer=True,
    ),
    Operation(
        "install-local",
        "Bu cihazı kur",
        "Kurulum",
        destructive=True,
        scope="local",
        description="Cihazı kurar, hostname'i bf-<bayi-no> yapar.",
        requires_root=True,
        needs_dealer=True,
        options=(
            OptionSpec("offline", "Yerel çevrimdışı depodan kur (--offline)", kind="bool"),
            OptionSpec("resume", "Zaten OK olan modülleri atla (--resume)", kind="bool"),
        ),
    ),
    Operation(
        "install-resume",
        "Başarısız kuruluma devam et (--resume)",
        "Kurulum",
        destructive=True,
        scope="local",
        description="Yarıda kalan kurulumu idempotent biçimde sürdürür.",
        requires_root=True,
        needs_dealer=True,
    ),
    Operation(
        "install-module",
        "Tek modül çalıştır (--only)",
        "Kurulum",
        destructive=True,
        scope="local",
        description="Kurulumun tek bir modülünü çalıştırır.",
        requires_root=True,
        needs_dealer=True,
        options=(
            OptionSpec(
                "only",
                "Modül",
                required=True,
                hint="Örn. 01-precheck",
                validator=validate_module_name,
            ),
        ),
    ),
    Operation(
        "install-state",
        "Kurulum modül durumu",
        "Kurulum",
        destructive=False,
        scope="local",
        description="Kurulumun hangi modülde kaldığını gösterir (salt-okunur).",
    ),
    Operation(
        "install-log",
        "Kurulum günlüğü (son 40 satır)",
        "Kurulum",
        destructive=False,
        scope="local",
        description="Kurulum günlüğünün sonunu gösterir (salt-okunur).",
    ),
    # --- Cihaz islemleri: salt-okunur raporlar -----------------------------
    Operation("ping", "Ping / erişilebilirlik", "Cihaz işlemleri", False, "simple",
              "SSH erişilebilirliği (salt-okunur).", "bf-ping.yml"),
    Operation("uptime", "Çalışma süresi ve yük", "Cihaz işlemleri", False, "simple",
              "Uptime ve yük ortalaması (salt-okunur).", "bf-uptime.yml"),
    Operation("disk", "Disk kullanımı", "Cihaz işlemleri", False, "simple",
              "Disk kullanımı; eşik üstünde uyarır.", "bf-disk-check.yml",
              options=_FLEET_OPTIONS["disk"]),
    Operation("docker", "Docker durumu", "Cihaz işlemleri", False, "simple",
              "Docker servisi ve konteynerler (salt-okunur).", "bf-docker-status.yml"),
    Operation("packages", "Kurulu paket sürümleri", "Cihaz işlemleri", False, "simple",
              "Pinlenmiş paketlerin kurulu sürümleri.", "bf-package-check.yml"),
    Operation("security-updates", "Bekleyen güvenlik güncellemeleri", "Cihaz işlemleri",
              False, "simple", "Yalnız rapor; hiçbir güncelleme kurmaz.",
              "bf-security-updates-check.yml"),
    Operation("provisioning-status", "Kurulum fazı raporu", "Cihaz işlemleri", False,
              "wave", "Cihaz başına state.json fazı.", "bf-provisioning-status.yml"),
    Operation("enrollment-status", "Kayıt (enrollment) ve merkez kanıtı",
              "Cihaz işlemleri", False, "wave",
              "ENROLLED/READY iddialarını merkezi kanıta karşı denetler.",
              "bf-enrollment-status.yml"),
    Operation("fieldos-version", "Field OS sürüm raporu", "Cihaz işlemleri", False, "wave",
              "Sürüm bilgisi; istenirse drift denetimi.", "bf-fieldos-version.yml",
              options=_FLEET_OPTIONS["fieldos-version"]),
    Operation("remote-channels", "Uzak erişim kanalları", "Cihaz işlemleri", False, "wave",
              "SSH/xRDP/RustDesk/WireGuard hazırlığı.", "bf-remote-channels-check.yml"),
    Operation("offline-ready", "Çevrimdışı hazırlık raporu", "Cihaz işlemleri", False, "wave",
              "Offline provisioning yerel ön koşulları.", "bf-offline-ready-check.yml"),
    # --- Cihaz islemleri: bakim (yikici olanlar isaretli) -------------------
    Operation("rdp-restart", "xRDP servisini yeniden başlat", "Cihaz işlemleri", True,
              "simple", "xRDP servisini yeniden başlatır (RDP açık kalır).",
              "bf-rdp-restart.yml"),
    Operation("rustdesk-restart", "RustDesk servisini yeniden başlat", "Cihaz işlemleri",
              True, "simple", "RustDesk servisini yeniden başlatır.", "bf-rustdesk-restart.yml"),
    Operation("wireguard-restart", "WireGuard (wg0) yeniden başlat", "Cihaz işlemleri", True,
              "simple", "wg-quick@wg0 servisini yeniden başlatır.", "bf-wireguard-restart.yml"),
    Operation("service-restart", "İzinli servisi yeniden başlat", "Cihaz işlemleri", True,
              "simple", "Yalnız izinli servis adlarını yeniden başlatır.",
              "bf-service-restart.yml", options=_FLEET_OPTIONS["service-restart"]),
    Operation("gui-off", "Yerel grafik oturumu kapat (headless)", "Cihaz işlemleri", True,
              "wave", "Dalgayı multi-user.target'e alır; xRDP'yi durdurmaz.", "bf-gui-off.yml"),
    Operation("gui-on", "Yerel grafik oturumu aç (bakım)", "Cihaz işlemleri", True, "wave",
              "Grafik oturumu yeniden açar (bakım için).", "bf-gui-on.yml"),
    Operation("collect-logs", "Günlük topla / destek paketi", "Cihaz işlemleri", False,
              "wave", "Zaman damgalı journal + destek paketi üretir.", "bf-collect-logs.yml",
              options=_FLEET_OPTIONS["collect-logs"]),
    Operation("run-script", "Onaylı script çalıştır", "Cihaz işlemleri", True, "wave",
              "Yalnız onaylı dizinlerdeki scriptleri çalıştırır.", "bf-run-script.yml",
              options=_FLEET_OPTIONS["run-script"]),
    Operation("reboot", "Kontrollü yeniden başlatma", "Cihaz işlemleri", True, "release",
              "Seri yeniden başlatma + sağlık kapısı.", "bf-reboot.yml",
              options=_FLEET_OPTIONS["reboot"]),
    Operation("deploy-update", "Onaylı paket güncellemesi", "Cihaz işlemleri", True,
              "release", "package=sürüm pinleri + dalga ve sağlık kapıları.",
              "bf-deploy-update.yml", options=_FLEET_OPTIONS["deploy-update"]),
    # --- Merkez hazirligi (salt-okunur denetim; merkez SUNUCUSU kurulmaz) ---
    Operation("central-targets", "Envanter hedefleri (dalga/grup/cihaz sayıları)",
              "Merkez hazırlığı", False, "local",
              "Envanteri ve dalga gruplarını listeler; hiçbir cihaza dokunmaz."),
    Operation("central-placeholders", "Doldurulmamış PLACEHOLDER denetimi",
              "Merkez hazırlığı", False, "local",
              "group_vars/all.yml içinde kalan PLACEHOLDER değerlerini gösterir."),
    Operation("central-endpoints", "Yapılandırılmış merkez uç noktaları",
              "Merkez hazırlığı", False, "local",
              "WireGuard hub, izleme ve depo uç noktalarını (secret hariç) gösterir."),
    Operation("central-checklist", "Merkez hazırlık kontrol listesi",
              "Merkez hazırlığı", False, "local",
              "Kayıttan önce merkezde var olması gerekenleri hatırlatır."),
    # --- Araclar -----------------------------------------------------------
    Operation("tools-catalogue", "İşlem kataloğunu göster (--list)", "Araçlar", False,
              "local", "Konsolun işlem kataloğunu listeler."),
    Operation("tools-git-pull", "Bu kopyayı güncelle (git pull --ff-only)", "Araçlar", True,
              "local", "Depo kopyasını ileri sarar; yerel değişikliği silmez."),
    Operation("tools-gate-local", "Yerel çevrimdışı kapısı (bf-check-local)", "Araçlar",
              False, "local", "Cihazın çevrimdışı kurulum ön koşullarını denetler."),
    Operation("tools-gate-enrollment", "Kayıt kapısı (bf-check-enrollment)", "Araçlar",
              False, "local", "Kayıt (enrollment) ön koşullarını denetler."),
    Operation("tools-gate-ready", "Teslim kapısı (bf-check-ready)", "Araçlar", False,
              "local", "Cihazın READY olabilmesi için gerekenleri denetler."),
    Operation("tools-diagnostics", "Derin teşhis (bf-diagnostics)", "Araçlar", False,
              "local", "Kapsamlı teşhis raporu üretir (salt-okunur)."),
    Operation("tools-release", "Field OS sürüm kimliği (bf-release)", "Araçlar", False,
              "local", "Cihazdaki Field OS sürümünü gösterir."),
    Operation("tools-support-bundle", "Destek paketi oluştur", "Araçlar", False, "local",
              "Parola/anahtar içermeyen destek paketi üretir."),
    Operation("tools-console-log", "Konsol denetim günlüğü (son 40 satır)", "Araçlar",
              False, "local", "Operatör konsolunun denetim günlüğünü gösterir."),
    # --- Cihaz bilgisi (salt-okunur) ---------------------------------------
    Operation("info-summary", "Durum özeti (sağlık + kurulum durumu)", "Cihaz bilgisi",
              False, "local",
              "bf-status, whitelist'li state.json alanları ve envanter hedefleri."),
    Operation("info-identity", "Kimlik (hostname, cihaz no)", "Cihaz bilgisi", False,
              "local", "Makine adı ve cihaz kimliği."),
    Operation("info-network", "Ağ (adres, rota, DNS, WireGuard)", "Cihaz bilgisi", False,
              "local", "Ağ arayüzleri, varsayılan rota, DNS ve WireGuard durumu."),
    Operation("info-resources", "Disk, bellek, yük", "Cihaz bilgisi", False, "local",
              "Dosya sistemleri, bellek ve yük ortalaması."),
    Operation("info-packages", "Kurulu pinlenmiş paketler", "Cihaz bilgisi", False, "local",
              "docker-ce, wireguard, rustdesk, xrdp, openssh-server sürümleri."),
    Operation("info-services", "Servis durumu", "Cihaz bilgisi", False, "local",
              "ssh, xrdp, rustdesk, docker, wg-quick@wg0, cron durumu."),
    Operation("info-journal", "Son journal hataları", "Cihaz bilgisi", False, "local",
              "journalctl -p err son 20 satır."),
    Operation("info-state", "Kurulum/kayıt durumu (state.json beyaz liste)", "Cihaz bilgisi",
              False, "local",
              "Yalnız kimlik/durum alanları okunur; token ve anahtar asla gösterilmez."),
)

_OPERATION_INDEX: Mapping[str, Operation] = {op.id: op for op in OPERATIONS}


def operation_by_id(operation_id: str) -> Operation | None:
    return _OPERATION_INDEX.get(operation_id)


def operations_by_category(category: str) -> tuple[Operation, ...]:
    return tuple(op for op in OPERATIONS if op.category == category)


# ---------------------------------------------------------------------------
# Yardimci: yol cozumleme (admin/bf-menu ile ayni kurallar)
# ---------------------------------------------------------------------------
def repo_root_from_file() -> Path:
    """bfos/ui_gui.py -> depo koku (bir ust dizin)."""
    return Path(__file__).resolve().parents[1]


def resolve_inventory(repo_root: Path, explicit: str | None = None) -> Path | None:
    if explicit:
        candidate = Path(explicit).expanduser()
        return candidate if candidate.is_file() else None
    base = repo_root / "ansible" / "inventory"
    for name in ("hosts.yml", "hosts.yaml", "hosts", "hosts.ini"):
        candidate = base / name
        if candidate.is_file():
            return candidate
    return None


def resolve_tool(name: str, repo_root: Path | None = None) -> str | None:
    """admin/bf-menu bf_tool_path ile ayni sira: /usr/local/bin, sonra depo."""
    system = Path("/usr/local/bin") / name
    if system.is_file() and os.access(system, os.X_OK):
        return str(system)
    root = repo_root or repo_root_from_file()
    for sub in ("scripts/diagnostics", "scripts/maintenance"):
        candidate = root / sub / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def playbook_path(repo_root: Path, playbook: str) -> Path:
    return repo_root / PLAYBOOK_DIR_REL / playbook


def playbook_declares_var(path: Path, var: str) -> bool:
    """Playbook dosyasi VAR'i (yorum satirlari haric) kullaniyor mu?

    admin/bf-menu -> bf_playbook_var_present ile ayni fikir: playbook kendi
    kapisinin kaynagi kalir, konsol onu varsaymaz.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    pattern = re.compile(rf"\b{re.escape(var)}\b")
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if pattern.search(line):
            return True
    return False


def playbook_scope(path: Path) -> str:
    """Playbook'un kendi beyan ettigi kapsam: release | wave | simple."""
    if playbook_declares_var(path, "release_wave"):
        return "release"
    if playbook_declares_var(path, "operation_wave"):
        return "wave"
    return "simple"


def parse_inventory(path: Path) -> dict[str, list[str]]:
    """Salt-okunur envanter okuma: {grup: [host, ...]}.

    admin/lib/targets.sh -> bf_inventory_pairs awk okuyucusunun Python
    karsiligi: `hosts:` bloklarini iceren en yakin grup anahtari kullanilir.
    Amac yalnizca hedef listesi/dalga listesi doldurmak; hicbir sey yazilmaz.
    """
    groups: dict[str, list[str]] = {}
    stack: list[tuple[int, str]] = []
    hosts_indent: int | None = None
    hosts_step: int | None = None
    hosts_group = ""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return groups

    for raw in lines:
        if raw.lstrip().startswith("#") or not raw.strip() or raw.lstrip().startswith("-"):
            continue
        if ":" not in raw:
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        key, _, value = raw.partition(":")
        key = key.strip().strip("\"'")
        value = value.strip().strip("\"'")
        if not key:
            continue
        while stack and stack[-1][0] >= indent:
            stack.pop()

        if key == "hosts" and value == "":
            hosts_indent = indent
            hosts_step = None
            hosts_group = stack[-1][1] if stack else ""
            stack.append((indent, key))
            continue
        if hosts_indent is not None and indent <= hosts_indent:
            hosts_indent = None
            hosts_step = None

        if hosts_indent is not None and indent > hosts_indent:
            if hosts_step is None:
                hosts_step = indent
            if indent == hosts_step and hosts_group:
                groups.setdefault(hosts_group, []).append(key)
                stack.append((indent, key))
                continue
        if value == "":
            stack.append((indent, key))
    return groups


def waves_in_inventory(groups: Mapping[str, Sequence[str]]) -> tuple[str, ...]:
    """Envanterde gercekten bulunan onayli dalgalar (yayilim sirasiyla)."""
    return tuple(wave for wave in WAVES if groups.get(wave))


def device_wave(host: str, groups: Mapping[str, Sequence[str]]) -> str | None:
    for wave in WAVES:
        if host in (groups.get(wave) or ()):
            return wave
    return None


# ---------------------------------------------------------------------------
# Komut calistirma (sozlesme maddesi 4)
# ---------------------------------------------------------------------------
def run_command(
    argv: Sequence[str],
    on_line: Callable[[str], None] | None = None,
    cancel: threading.Event | None = None,
    cwd: str | None = None,
) -> RunResult:
    """Tek komutu calistirir; ciktisi satir satir `on_line`'a akar."""
    argv = [str(a) for a in argv]
    if not argv:
        return RunResult(2, False, "Boş komut çalıştırılamaz.")
    emit = on_line or (lambda _line: None)
    try:
        proc = subprocess.Popen(  # noqa: S603 - argv listesi, shell yok
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=cwd,
        )
    except FileNotFoundError:
        message = (
            f"Komut bulunamadı: '{argv[0]}' bu cihazda kurulu değil. "
            "Araçları bağlamak için: sudo admin/bf-bootstrap.sh"
        )
        emit(message)
        return RunResult(127, False, message + "\n")
    except OSError as exc:
        message = f"Komut başlatılamadı: {' '.join(argv)} ({exc})"
        emit(message)
        return RunResult(126, False, message + "\n")

    collected: list[str] = []
    assert proc.stdout is not None
    for line in proc.stdout:
        collected.append(line)
        emit(line.rstrip("\n"))
        if cancel is not None and cancel.is_set():
            proc.terminate()
            note = "Kullanıcı iptal etti; komut sonlandırıldı."
            collected.append(note + "\n")
            emit(note)
            break
    exit_code = proc.wait()
    return RunResult(exit_code, exit_code == 0, "".join(collected))


def run_plan(
    plan: CommandPlan,
    on_line: Callable[[str], None] | None = None,
    cancel: threading.Event | None = None,
    cwd: str | None = None,
) -> RunResult:
    """Plan icindeki komutlari sirayla calistirir; ilk hatada DURUR.

    (Wave akisindaki "bir dalga basarisizsa sonraki dalgaya gecme" kuralinin
    basit karsiligi: hata sonrasi komut calistirilmaz.)
    """
    emit = on_line or (lambda _line: None)
    if plan.is_empty:
        return RunResult(2, False, "Çalıştırılacak komut yok.\n")
    if plan.is_report_only:
        for line in plan.report_lines:
            emit(line)
        return RunResult(0, True, "\n".join(plan.report_lines) + "\n")
    if plan.dry_run:
        for line in plan.lines:
            emit(f"[deneme] {line}")
        return RunResult(0, True, "[deneme] komut çalıştırılmadı.\n")

    chunks: list[str] = []
    for index, argv in enumerate(plan.commands, start=1):
        if not argv:
            continue
        if len(plan.commands) > 1:
            emit(f"--- [{index}/{len(plan.commands)}] {shlex.join(argv)}")
        result = run_command(argv, on_line=emit, cancel=cancel, cwd=cwd)
        chunks.append(result.output)
        if not result.ok:
            emit(f"[HATA] Komut {result.exit_code} koduyla bitti: {shlex.join(argv)}")
            return RunResult(result.exit_code, False, "".join(chunks))
    return RunResult(0, True, "".join(chunks))


# ---------------------------------------------------------------------------
# Backend: yerlesik katalog (admin/bf-menu kurallari) + gercek modul adapteri
# ---------------------------------------------------------------------------
@dataclass
class GuiContext:
    """Arayuzun calisma baglami (yol ve kip bilgisi)."""

    repo_root: Path = field(default_factory=repo_root_from_file)
    inventory: Path | None = None
    console_log: str = DEFAULT_CONSOLE_LOG
    dry_run: bool = False

    @classmethod
    def detect(cls, repo: str | None = None, inventory: str | None = None,
               dry_run: bool = False) -> "GuiContext":
        root = Path(repo).expanduser().resolve() if repo else repo_root_from_file()
        return cls(
            repo_root=root,
            inventory=resolve_inventory(root, inventory),
            console_log=os.environ.get("BF_CONSOLE_LOG", DEFAULT_CONSOLE_LOG),
            dry_run=dry_run,
        )


class CatalogueBackend:
    """Yerlesik katalog: admin/bf-menu'nun tablosu + komut uretimi.

    Gercek moduller (bfos.operations / bfos.runner) yoksa arayuz bunu kullanir;
    boylece GUI, backend yazilmadan once de dogru komutu gosterip calistirabilir.
    """

    name = "yerleşik katalog (admin/bf-menu kuralları)"

    def __init__(self, ctx: GuiContext):
        self.ctx = ctx
        self._groups: dict[str, list[str]] | None = None

    # -- envanter (salt-okunur) -------------------------------------------
    @property
    def groups(self) -> dict[str, list[str]]:
        if self._groups is None:
            self._groups = (
                parse_inventory(self.ctx.inventory) if self.ctx.inventory else {}
            )
        return self._groups

    def list_operations(self) -> tuple[Operation, ...]:
        return OPERATIONS

    def list_waves(self) -> tuple[str, ...]:
        present = waves_in_inventory(self.groups)
        return present or WAVES

    def inventory_note(self) -> str:
        if self.ctx.inventory is None:
            note = (
                "Ansible envanteri bulunamadı (ansible/inventory/hosts.yml). "
                "Filo işlemleri için envanteri oluşturun: "
                "cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml"
            )
        else:
            note = f"Envanter: {self.ctx.inventory}"
        if shutil.which("ansible-playbook") is None:
            note += (
                "  |  UYARI: ansible-playbook bulunamadı; filo işlemleri çalışmaz "
                "(sudo apt install ansible)."
            )
        return note

    # -- hedef -------------------------------------------------------------
    def validate_target(self, operation: Operation, target: Target) -> str | None:
        if target.kind == "dealer":
            problem = dealer_error(target.value)
            if problem:
                return problem
        if operation.scope in ("wave", "release"):
            if target.kind == "dealer":
                if self.ctx.inventory is None:
                    return (
                        "Bu işlem dalga kapılıdır ve cihazın dalgasını çözmek için "
                        "envanter gerekir; envanter bulunamadı."
                    )
                wave = device_wave(dealer_to_host(target.value), self.groups)
                if not wave:
                    return (
                        f"{dealer_to_host(target.value)} onaylı bir dalga grubunda değil "
                        f"({', '.join(WAVES)}). Önce cihazı dalgasına ekleyin."
                    )
            elif target.kind == "all":
                if operation.scope == "release":
                    return (
                        "Sürüm kapılı işlemler tüm filo ile çalıştırılamaz: "
                        "onaylı bir dalga grubu seçin (dalga dalga yayılım)."
                    )
            elif target.kind == "group" and not is_wave(target.value):
                return (
                    f"'{target.value}' onaylı bir dalga değil. Dalga kapılı işlemler "
                    f"şu dalgalardan birini ister: {', '.join(WAVES)}."
                )
        return None

    def target_wave(self, operation: Operation, target: Target) -> str | None:
        if target.kind == "group" and is_wave(target.value):
            return target.value
        if target.kind == "dealer":
            return device_wave(dealer_to_host(target.value), self.groups)
        return None

    # -- kapilar (acik onay adimlari) ---------------------------------------
    def gate_steps(
        self, operation: Operation, target: Target | None
    ) -> tuple[GateStepInfo, ...]:
        """Calistirmadan once sorulacak ACIK onaylar (bf-menu ile ayni kurallar).

        Hicbir kapi sessizce gecilmez: dalga adi yazdirilir, production icin
        ayrica `production` yazilir, surum kapisi icin GATE yazilir, yikici
        islemler icin ikinci onay istenir.
        """
        steps: list[GateStepInfo] = []
        wave = self.target_wave(operation, target) if target else None
        book = (
            playbook_path(self.ctx.repo_root, operation.playbook)
            if operation.playbook
            else None
        )
        gate_supported = bool(book and playbook_declares_var(book, "wave_gate_confirmed"))

        if operation.scope in ("wave", "release") and wave:
            if wave == PRODUCTION_WAVE:
                steps.append(
                    GateStepInfo(
                        kind="token",
                        key="production_token",
                        prompt="PRODUCTION onayı — canlı filo",
                        message=(
                            "Seçilen dalga canlı filodur (production).\n"
                            "Onaylamak için kutuya 'production' yazın; başka bir şey iptal eder."
                            + ("\nEk olarak dalga kapısı bayrağı onaylanacak." if gate_supported else "")
                        ),
                        token=PRODUCTION_WAVE,
                        unlocks=("wave_gate_confirmed",) if gate_supported else (),
                    )
                )
                steps.append(
                    GateStepInfo(
                        kind="approval",
                        key="production_approval",
                        prompt="Production ek onayı",
                        message=(
                            "production_override / allow_production_reboot bayrakları "
                            "yalnız bu onayla eklenir (playbook ilgili değişkeni "
                            "kullanıyorsa).\nDevam edilsin mi?"
                        ),
                        unlocks=("production_override", "allow_production_reboot"),
                    )
                )
            elif operation.scope == "release" and gate_supported:
                steps.append(
                    GateStepInfo(
                        kind="token",
                        key="wave_gate_token",
                        prompt=f"Sürüm kapısı onayı (dalga: {wave})",
                        message=(
                            f"'{wave}' dalgası için sürüm kapısını onaylıyorsunuz.\n"
                            f"Önceki dalga sağlık kapısını geçtiyse '{GATE_TOKEN_RELEASE}' yazın."
                        ),
                        token=GATE_TOKEN_RELEASE,
                        unlocks=("wave_gate_confirmed",),
                    )
                )
        if target is not None and target.kind == "all" and operation.scope == "simple":
            steps.append(
                GateStepInfo(
                    kind="token",
                    key="fleet_token",
                    prompt="FİLO GENELİ onayı",
                    message=(
                        "Komut envanterdeki HER cihaza uygulanacak.\n"
                        "Onaylamak için kutuya 'all' yazın."
                    ),
                    token="all",
                    unlocks=("fleet_wide",),
                )
            )
        if operation.destructive:
            steps.append(
                GateStepInfo(
                    kind="approval",
                    key="destructive_approval",
                    prompt="İKİNCİ ONAY — yıkıcı işlem",
                    message=(
                        f"'{operation.label}' seçili hedefte DEĞİŞİKLİK YAPAR.\n"
                        "Bu onay yalnız bu işlem için geçerlidir. Devam edilsin mi?"
                    ),
                )
            )
        return tuple(steps)

    # -- komut uretimi -----------------------------------------------------
    def build_command(
        self,
        operation: Operation,
        target: Target | None = None,
        options: Mapping[str, str] | None = None,
        grants: Mapping[str, bool] | None = None,
        check_mode: bool = False,
    ) -> CommandPlan:
        opts = dict(options or {})
        self._check_options(operation, opts)
        if operation.scope in ("wave", "release") and target is not None:
            problems = self.validate_target(operation, target)
            if problems:
                raise CommandError(problems)
        if operation.is_fleet:
            return self._build_fleet_plan(operation, target, opts, dict(grants or {}), check_mode)
        return self._build_local_plan(operation, target, opts, check_mode)

    def _check_options(self, operation: Operation, opts: Mapping[str, str]) -> None:
        for spec in operation.options:
            value = (opts.get(spec.name) or "").strip()
            if spec.required and not value:
                raise CommandError(f"'{spec.label}' zorunludur ({operation.label}).")
            if value and spec.validator:
                problem = spec.validator(value)
                if problem:
                    raise CommandError(problem)

    def _build_fleet_plan(
        self,
        operation: Operation,
        target: Target | None,
        opts: Mapping[str, str],
        grants: Mapping[str, bool],
        check_mode: bool = False,
    ) -> CommandPlan:
        if target is None or not target.value:
            raise CommandError(
                "Hedef seçilmedi; komut üretilmedi. Bayi numarası veya dalga grubu seçin."
            )
        problem = self.validate_target(operation, target)
        if problem:
            raise CommandError(problem)
        if self.ctx.inventory is None:
            raise CommandError(
                "Ansible envanteri bulunamadı; filo işlemleri komutu üretilemiyor. "
                "Beklenen yol: ansible/inventory/hosts.yml (veya --inventory PATH)."
            )
        book = playbook_path(self.ctx.repo_root, operation.playbook)
        if not book.is_file():
            raise CommandError(
                f"Playbook bulunamadı: {PLAYBOOK_DIR_REL}/{operation.playbook}\n"
                "Doğru depo kopyasında çalıştırın (--repo PATH) veya checkout'u güncelleyin."
            )
        declared = playbook_scope(book)
        if declared != operation.scope:
            raise CommandError(
                f"{operation.playbook} çalıştırılmıyor: konsol kapsamı '{operation.scope}' "
                f"beklerken playbook '{declared}' beyan ediyor.\n"
                "Playbook kapıların kaynağıdır; tablo ile playbook'u eşitleyin "
                "(admin/bf-menu -> bf_playbook_check ile aynı kural)."
            )

        wave = self.target_wave(operation, target)
        if operation.scope in ("wave", "release") and not wave:
            raise CommandError(
                "Bu işlem dalga kapsamlıdır ama hedefte onaylı bir dalga yok. "
                "Bir dalga grubu seçin (" + ", ".join(WAVES) + ")."
            )

        argv: list[str] = [
            "ansible-playbook",
            "-i",
            str(self.ctx.inventory),
            str(book),
            "--limit",
            target.limit,
        ]
        notes: list[str] = []
        if operation.scope == "wave":
            argv += ["-e", f"operation_wave={wave}", "-e", "operation_confirmed=true"]
            if (
                wave == PRODUCTION_WAVE
                and grants.get("production_override")
                and playbook_declares_var(book, "production_override")
            ):
                argv += ["-e", "production_override=true"]
            notes.append(
                "Dalga kapısı: yalnız önceki dalga sağlık kapısını ve merkez onayını "
                "geçtiyse çalıştırın (docs/10)."
            )
        elif operation.scope == "release":
            argv += ["-e", f"release_wave={wave}"]
            if grants.get("wave_gate_confirmed") and playbook_declares_var(
                book, "wave_gate_confirmed"
            ):
                argv += ["-e", "wave_gate_confirmed=true"]
            if playbook_declares_var(book, "reboot_confirmed"):
                argv += ["-e", "reboot_confirmed=true"]
            if wave == PRODUCTION_WAVE:
                if grants.get("production_override") and playbook_declares_var(
                    book, "production_override"
                ):
                    argv += ["-e", "production_override=true"]
                if grants.get("allow_production_reboot") and playbook_declares_var(
                    book, "allow_production_reboot"
                ):
                    argv += ["-e", "allow_production_reboot=true"]
            notes.append(
                "Sürüm kapısı: dalga onayı ve sağlık kapısı olmadan çalıştırmayın (docs/10)."
            )
        if target.kind == "all" and operation.scope == "wave":
            notes.append(
                "Tüm filo: dalga kapılı playbook'lar dalga dalga ilerler; her dalgayı "
                "ayrı ayrı onaylayın."
            )

        argv += self._extra_vars(operation.id, opts)
        if check_mode:
            argv.append("--check")
            notes.append("--check: playbook hiçbir değişiklik uygulamaz (deneme koşusu).")
        return CommandPlan(
            commands=(tuple(argv),),
            destructive=operation.destructive,
            requires_root=operation.requires_root,
            operation_id=operation.id,
            target_label=target.label + (f" (dalga {wave})" if wave else ""),
            notes=tuple(notes),
            dry_run=self.ctx.dry_run,
            check_mode=check_mode,
        )

    def _extra_vars(self, operation_id: str, opts: Mapping[str, str]) -> list[str]:
        value = lambda name: (opts.get(name) or "").strip()  # noqa: E731
        extra: list[str] = []
        if operation_id == "disk" and value("disk_warn_pct"):
            extra += ["-e", f"disk_warn_pct={value('disk_warn_pct')}"]
        elif operation_id == "fieldos-version" and value("fieldos_expected_version"):
            extra += ["-e", f"fieldos_expected_version={value('fieldos_expected_version')}"]
        elif operation_id == "collect-logs" and value("log_lines"):
            extra += ["-e", f"log_lines={value('log_lines')}"]
        elif operation_id == "reboot" and value("reboot_grace_seconds"):
            extra += ["-e", f"reboot_grace_seconds={value('reboot_grace_seconds')}"]
        elif operation_id == "service-restart" and value("service_name"):
            extra += ["-e", f"service_name={value('service_name')}"]
        elif operation_id == "run-script" and value("script_path"):
            extra += ["-e", f"script_path={value('script_path')}"]
            if value("script_args"):
                extra += ["-e", f"script_args={value('script_args')}"]
        elif operation_id == "deploy-update" and value("update_packages"):
            pins = [
                f'"{pin.strip()}"'
                for pin in value("update_packages").split(",")
                if pin.strip()
            ]
            extra += ["-e", f"update_packages=[{','.join(pins)}]"]
        return extra

    def _installer_arg(self) -> str:
        installer = self.ctx.repo_root / INSTALLER_REL
        if not installer.is_file():
            raise CommandError(
                f"Kurulum betiği bulunamadı: {INSTALLER_REL}\n"
                "Depo kopyasını doğru verin (--repo PATH) veya checkout'u güncelleyin."
            )
        return str(installer)

    def _menu_arg(self) -> str:
        menu = self.ctx.repo_root / MENU_REL
        if not menu.is_file():
            raise CommandError(
                f"Konsol betiği bulunamadı: {MENU_REL}\n"
                "Depo kopyasını doğru verin (--repo PATH)."
            )
        return str(menu)

    def _tool_argv(self, tool: str, *args: str, optional: bool = False) -> tuple[str, ...] | None:
        path = resolve_tool(tool, self.ctx.repo_root)
        if path is None:
            if optional:
                return None
            raise CommandError(
                f"Araç bulunamadı: {tool}\n"
                "Bu araç depoda veya /usr/local/bin altında yok. Bağlamak için: "
                "sudo admin/bf-bootstrap.sh"
            )
        return (path, *args)

    def _build_local_plan(
        self,
        operation: Operation,
        target: Target | None,
        opts: Mapping[str, str],
        check_mode: bool = False,
    ) -> CommandPlan:
        dealer = ""
        if operation.needs_dealer:
            if target is None or target.kind != "dealer" or not target.value:
                raise CommandError(
                    f"'{operation.label}' için bayi numarası gerekir "
                    "(hedef alanına 8 haneli bayi no yazın)."
                )
            problem = dealer_error(target.value)
            if problem:
                raise CommandError(problem)
            dealer = target.value
        commands: list[tuple[str, ...]] = []
        notes: list[str] = []
        op_id = operation.id

        if op_id == "install-preflight":
            commands.append(
                ("bash", self._installer_arg(), "--dealer-id", dealer, "--check")
            )
            notes.append("Ön kontrol hiçbir şey yazmaz (log/state/dizin oluşturmaz).")
        elif op_id in ("install-local", "install-resume"):
            argv = ["bash", self._installer_arg(), "--dealer-id", dealer]
            if op_id == "install-resume" or opts.get("resume") == "1":
                argv.append("--resume")
            if opts.get("offline") == "1":
                argv.append("--offline")
            commands.append(tuple(argv))
            notes.append(f"Hedef cihaz kimliği: {dealer_to_device_id(dealer)} ({dealer_to_host(dealer)}).")
        elif op_id == "install-module":
            commands.append(
                (
                    "bash",
                    self._installer_arg(),
                    "--dealer-id",
                    dealer,
                    "--only",
                    (opts.get("only") or "").strip(),
                )
            )
        elif op_id == "install-state":
            commands.append(("cat", INSTALL_STATE_PATH))
        elif op_id == "install-log":
            commands.append(("tail", "-n", "40", INSTALL_LOG_PATH))
        elif op_id == "central-targets":
            commands.append(("bash", self._menu_arg(), "--list-targets"))
        elif op_id == "central-placeholders":
            commands.append(
                (
                    "grep",
                    "-n",
                    "PLACEHOLDER",
                    str(self.ctx.repo_root / "ansible" / "inventory" / "group_vars" / "all.yml"),
                )
            )
            notes.append("Eşleşme yoksa bu iyi haberdir (PLACEHOLDER kalmamış demektir).")
        elif op_id == "central-endpoints":
            commands.append(
                (
                    "grep",
                    "-nE",
                    r"^[[:space:]]*(wg_subnet|wg_interface|wg_hub_endpoint|monitoring_endpoint|"
                    r"monitoring_job|update_repo_url|meg_image_tag|support_bundle_dir)[[:space:]]*:",
                    str(self.ctx.repo_root / "ansible" / "inventory" / "group_vars" / "all.yml"),
                )
            )
            notes.append("Yalnız yapılandırma anahtarları okunur; secret hiçbir zaman gösterilmez.")
        elif op_id == "central-checklist":
            for line in CENTRAL_CHECKLIST:
                notes.append(line)
        elif op_id == "tools-catalogue":
            commands.append(("bash", self._menu_arg(), "--list"))
        elif op_id == "tools-git-pull":
            commands.append(("git", "-C", str(self.ctx.repo_root), "pull", "--ff-only"))
            notes.append("Çekme sonrası konsol değişmiş olabilir; arayüzü yeniden başlatın.")
        elif op_id == "tools-gate-local":
            commands.append(self._tool_argv("bf-check-local", "--check") or ())
        elif op_id == "tools-gate-enrollment":
            commands.append(self._tool_argv("bf-check-enrollment", "--check") or ())
        elif op_id == "tools-gate-ready":
            commands.append(self._tool_argv("bf-check-ready", "--check") or ())
        elif op_id == "tools-diagnostics":
            commands.append(self._tool_argv("bf-diagnostics") or ())
        elif op_id == "tools-release":
            commands.append(self._tool_argv("bf-release") or ())
        elif op_id == "tools-support-bundle":
            commands.append(
                self._tool_argv("bf-support-bundle", "--out-dir", "/var/tmp") or ()
            )
            notes.append("Destek paketi parola, private key veya token içermez.")
        elif op_id == "tools-console-log":
            commands.append(("tail", "-n", "40", self.ctx.console_log))
        elif op_id == "info-summary":
            commands.extend(self._status_summary_commands())
        elif op_id == "info-identity":
            commands.append(("hostname",))
            commands.append(
                (
                    "grep",
                    "-nE",
                    r"^[[:space:]]*\"(device_id|phase)\"",
                    STATE_JSON_PATH,
                )
            )
        elif op_id == "info-network":
            commands.append(("ip", "-brief", "address"))
            commands.append(("ip", "route", "show", "default"))
            commands.append(("sh", "-c", "awk '/^nameserver/{print}' /etc/resolv.conf"))
            commands.append(("wg", "show", "wg0", "latest-handshakes"))
            notes.append("WireGuard private/preshared anahtarları istenmez ve gösterilmez.")
        elif op_id == "info-resources":
            commands.append(("df", "-h"))
            commands.append(("free", "-h"))
            commands.append(("uptime",))
        elif op_id == "info-packages":
            commands.append(
                (
                    "dpkg-query",
                    "-W",
                    "-f=${Package} ${Version} ${Status}\n",
                    "docker-ce",
                    "wireguard",
                    "rustdesk",
                    "xrdp",
                    "openssh-server",
                )
            )
        elif op_id == "info-services":
            commands.append(
                (
                    "systemctl",
                    "is-active",
                    "ssh",
                    "sshd",
                    "xrdp",
                    "rustdesk",
                    "docker",
                    "wg-quick@wg0",
                    "cron",
                )
            )
        elif op_id == "info-journal":
            commands.append(("journalctl", "-p", "err", "-n", "20", "--no-pager"))
        elif op_id == "info-state":
            commands.append(
                (
                    "grep",
                    "-nE",
                    r"^[[:space:]]*\"(phase|enrollment_status|fleet_status|device_id|provisioning_id)\"",
                    STATE_JSON_PATH,
                )
            )
            notes.append(
                "Yalnız kimlik/durum alanları okunur; token ve anahtarlar gösterilmez."
            )
        else:
            raise CommandError(f"Bilinmeyen operasyon: {operation.id}")

        commands = [argv for argv in commands if argv]
        if not commands:
            raise CommandError(
                f"'{operation.label}' için çalıştırılabilir komut üretilemedi. "
                "Bu cihazda gerekli araç kurulu olmayabilir (sudo admin/bf-bootstrap.sh)."
            )
        # --check yalnizca destekleyen komutlara eklenir (kurulum betigi ve
        # bf-check-* kapilari); tail/cat/grep/dpkg gibi komutlara eklenmez.
        if check_mode and op_id in CHECK_CAPABLE_LOCAL_OPS:
            commands = [tuple(argv) + ("--check",) for argv in commands]
            notes.append("--check: yalnız denetim yapılır, değişiklik uygulanmaz.")
        label = target.label if target is not None and target.value else "bu cihaz (yerel)"
        return CommandPlan(
            commands=tuple(commands),
            destructive=operation.destructive,
            requires_root=operation.requires_root,
            operation_id=operation.id,
            target_label=label,
            notes=tuple(notes),
            dry_run=self.ctx.dry_run,
            check_mode=check_mode and op_id in CHECK_CAPABLE_LOCAL_OPS,
        )

    def _status_summary_commands(self) -> list[tuple[str, ...]]:
        """Durum ozeti: bakim sirasinda kaybolan cikti yerine guvenli, opsiyonel set."""
        commands: list[tuple[str, ...]] = []
        for tool, args in (("bf-status", ()), ("bf-enrollment-status", ("--check",))):
            argv = self._tool_argv(tool, *args, optional=True)
            if argv:
                commands.append(argv)
        commands.append(
            (
                "grep",
                "-nE",
                r"^[[:space:]]*\"(phase|enrollment_status|fleet_status|device_id|provisioning_id)\"",
                STATE_JSON_PATH,
            )
        )
        commands.append(("bash", self._menu_arg(), "--list-targets"))
        return commands

    # -- calistirma --------------------------------------------------------
    def run(
        self,
        plan: CommandPlan,
        on_line: Callable[[str], None] | None = None,
        cancel: threading.Event | None = None,
    ) -> RunResult:
        return run_plan(plan, on_line=on_line, cancel=cancel, cwd=str(self.ctx.repo_root))


CENTRAL_CHECKLIST: tuple[str, ...] = (
    "1. WireGuard hub: uç nokta, anahtarlar ve her bf-<bayi-no> için eş ataması (docs/08).",
    "2. Kayıt (enrollment) token servisi: tek kullanımlık, TTL sınırlı token (docs/29).",
    "3. İzleme: Prometheus/VictoriaMetrics + Grafana, device_id etiketi = BF-<no> (docs/14).",
    "4. Uzak erişim: RustDesk hbbs/hbbr veya MeshCentral, WireGuard üzerinden erişilebilir (docs/07).",
    "5. Paket aynası + saha kurulumları için çevrimdışı anlık görüntü (docs/10, docs/27).",
    "6. Gerçek ana makine adlarını içeren Ansible envanteri ve yönetici SSH anahtarı (docs/02, 06, 09).",
    "Bu arayüz 6'yı denetler; 1-5'i hazırlamaya yardımcı olur, merkez sunucusu KURMAZ.",
)


class ModuleBackend:
    """Gercek bfos.operations / bfos.runner modullerini kullanan backend.

    Paylasilan is mantigi TEK kaynaktan gelir (kopyalanmaz):
      * katalog       : bfos.operations (catalogue_rows / ALL_OPERATIONS)
      * envanter/hedef: Inventory.load_repository + resolve_target
      * komut uretimi : build_ansible_command / build_install_command /
                        build_tool_command / build_extra_vars
      * kapilar       : confirmation_plan + GatesGranted (dalga, production,
                        surum kapisi, yikici ikinci onay)
      * denetim kaydi : bfos.runner.AuditLog (varsa) -- TUI ile ayni kayit.

    Yerel (kurulum / arac / merkez / bilgi) islemler icin modulde karsiligi olan
    kurucular kullanilir; karsiligi olmayan salt-okunur ekran ve komutlar
    CatalogueBackend'e devredilir (bkz. _local).
    """

    name = "bfos.operations + bfos.runner (gerçek backend)"

    #: modulde komut kurucusu olan yerel arac islemleri: id -> (arac, sabit arg.)
    _TOOL_OPS: Mapping[str, tuple[str, tuple[str, ...]]] = {
        "tools-gate-local": ("bf-check-local", ()),
        "tools-gate-enrollment": ("bf-check-enrollment", ()),
        "tools-gate-ready": ("bf-check-ready", ()),
        "tools-diagnostics": ("bf-diagnostics", ()),
        "tools-release": ("bf-release", ()),
        "tools-support-bundle": ("bf-support-bundle", ("--out-dir", "/var/tmp")),
    }

    #: modulun salt-okunur rapor ureticileri: id -> fonksiyon adi
    _REPORT_OPS: Mapping[str, str] = {
        "central-targets": "targets_lines",
        "central-readiness": "central_readiness_lines",
        "central-endpoints": "central_endpoint_lines",
        "central-probe": "central_probe_lines",
        "central-wave-gates": "wave_gate_state_lines",
        "info-identity": "identity_lines",
        "info-state": "state_lines",
    }

    def __init__(self, ops_module, runner_module, ctx: GuiContext):
        self._ops = ops_module
        self._runner = runner_module
        self.ctx = ctx
        self._local = CatalogueBackend(ctx)
        self._repo = ops_module.Repository(str(ctx.repo_root))
        self._inventory = ops_module.Inventory.load_repository(
            self._repo, str(ctx.inventory) if ctx.inventory else ""
        )
        self._raw_ops: dict[str, Any] = {}
        self._catalogue = self._load_catalogue()
        self._by_id = {op.id: op for op in self._catalogue}
        self._fleet_ids = frozenset(op.id for op in self._catalogue if op.is_fleet)

    # -- katalog -----------------------------------------------------------
    def _load_catalogue(self) -> tuple[Operation, ...]:
        """Modulun kataloğu (filo işlemleri) + yerel işlemler (kurulum/araç/...)."""
        raw: Any = None
        for name in ("catalogue_rows", "list_operations", "operations",
                     "ALL_OPERATIONS", "OPERATIONS", "OPS", "get_operations"):
            candidate = getattr(self._ops, name, None)
            if candidate is None:
                continue
            try:
                value = candidate() if callable(candidate) else candidate
            except Exception:
                continue
            if value:
                raw = value
                break
        if not raw:
            raise BackendUnavailable(
                "bfos.operations içinde operasyon listesi bulunamadı.\n"
                "Beklenen: catalogue_rows() / ALL_OPERATIONS "
                "(bkz. bfos/ui_gui.py başlığındaki SÖZLEŞME)."
            )
        fleet: list[Operation] = []
        for item in raw:
            operation = self._normalize_operation(item)
            fleet.append(operation)
            self._raw_ops[operation.id] = item
        if not fleet:
            raise BackendUnavailable("bfos.operations boş bir operasyon listesi döndürdü.")
        local = tuple(op for op in OPERATIONS if not op.is_fleet)
        return tuple(fleet) + local

    @staticmethod
    def _normalize_operation(item) -> Operation:
        """Modul operasyonunu arayuzun Operation tipine cevirir (SÖZLEŞME)."""
        if isinstance(item, Operation):
            return item
        get = (lambda key, default=None: item.get(key, default)) if isinstance(item, dict) \
            else (lambda key, default=None: getattr(item, key, default))
        op_id = get("id") or get("ident") or get("name") or get("operation_id")
        if not op_id:
            raise BackendUnavailable("Bir operasyonun id alanı yok (SÖZLEŞME: id zorunlu).")
        label = get("label") or get("title") or get("description") or op_id
        category = get("category") or "Cihaz işlemleri"
        if category not in CATEGORIES:
            category = "Cihaz işlemleri"
        scope = get("scope") or get("declared_scope") or "simple"
        prompt = get("prompt") or "none"
        return Operation(
            id=str(op_id),
            label=str(label),
            category=str(category),
            destructive=bool(get("destructive") or get("is_destructive") or False),
            scope=str(scope),
            description=str(get("description") or ""),
            playbook=str(get("playbook") or ""),
            options=_prompt_options(str(prompt)),
            requires_root=bool(get("requires_root") or False),
            needs_dealer=bool(get("needs_dealer") or False),
        )

    # -- envanter ----------------------------------------------------------
    def list_operations(self) -> tuple[Operation, ...]:
        return self._catalogue

    def list_waves(self) -> tuple[str, ...]:
        try:
            present = self._inventory.waves_present()
        except Exception:
            present = ()
        return tuple(present) or WAVES

    def inventory_note(self) -> str:
        note = self._local.inventory_note()
        if self._inventory.path:
            note = f"Envanter: {self._inventory.path} ({self._inventory.count_all()} cihaz)"
        if not self._have_ansible():
            note += (
                "  |  UYARI: ansible-playbook bulunamadı; filo işlemleri çalışmaz "
                "(sudo apt install ansible)."
            )
        return note

    def _have_ansible(self) -> bool:
        checker = getattr(getattr(self._runner, "Runner", None), "have_ansible", None)
        try:
            if callable(checker):
                return bool(checker())
        except Exception:
            pass
        return shutil.which("ansible-playbook") is not None

    def target_wave(self, operation: Operation, target: Target | None) -> str | None:
        if target is None or not target.value:
            return None
        try:
            resolved = self._resolve_target(target, operation)
        except CommandError:
            return None
        return resolved.wave or None

    def validate_target(self, operation: Operation, target: Target) -> str | None:
        try:
            self._resolve_target(target, operation)
        except CommandError as exc:
            return str(exc)
        return None

    def _resolve_target(self, target: Target, operation: Operation):
        """Modulun resolve_target'i ile hedefi cozer (Refused -> CommandError)."""
        raw_op = self._raw_ops.get(operation.id)
        mode = "any"
        if raw_op is not None:
            mode = getattr(raw_op, "target_mode", "any")
        try:
            return self._ops.resolve_target(target.value, mode, self._inventory)
        except Exception as exc:
            raise self._refusal(exc) from exc

    @staticmethod
    def _refusal(exc: Exception) -> CommandError:
        """Modulun Refused hatasini (mesaj + ayrinti) Turkce CommandError'a cevirir."""
        message = getattr(exc, "message", None) or str(exc)
        detail = getattr(exc, "detail", "") or ""
        text = f"{message}\n{detail}".strip() if detail else str(message)
        if isinstance(exc, CommandError):
            return exc
        return CommandError(text)
    # -- kapilar -----------------------------------------------------------
    def gate_steps(
        self, operation: Operation, target: Target | None
    ) -> tuple[GateStepInfo, ...]:
        """Modulun confirmation_plan'i ile ayni kapi kurallari.

        confirmation_plan yoksa/çağrılamazsa yerel ayna (CatalogueBackend)
        kullanilir: kapi sormamak gibi sessiz bir davranis ASLA secilmez.
        """
        if operation.id not in self._fleet_ids or target is None or not target.value:
            return self._local.gate_steps(operation, target)
        planner = getattr(self._ops, "confirmation_plan", None)
        raw_op = self._raw_ops.get(operation.id)
        if not callable(planner) or raw_op is None:
            return self._local.gate_steps(operation, target)
        try:
            resolved = self._resolve_target(target, operation)
            gate_supported = False
            plays = getattr(self._repo, "playbook_uses", None)
            if callable(plays):
                gate_supported = bool(plays(raw_op.playbook, "wave_gate_confirmed"))
            steps = planner(
                raw_op, raw_op.declared_scope, resolved,
                wave_gate_supported=gate_supported,
            )
        except Exception:
            return self._local.gate_steps(operation, target)
        infos: list[GateStepInfo] = []
        for step in steps:
            infos.append(
                GateStepInfo(
                    kind=str(getattr(step, "kind", "approval")),
                    key=str(getattr(step, "key", "")),
                    prompt=str(getattr(step, "prompt", "")),
                    message=str(getattr(step, "message", "")),
                    token=str(getattr(step, "token", "")),
                    unlocks=tuple(getattr(step, "unlocks", ()) or ()),
                )
            )
        return tuple(infos)

    def _gates(self, grants: Mapping[str, bool]):
        """Onaylanan bayraklari modulun GatesGranted tipine cevirir."""
        gates_cls = getattr(self._ops, "GatesGranted", None)
        if gates_cls is None:
            return None
        fields = getattr(gates_cls, "__dataclass_fields__", {})
        kwargs = {name: bool(value) for name, value in grants.items() if name in fields}
        try:
            return gates_cls(**kwargs)
        except Exception:
            return None

    # -- komut uretimi -----------------------------------------------------
    def build_command(
        self,
        operation: Operation,
        target: Target | None = None,
        options: Mapping[str, str] | None = None,
        grants: Mapping[str, bool] | None = None,
        check_mode: bool = False,
    ) -> CommandPlan:
        opts = dict(options or {})
        granted = dict(grants or {})
        if operation.id in self._fleet_ids:
            return self._build_fleet_plan(operation, target, opts, granted, check_mode)
        for builder in (self._build_install_plan, self._build_tool_plan,
                        self._build_report_plan):
            plan = builder(operation, target, opts, check_mode)
            if plan is not None:
                return plan
        # Modulde karsiligi olmayan yerel komut/salt-okunur ekranlar.
        return self._local.build_command(operation, target, opts, granted, check_mode)

    def _build_fleet_plan(
        self,
        operation: Operation,
        target: Target | None,
        opts: Mapping[str, str],
        grants: Mapping[str, bool],
        check_mode: bool,
    ) -> CommandPlan:
        raw_op = self._raw_ops.get(operation.id)
        if raw_op is None:
            raise CommandError(
                f"'{operation.id}' operasyonunun tanımı backend'de bulunamadı."
            )
        if target is None or not target.value:
            raise CommandError(
                "Hedef seçilmedi; komut üretilmedi. Bayi numarası veya dalga grubu seçin."
            )
        if not self._inventory.path:
            raise CommandError(
                "Ansible envanteri bulunamadı; filo işlemleri komutu üretilemiyor. "
                "Beklenen yol: ansible/inventory/hosts.yml (veya --inventory PATH)."
            )
        verify = getattr(self._repo, "verify_scope", None)
        if callable(verify):
            # Playbook kendi kapisinin kaynagidir; tablo ile uyusmazsa REDDET.
            try:
                verify(raw_op)
            except Exception as exc:
                raise self._refusal(exc) from exc
        try:
            resolved = self._resolve_target(target, operation)
            extra = self._ops.build_extra_vars(raw_op.prompt, opts)
            argv = self._ops.build_ansible_command(
                self._repo, self._inventory.path, raw_op, raw_op.declared_scope,
                resolved, extra_vars=extra, gates=self._gates(grants),
                check_mode=check_mode,
            )
        except Exception as exc:
            raise self._refusal(exc) from exc

        notes: list[str] = []
        if raw_op.declared_scope in ("wave", "release"):
            notes.append(
                "Dalga/sürüm kapısı: yalnız önceki dalga sağlık kapısını ve merkez "
                "onayını geçtiyse çalıştırın (docs/10)."
            )
        if not grants.get("wave_gate_confirmed") and _declares(
            self._repo, raw_op.playbook, "wave_gate_confirmed"
        ):
            notes.append(
                "Not: wave_gate_confirmed bayrağı yalnız sürüm kapısı onayı verilirse "
                "komuta eklenir."
            )
        if check_mode:
            notes.append("--check: playbook hiçbir değişiklik uygulamaz (deneme koşusu).")
        return CommandPlan(
            commands=(tuple(argv),),
            destructive=bool(raw_op.destructive),
            requires_root=False,
            operation_id=operation.id,
            target_label=str(getattr(resolved, "label", target.label)),
            notes=tuple(notes),
            dry_run=self.ctx.dry_run,
            check_mode=check_mode,
        )

    def _build_install_plan(
        self, operation: Operation, target: Target | None,
        opts: Mapping[str, str], check_mode: bool,
    ) -> CommandPlan | None:
        if not operation.id.startswith("install-"):
            return None
        builder = getattr(self._ops, "build_install_command", None)
        if not callable(builder):
            return None
        if operation.id in ("install-state", "install-log"):
            return None
        dealer = ""
        if operation.needs_dealer:
            if target is None or target.kind != "dealer" or not target.value:
                raise CommandError(
                    f"'{operation.label}' için bayi numarası gerekir "
                    "(hedef alanına 8 haneli bayi no yazın)."
                )
            problem = dealer_error(target.value)
            if problem:
                raise CommandError(problem)
            dealer = target.value
        try:
            installer = self._repo.installer_path()
        except Exception as exc:
            raise self._refusal(exc) from exc
        check = operation.id == "install-preflight" or check_mode
        try:
            argv = builder(
                installer,
                dealer,
                offline=opts.get("offline") == "1",
                resume=operation.id == "install-resume" or opts.get("resume") == "1",
                only=(opts.get("only") or "").strip(),
                check_mode=check,
            )
        except Exception as exc:
            raise self._refusal(exc) from exc
        notes = [f"Hedef cihaz kimliği: {dealer_to_device_id(dealer)} ({dealer_to_host(dealer)})."]
        if operation.id == "install-preflight":
            notes.append("Ön kontrol hiçbir şey yazmaz (log/state/dizin oluşturmaz).")
        if check:
            notes.append("--check: hiçbir değişiklik uygulanmaz.")
        return CommandPlan(
            commands=(tuple(argv),),
            destructive=operation.destructive,
            requires_root=operation.requires_root,
            operation_id=operation.id,
            target_label=f"cihaz {dealer_to_device_id(dealer)} ({dealer_to_host(dealer)})",
            notes=tuple(notes),
            dry_run=self.ctx.dry_run,
            check_mode=check,
        )

    def _build_tool_plan(
        self, operation: Operation, target: Target | None,
        opts: Mapping[str, str], check_mode: bool,
    ) -> CommandPlan | None:
        entry = self._TOOL_OPS.get(operation.id)
        if entry is None:
            return None
        builder = getattr(self._ops, "build_tool_command", None)
        tool, args = entry
        try:
            path = self._repo.tool_path(tool)
        except Exception as exc:
            raise self._refusal(exc) from exc
        if not callable(builder):
            return None
        check = tool.startswith("bf-check-") or check_mode
        argv = builder(path, list(args), check_mode=check)
        notes: list[str] = []
        if operation.id == "tools-support-bundle":
            notes.append("Destek paketi parola, private key veya token içermez.")
        return CommandPlan(
            commands=(tuple(argv),),
            destructive=operation.destructive,
            requires_root=operation.requires_root,
            operation_id=operation.id,
            target_label="bu cihaz (yerel)",
            notes=tuple(notes),
            dry_run=self.ctx.dry_run,
            check_mode=check,
        )

    def _build_report_plan(
        self, operation: Operation, target: Target | None,
        opts: Mapping[str, str], check_mode: bool,
    ) -> CommandPlan | None:
        """Modulun salt-okunur ekran ureticileri (komut CALISTIRILMAZ)."""
        lines = self._module_report_lines(operation)
        if lines is None:
            return None
        return CommandPlan(
            report_lines=tuple(lines),
            destructive=False,
            operation_id=operation.id,
            target_label="bu cihaz (yerel)",
            notes=("Salt-okunur ekran: hiçbir komut çalıştırılmadı.",),
            dry_run=self.ctx.dry_run,
        )

    def _module_report_lines(self, operation: Operation) -> tuple[str, ...] | None:
        ops = self._ops
        try:
            if operation.id == "central-targets" and hasattr(ops, "targets_lines"):
                return tuple(ops.targets_lines(self._inventory))
            if operation.id == "central-placeholders" and hasattr(
                ops, "central_readiness_lines"
            ):
                return tuple(ops.central_readiness_lines(self._repo, self._inventory))
            if operation.id == "central-endpoints" and hasattr(ops, "central_endpoint_lines"):
                return tuple(ops.central_endpoint_lines(self._repo))
            if operation.id == "central-checklist" and hasattr(ops, "central_checklist_lines"):
                return tuple(ops.central_checklist_lines())
            if operation.id == "info-identity" and hasattr(ops, "identity_lines"):
                return tuple(ops.identity_lines())
            if operation.id == "info-state" and hasattr(ops, "state_lines"):
                return tuple(ops.state_lines())
            if operation.id == "info-summary" and hasattr(ops, "environment_lines"):
                lines = list(
                    ops.environment_lines(
                        self._repo, str(self.ctx.console_log), self._inventory,
                        self.ctx.dry_run, False,
                    )
                )
                if hasattr(ops, "state_lines"):
                    lines += [""]
                    lines += list(ops.state_lines())
                return tuple(lines)
        except Exception:
            # Rapor uretilemedi: yerel (katalog) yoluna dusulur, hata gizlenmez.
            return None
        return None
    # -- calistirma --------------------------------------------------------
    def run(
        self,
        plan: CommandPlan,
        on_line: Callable[[str], None] | None = None,
        cancel: threading.Event | None = None,
    ) -> RunResult:
        """Komutlari canli ciktiyla calistirir; denetim kaydi modul uzerinden.

        Not: bfos.runner.Runner komutu kendi stdio'suyla calistirir (TUI icin
        dogru olan davranis budur) ve ciktiyi dondurmez; GUI metin kutusuna
        satir satir akis icin buranin streaming calistiricisi kullanilir.
        Denetim kaydi, modulun AuditLog'u varsa onun uzerinden yazilir, boylece
        GUI ile TUI ayni bicimde kayit tutar.
        """
        audit = self._audit_log()
        redact = getattr(self._runner, "redact", None)
        command_text = " && ".join(shlex.join(argv) for argv in plan.commands)
        if callable(redact):
            try:
                command_text = str(redact(command_text))
            except Exception:
                pass
        if audit is not None:
            self._audit_write(audit, self._audit_level("AUDIT_RUN", "RUN"), command_text)
        result = run_plan(plan, on_line=on_line, cancel=cancel, cwd=str(self.ctx.repo_root))
        if audit is not None:
            level = self._audit_level("AUDIT_OK", "OK") if result.ok \
                else self._audit_level("AUDIT_FAIL", "FAIL")
            self._audit_write(audit, level, f"exit={result.exit_code} :: {command_text}")
        return result

    def _audit_log(self):
        """bfos.runner.AuditLog (varsa) -- kurulamazsa None (kayit sessizce atlanir)."""
        factory = getattr(self._runner, "AuditLog", None)
        if factory is None:
            return None
        try:
            return factory()
        except Exception:
            return None

    @staticmethod
    def _audit_write(audit, level: str, message: str) -> None:
        try:
            audit.write(level, message)
        except Exception:
            pass

    def _audit_level(self, name: str, fallback: str) -> str:
        config = getattr(self._ops, "config", None)
        return str(getattr(config, name, fallback) or fallback)


def _declares(repo, playbook: str, var: str) -> bool:
    """Playbook VAR'i kullaniyor mu? (modulun okuma yolu varsa onu kullanir.)"""
    checker = getattr(repo, "playbook_uses", None)
    if not callable(checker):
        return False
    try:
        return bool(checker(playbook, var))
    except Exception:
        return False


#: Modulun prompt turleri (bfos.operations PROMPT_*) icin arayuz secenekleri.
#: Anahtarlar modulun build_extra_vars() cevap anahtarlariyla AYNI olmalidir.
_PROMPT_OPTION_SPECS: Mapping[str, tuple[OptionSpec, ...]] = {
    "none": (),
    "packages": (
        OptionSpec(
            "packages",
            "Paket pinleri (paket=sürüm, virgülle)",
            required=True,
            hint="Yalnız tam pin; 'latest' ve aralık kabul edilmez",
            validator=validate_package_pins,
        ),
    ),
    "service": (
        OptionSpec(
            "service",
            "Servis adı",
            kind="choice",
            choices=SERVICE_ALLOWLIST,
            required=True,
            hint="Yalnız izinli servis adları",
            validator=validate_service_name,
        ),
    ),
    "script": (
        OptionSpec(
            "script",
            "Script yolu",
            required=True,
            hint=f"İzinli dizinler: {', '.join(SCRIPT_DIRS)}",
            validator=validate_script_path,
        ),
        OptionSpec("script_args", "Script argümanları", default="", hint="İsteğe bağlı"),
    ),
    "grace": (
        OptionSpec(
            "grace",
            "Yeniden başlatma bekleme süresi (saniye)",
            kind="int",
            default="300",
            validator=validate_grace,
        ),
    ),
    "disk_pct": (
        OptionSpec(
            "disk_pct",
            "Uyarı eşiği (%)",
            kind="int",
            default="",
            hint="Boş = playbook varsayılanı (80)",
            validator=validate_disk_pct,
        ),
    ),
    "log_lines": (
        OptionSpec(
            "log_lines",
            "Cihaz başına journal satırı",
            kind="int",
            default="500",
            validator=validate_log_lines,
        ),
    ),
    "expected_version": (
        OptionSpec(
            "expected_version",
            "Beklenen Field OS sürümü",
            default="",
            hint="Boş = sapma (drift) denetimi atlanır",
            validator=validate_expected_version,
        ),
    ),
}


def _prompt_options(prompt: str) -> tuple[OptionSpec, ...]:
    return _PROMPT_OPTION_SPECS.get(prompt, ())


def load_backend(ctx: GuiContext):
    """Gercek modulleri dener; yoksa yerlesik katalog'a duser.

    Donus: (backend, not) -- `not` Turkce bilgi satiridir (durum cubugunda
    gosterilir), hata DEGILDIR.
    """
    add_repo_to_path(ctx.repo_root)
    try:
        from bfos import operations as operations_module  # type: ignore
    except Exception as exc:  # ImportError ve beklenmeyen hatalar
        return (
            CatalogueBackend(ctx),
            f"bfos.operations bulunamadı ({type(exc).__name__}); yerleşik katalog "
            "kullanılıyor (admin/bf-menu kuralları).",
        )
    runner_module = None
    try:
        from bfos import runner as runner_module  # type: ignore  # noqa: F811
    except Exception:
        runner_module = None
    if runner_module is None:
        return (
            CatalogueBackend(ctx),
            "bfos.runner bulunamadı; komutlar yerleşik çalıştırıcıyla koşuluyor.",
        )
    try:
        backend = ModuleBackend(operations_module, runner_module, ctx)
    except BackendUnavailable as exc:
        return CatalogueBackend(ctx), f"UYARI: {exc}"
    except Exception as exc:  # beklenmeyen modul hatasi arayuzu kilitlemesin
        return (
            CatalogueBackend(ctx),
            f"UYARI: gerçek backend başlatılamadı ({type(exc).__name__}: {exc}); "
            "yerleşik katalog kullanılıyor.",
        )
    catalogue = len(backend.list_operations())
    fleet = len(backend._fleet_ids)  # noqa: SLF001 - bilgi amacli sayim
    return (
        backend,
        f"Gerçek backend: bfos.operations + bfos.runner "
        f"({fleet} filo işlemi, {catalogue - fleet} yerel işlem).",
    )


def add_repo_to_path(repo_root: Path) -> None:
    root = str(repo_root)
    if root not in sys.path:
        sys.path.insert(0, root)


# ---------------------------------------------------------------------------
# Cikti paneli + canli akis
# ---------------------------------------------------------------------------
class OutputPane:
    """Kaydirilabilir, canli guncellenen cikti alani (tkinter sarmalayicisi)."""

    def __init__(self, parent, height: int = 16):
        self.frame = ttk.LabelFrame(parent, text="Komut çıktısı")
        self.frame.pack(fill="both", expand=True, padx=8, pady=(4, 8))
        self.text = scrolledtext.ScrolledText(
            self.frame, height=height, wrap="word", font=("monospace", 10)
        )
        self.text.pack(fill="both", expand=True, padx=6, pady=6)
        self.text.configure(state="disabled")
        self._queue: "queue.Queue[str | None]" = queue.Queue()
        self._parent = parent

    def append(self, line: str) -> None:
        """Herhangi bir is parcacigindan guvenle cagrilabilir (kuyruga yazar)."""
        self._queue.put(line)

    def drain(self) -> None:
        """Ana is parcaciginda kuyrugu bosaltir (after ile periyodik cagrilir)."""
        wrote = False
        while True:
            try:
                line = self._queue.get_nowait()
            except queue.Empty:
                break
            self.text.configure(state="normal")
            self.text.insert("end", line + "\n")
            self.text.configure(state="disabled")
            wrote = True
        if wrote:
            self.text.see("end")
        self._parent.after(120, self.drain)

    def clear(self) -> None:
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.configure(state="disabled")

    def write_now(self, line: str) -> None:
        self.append(line)
        self.drain_once()

    def drain_once(self) -> None:
        while True:
            try:
                line = self._queue.get_nowait()
            except queue.Empty:
                break
            self.text.configure(state="normal")
            self.text.insert("end", line + "\n")
            self.text.configure(state="disabled")
        self.text.see("end")


# ---------------------------------------------------------------------------
# Arayuz
# ---------------------------------------------------------------------------
class BfGui:  # pragma: no cover - pencere gerektirir (statik testler dokunmaz)
    """Blueforce Field OS Turkce masaustu arayuzu."""

    def __init__(self, root, backend, ctx: GuiContext, *, full_mode: bool = False):
        self.root = root
        self.backend = backend
        self.ctx = ctx
        self.cancel_event = threading.Event()
        self.running = False
        self.option_widgets: dict[str, tuple[str, Any]] = {}
        self._panes: dict[str, tuple[Any, Any]] = {}
        # Islem tanimlari BACKEND'den gelir (yerlesik katalog ya da gercek
        # bfos.operations): secenek adlari backend ile ayni olmak zorundadir.
        self._ops_by_id: dict[str, Operation] = {
            op.id: op for op in backend.list_operations()
        }
        self._selected_operation: Operation | None = None
        self._current_plan: CommandPlan | None = None

        root.title(WINDOW_TITLE)
        root.minsize(980, 720)
        ttk.Style().configure(".", font=("Sans", 10))

        self._build_header()
        self._build_mode_bar()
        self.simple_frame = ttk.Frame(root)
        self.detail_frame = ttk.Frame(root)
        self._build_simple_mode(self.simple_frame)
        self._build_detail_mode(self.detail_frame)
        self.output = OutputPane(root, height=18)
        self.output.drain()
        self._build_footer()

        self.show_mode(full=full_mode)
        self._load_inventory()

    # -- ust bilgi ---------------------------------------------------------
    def _build_header(self) -> None:
        header = ttk.Frame(self.root)
        header.pack(fill="x", padx=8, pady=(8, 2))
        ttk.Label(header, text=WINDOW_TITLE, font=("Sans", 15, "bold")).pack(anchor="w")
        ttk.Label(header, text=APP_SUBTITLE, foreground="#444").pack(anchor="w")
        ttk.Label(
            header,
            text=f"Depo: {self.ctx.repo_root}",
            foreground="#666",
        ).pack(anchor="w")
        self.backend_note = ttk.Label(header, text=self.backend.name, foreground="#666")
        self.backend_note.pack(anchor="w")
        if self.ctx.dry_run:
            ttk.Label(
                header,
                text="DENEME KİPİ (--dry-run): komutlar gösterilir, çalıştırılmaz.",
                foreground="#a05000",
            ).pack(anchor="w")

    def _build_mode_bar(self) -> None:
        bar = ttk.Frame(self.root)
        bar.pack(fill="x", padx=8, pady=(6, 0))
        self.mode_button = ttk.Button(bar, text=SIMPLE_MODE_LABEL, command=self.toggle_mode)
        self.mode_button.pack(side="left")
        ttk.Label(bar, text="Hedef:").pack(side="left", padx=(16, 4))
        self.dealer_var = tk.StringVar()
        self.dealer_entry = ttk.Entry(bar, textvariable=self.dealer_var, width=12)
        self.dealer_entry.pack(side="left")
        self.dealer_entry.bind("<KeyRelease>", lambda _e: self._on_dealer_change())
        ttk.Label(bar, text="Bayi no (8 hane)").pack(side="left", padx=(4, 12))
        self.wave_var = tk.StringVar()
        self.wave_combo = ttk.Combobox(
            bar, textvariable=self.wave_var, values=list(WAVES), width=14, state="readonly"
        )
        self.wave_combo.pack(side="left")
        ttk.Label(bar, text="Dalga").pack(side="left", padx=(4, 12))
        self.all_var = tk.IntVar(value=0)
        ttk.Checkbutton(
            bar, text="Tüm filo (dikkat)", variable=self.all_var,
            command=self._on_target_change,
        ).pack(side="left")
        self.target_status = ttk.Label(bar, text="", foreground="#a00000")
        self.target_status.pack(side="left", padx=10)

    def _build_footer(self) -> None:
        footer = ttk.Frame(self.root)
        footer.pack(fill="x", padx=8, pady=(0, 8))
        self.run_button = ttk.Button(
            footer, text="Komutu göster ve çalıştır", command=self._on_run_clicked
        )
        self.run_button.pack(side="left")
        ttk.Button(footer, text="Çıktıyı temizle", command=self._clear_output).pack(
            side="left", padx=6
        )
        self.cancel_button = ttk.Button(
            footer, text="Çalışanı iptal et", command=self._cancel, state="disabled"
        )
        self.cancel_button.pack(side="left", padx=6)
        self.check_var = tk.IntVar(value=0)
        ttk.Checkbutton(
            footer, text="Yalnız denetim (--check)", variable=self.check_var
        ).pack(side="left", padx=6)
        ttk.Button(footer, text="Çıkış", command=self.root.destroy).pack(side="right")
        self.status = ttk.Label(footer, text="Hazır.")
        self.status.pack(side="right", padx=12)

    # -- basit mod ---------------------------------------------------------
    def _build_simple_mode(self, parent) -> None:
        box = ttk.Frame(parent)
        box.pack(expand=True, fill="both", padx=24, pady=24)
        ttk.Label(
            box,
            text="Ne yapmak istiyorsunuz?",
            font=("Sans", 13, "bold"),
        ).pack(anchor="w", pady=(0, 12))
        for label in SIMPLE_MODE_BUTTONS:
            command = {
                "Kur": self._simple_install,
                "Durum": self._simple_status,
                "Çıkış": self.root.destroy,
            }[label]
            button = ttk.Button(box, text=label, command=command)
            button.configure(width=18)
            button.pack(fill="x", pady=8, ipady=10)
        ttk.Label(
            box,
            text=(
                "Kur: bu cihazı kurar (bayi no gerekir).  Durum: salt-okunur özet.\n"
                "Daha fazlası için üstteki '" + SIMPLE_MODE_LABEL + "' düğmesini kullanın."
            ),
            foreground="#555",
            justify="left",
        ).pack(anchor="w", pady=(12, 0))

    def _simple_install(self) -> None:
        choice = self._choice_dialog(
            "Kurulum",
            "Bu cihazda ne yapılacak?\n\n"
            "Ön kontrol (--check) hiçbir şey yazmaz; kurulum cihazı değiştirir.",
            (("Ön kontrol (--check)", "install-preflight"),
             ("Kurulumu başlat", "install-local"),
             ("Vazgeç", None)),
        )
        if not choice:
            return
        operation = self._ops_by_id.get(choice)
        if operation is not None:
            self._execute(operation)

    def _simple_status(self) -> None:
        operation = self._ops_by_id.get("info-summary")
        if operation is None:
            return
        self._execute(operation)

    # -- detayli mod -------------------------------------------------------
    def _build_detail_mode(self, parent) -> None:
        self.notebook = ttk.Notebook(parent)
        self.notebook.pack(fill="both", expand=True, padx=8, pady=8)
        for category in CATEGORIES:
            frame = ttk.Frame(self.notebook)
            self.notebook.add(frame, text=category)
            self._build_category_tab(frame, category)

    def _build_category_tab(self, frame, category: str) -> None:
        left = ttk.Frame(frame)
        left.pack(side="left", fill="both", expand=True, padx=6, pady=6)
        columns = ("islem", "kapsam", "tur")
        tree = ttk.Treeview(left, columns=columns, show="headings", height=14)
        tree.heading("islem", text="İşlem")
        tree.heading("kapsam", text="Kapsam")
        tree.heading("tur", text="Tür")
        tree.column("islem", width=360)
        tree.column("kapsam", width=200)
        tree.column("tur", width=110, anchor="center")
        scroll = ttk.Scrollbar(left, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=scroll.set)
        tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="left", fill="y")
        tree.bind(
            "<<TreeviewSelect>>",
            lambda _e, t=tree, c=category: self._on_operation_selected(t, c),
        )
        setattr(self, f"_tree_{category}", tree)
        for op in operations_by_category(category):
            tree.insert(
                "",
                "end",
                iid=op.id,
                values=(
                    op.label,
                    SCOPE_LABELS.get(op.scope, op.scope),
                    "YIKICI" if op.destructive else "salt-okunur",
                ),
                tags=("destructive",) if op.destructive else (),
            )
        tree.tag_configure("destructive", foreground="#a00000")

        right = ttk.LabelFrame(frame, text="Seçenekler ve açıklama")
        right.pack(side="left", fill="both", expand=True, padx=6, pady=6)
        detail_label = ttk.Label(right, text="Bir işlem seçin.", wraplength=380,
                                 justify="left")
        detail_label.pack(anchor="w", padx=8, pady=8)
        options_frame = ttk.Frame(right)
        options_frame.pack(fill="x", padx=8, pady=4)
        # Sekme basina ayri secenek alani: her sekme kendi islemini gosterir.
        self._panes = getattr(self, "_panes", {})
        self._panes[category] = (detail_label, options_frame)
        ttk.Label(
            right,
            text="Komut her zaman önce gösterilir ve onaysız çalıştırılmaz.",
            foreground="#555",
            wraplength=380,
            justify="left",
        ).pack(anchor="w", padx=8, pady=(8, 4))

    def _on_operation_selected(self, tree, category: str) -> None:
        selection = tree.selection()
        if not selection:
            return
        operation = self._ops_by_id.get(selection[0])
        if operation is None:
            return
        self._selected_operation = operation
        self._render_options(operation, category)

    def _render_options(self, operation: Operation, category: str) -> None:
        detail_label, options_frame = self._panes[category]
        for child in options_frame.winfo_children():
            child.destroy()
        self.option_widgets = {}
        text = operation.label + "\n\n" + (operation.description or "Açıklama yok.")
        if operation.playbook:
            text += f"\n\nAnsible playbook: {PLAYBOOK_DIR_REL}/{operation.playbook}"
        text += f"\nKapsam: {SCOPE_LABELS.get(operation.scope, operation.scope)}"
        if operation.destructive:
            text += "\n\nBU İŞLEM YIKICIDIR: iki kez onay istenir."
        detail_label.configure(text=text)
        for spec in operation.options:
            row = ttk.Frame(options_frame)
            row.pack(fill="x", pady=3)
            ttk.Label(row, text=spec.label + ":", width=32, anchor="w").pack(side="left")
            if spec.kind == "bool":
                var = tk.BooleanVar(value=spec.default == "1")
                ttk.Checkbutton(row, variable=var).pack(side="left")
                self.option_widgets[spec.name] = ("bool", var)
                widget = None
            elif spec.kind == "choice":
                var = tk.StringVar(value=spec.default or (spec.choices[0] if spec.choices else ""))
                widget = ttk.Combobox(row, textvariable=var, values=list(spec.choices),
                                      width=24, state="readonly")
                self.option_widgets[spec.name] = ("str", var)
            else:
                var = tk.StringVar(value=spec.default)
                widget = ttk.Entry(row, textvariable=var, width=26)
                self.option_widgets[spec.name] = ("str", var)
            if widget is not None:
                widget.pack(side="left")
            if spec.hint:
                ttk.Label(row, text=f"  {spec.hint}", foreground="#666").pack(side="left")

    # -- hedef -------------------------------------------------------------
    def _load_inventory(self) -> None:
        waves = self.backend.list_waves()
        self.wave_combo.configure(values=list(waves))
        if waves:
            self.wave_var.set(waves[0])
        note = self.backend.inventory_note()
        self.output.write_now(f"[i] {note}")
        self.status.configure(text="Hazır.")

    def _on_dealer_change(self) -> None:
        value = self.dealer_var.get().strip()
        problem = dealer_error(value) if value else None
        self.target_status.configure(text=problem or "")
        if not problem:
            self.status.configure(text=f"Bayi no geçerli: {dealer_to_device_id(value)}")

    def _on_target_change(self) -> None:
        if self.all_var.get():
            self.target_status.configure(
                text="Tüm filo seçildi: dalga kapılı işlemler dalga dalga ilerler."
            )
        else:
            self._on_dealer_change()

    def current_target(self) -> Target | None:
        if self.all_var.get():
            return Target("all", "all")
        dealer = self.dealer_var.get().strip()
        if dealer:
            return Target("dealer", dealer)
        wave = self.wave_var.get().strip()
        if wave:
            return Target("group", wave)
        return None

    # -- mod degistirme ----------------------------------------------------
    def show_mode(self, *, full: bool) -> None:
        self.simple_frame.pack_forget()
        self.detail_frame.pack_forget()
        if full:
            self.detail_frame.pack(fill="both", expand=True)
            self.mode_button.configure(text=SIMPLE_MODE_BACK_LABEL)
        else:
            self.simple_frame.pack(fill="both", expand=True)
            self.mode_button.configure(text=SIMPLE_MODE_LABEL)
        self.full_mode = full

    def toggle_mode(self) -> None:
        self.show_mode(full=not self.full_mode)

    # -- calistirma akisi --------------------------------------------------
    def _on_run_clicked(self) -> None:
        if self._selected_operation is None:
            messagebox.showinfo(
                "Seçim gerekli",
                "Önce listeden bir işlem seçin, sonra 'Komutu göster ve çalıştır' düğmesine basın.",
            )
            return
        self._execute(self._selected_operation)

    def _collect_options(self, operation: Operation) -> dict[str, str]:
        options: dict[str, str] = {}
        for spec in operation.options:
            entry = self.option_widgets.get(spec.name)
            if not entry:
                continue
            kind, variable = entry
            if kind == "bool":
                options[spec.name] = "1" if variable.get() else "0"
            else:
                options[spec.name] = str(variable.get()).strip()
        return options

    def _execute(self, operation: Operation) -> None:
        if self.running:
            messagebox.showinfo("Bekleyin", "Zaten çalışan bir işlem var.")
            return
        target = self.current_target() if operation.is_fleet or operation.needs_dealer else None
        if operation.needs_dealer and (target is None or target.kind != "dealer"):
            messagebox.showerror(
                "Bayi numarası gerekli",
                "Bu işlem için bayi numarası girin (8 hane, örn. 12010193).",
            )
            return
        if target is not None and target.kind == "dealer":
            problem = dealer_error(target.value)
            if problem:
                messagebox.showerror("Geçersiz bayi numarası", problem)
                return
        options = self._collect_options(operation)
        check_mode = bool(self.check_var.get())
        try:
            draft = self.backend.build_command(
                operation, target, options, check_mode=check_mode
            )
        except CommandError as exc:
            messagebox.showerror("Komut üretilemedi", str(exc))
            return
        except BackendUnavailable as exc:
            messagebox.showerror("Backend hatası", str(exc))
            return

        # Salt-okunur rapor (komut yok): dogrudan cikti alanina yazilir.
        if draft.is_report_only:
            self._current_plan = draft
            self._show_plan(draft, title=f"Salt-okunur ekran: {operation.label}")
            self._start_run(draft)
            return

        # 1) Taslak komut GORSTERILIR ve onaylanir: onaysiz hicbir sey calismaz.
        if not self._confirm_plan(draft, operation, target, title="Komutu onaylayın"):
            self.output.write_now("[i] Kullanıcı vazgeçti; komut çalıştırılmadı.")
            return

        # 2) Acik kapilar: dalga adi, production, filo geneli, yikici ikinci onay.
        grants = self._collect_grants(operation, target)
        if grants is None:
            self.output.write_now("[i] Kapı onayı verilmedi; işlem iptal edildi.")
            return

        # 3) Kapilar eklendikten sonraki KESIN komut yeniden gosterilir.
        try:
            plan = self.backend.build_command(
                operation, target, options, grants=grants, check_mode=check_mode
            )
        except CommandError as exc:
            messagebox.showerror("Komut üretilemedi", str(exc))
            return
        if plan.lines != draft.lines:
            if not self._confirm_plan(
                plan, operation, target,
                title="KESİN KOMUT (onayların eklendiği son hâl)",
            ):
                self.output.write_now("[i] Kesin komut onaylanmadı; işlem iptal edildi.")
                return

        self._current_plan = plan
        self._show_plan(plan, title=f"Çalıştırılıyor: {operation.label}")
        self._start_run(plan)

    def _confirm_plan(
        self, plan: CommandPlan, operation: Operation,
        target: Target | None, title: str,
    ) -> bool:
        """Komutu gosteren onay penceresi (yikici islemde uyari vurgusu)."""
        preview = preview_text(plan, operation=operation, target=target)
        return bool(
            messagebox.askyesno(
                title,
                preview + "\n\nBu komut çalıştırılsın mı?",
                icon="warning" if plan.destructive else "question",
                default="no" if plan.destructive else "yes",
            )
        )

    def _collect_grants(
        self, operation: Operation, target: Target | None
    ) -> dict[str, bool] | None:
        """Backend'in istedigi acik onaylari sorar; iptalde None doner."""
        try:
            steps = self.backend.gate_steps(operation, target)
        except CommandError as exc:
            messagebox.showerror("Kapı onayları alınamadı", str(exc))
            return None
        grants: dict[str, bool] = {}
        for step in steps:
            if step.kind == "token":
                answer = self._token_dialog(step.prompt or "Onay", step.message, step.token)
                if answer is None or answer.strip() != step.token:
                    return None
            else:
                if not messagebox.askyesno(
                    step.prompt or "Onay",
                    step.message or "Devam edilsin mi?",
                    icon="warning",
                    default="no",
                ):
                    return None
            for name in step.unlocks:
                grants[name] = True
        return grants

    def _show_plan(self, plan: CommandPlan, title: str) -> None:
        """Komutu/raporu cikti alanina yazar (kayit ve gozden gecirme icin)."""
        self.output.write_now("")
        self.output.write_now("=" * 72)
        self.output.write_now(f"   {title}")
        if plan.report_lines and not plan.lines:
            for line in plan.report_lines:
                self.output.write_now("   " + line)
        else:
            for line in plan.lines:
                self.output.write_now("   " + line)
        self.output.write_now("=" * 72)

    def _start_run(self, plan: CommandPlan) -> None:
        self.running = True
        self.cancel_event.clear()
        self.run_button.configure(state="disabled")
        self.cancel_button.configure(state="normal")
        self.status.configure(text="Çalışıyor… (iptal için 'Çalışanı iptal et')")

        def worker() -> None:
            try:
                result = self.backend.run(
                    plan, on_line=self.output.append, cancel=self.cancel_event
                )
            except Exception as exc:  # backend hatasi arayuzu kilitlemesin
                self.output.append(f"[HATA] Çalıştırma başarısız: {exc}")
                result = RunResult(1, False, "")
            self.root.after(0, lambda: self._finish_run(result))

        threading.Thread(target=worker, daemon=True).start()

    def _finish_run(self, result: RunResult) -> None:
        self.running = False
        self.run_button.configure(state="normal")
        self.cancel_button.configure(state="disabled")
        if result.ok:
            self.output.append("[OK] Komut başarıyla tamamlandı (çıkış kodu 0).")
            self.status.configure(text="Tamamlandı (çıkış kodu 0).")
        else:
            self.output.append(f"[HATA] Komut {result.exit_code} koduyla bitti.")
            self.status.configure(text=f"Hata: çıkış kodu {result.exit_code}")

    def _cancel(self) -> None:
        self.cancel_event.set()
        self.status.configure(text="İptal istendi…")

    def _clear_output(self) -> None:
        self.output.clear()

    # -- kucuk diyaloglar --------------------------------------------------
    def _choice_dialog(self, title: str, message: str,
                       choices: Sequence[tuple[str, str | None]]) -> str | None:
        dialog = tk.Toplevel(self.root)
        dialog.title(title)
        dialog.transient(self.root)
        dialog.grab_set()
        result: dict[str, str | None] = {"value": None}

        ttk.Label(dialog, text=message, wraplength=460, justify="left").pack(
            padx=16, pady=16, anchor="w"
        )

        def choose(value: str | None) -> None:
            result["value"] = value
            dialog.destroy()

        row = ttk.Frame(dialog)
        row.pack(fill="x", padx=16, pady=(0, 16))
        for label, value in choices:
            ttk.Button(row, text=label, command=lambda v=value: choose(v)).pack(
                side="left", padx=4
            )
        dialog.wait_window()
        return result["value"]

    def _token_dialog(self, title: str, message: str, token: str) -> str | None:
        dialog = tk.Toplevel(self.root)
        dialog.title(title)
        dialog.transient(self.root)
        dialog.grab_set()
        result: dict[str, str | None] = {"value": None}
        ttk.Label(dialog, text=message, wraplength=460, justify="left").pack(
            padx=16, pady=16, anchor="w"
        )
        var = tk.StringVar()
        entry = ttk.Entry(dialog, textvariable=var, width=32)
        entry.pack(padx=16, anchor="w")
        entry.focus_set()

        def confirm() -> None:
            result["value"] = var.get().strip()
            dialog.destroy()

        def cancel() -> None:
            result["value"] = None
            dialog.destroy()

        row = ttk.Frame(dialog)
        row.pack(fill="x", padx=16, pady=16)
        ttk.Button(row, text="Onayla", command=confirm).pack(side="left", padx=4)
        ttk.Button(row, text="Vazgeç", command=cancel).pack(side="left", padx=4)
        dialog.bind("<Return>", lambda _e: confirm())
        dialog.wait_window()
        return result["value"]


# ---------------------------------------------------------------------------
# Katalog yazdirma (pencere ACMADAN dogrulama icin)
# ---------------------------------------------------------------------------
def print_catalogue(backend, stream=None) -> None:
    out = stream or sys.stdout
    operations = backend.list_operations()
    print(f"Blueforce Field OS — işlem kataloğu ({len(operations)} işlem)", file=out)
    for category in CATEGORIES:
        items = [op for op in operations if op.category == category]
        print(f"\n== {category} ({len(items)} işlem) ==", file=out)
        for op in items:
            kind = "YIKICI" if op.destructive else "salt-okunur"
            playbook = op.playbook or "-"
            print(
                f"  {op.id:<24} {op.label:<46} kapsam={op.scope:<8} {kind:<11} playbook={playbook}",
                file=out,
            )


# ---------------------------------------------------------------------------
# Baslatma
# ---------------------------------------------------------------------------
def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python3 -m bfos.ui_gui",
        description="Blueforce Field OS masaüstü arayüzü (Türkçe, tkinter).",
    )
    parser.add_argument("--full", action="store_true",
                        help="Doğrudan detaylı modda başlat (kategori sekmeleri).")
    parser.add_argument("--repo", default=None, help="Depo kökü (varsayılan: bfos'un üst dizini).")
    parser.add_argument("--inventory", default=None, help="Ansible envanteri (varsayılan: otomatik).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Komutları göster, hiçbir şey çalıştırma.")
    parser.add_argument("--list", action="store_true",
                        help="Pencere açmadan işlem kataloğunu yazdır ve çık.")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    ctx = GuiContext.detect(repo=args.repo, inventory=args.inventory, dry_run=args.dry_run)
    backend, note = load_backend(ctx)

    if args.list:
        print_catalogue(backend)
        print(f"\n[i] {note}")
        return 0

    if not HAVE_TKINTER:
        print(tkinter_missing_message(TK_IMPORT_ERROR), file=sys.stderr)
        return 3
    problem = headless_error()
    if problem:
        print(problem, file=sys.stderr)
        return 3

    root = tk.Tk()
    try:
        BfGui(root, backend, ctx, full_mode=args.full)
    except tk.TclError as exc:  # DISPLAY var ama erisilemiyor
        print(window_start_error(exc), file=sys.stderr)
        return 3
    root.mainloop()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
