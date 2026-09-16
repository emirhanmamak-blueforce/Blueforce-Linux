"""Static configuration for the bfos operator console.

Everything an operator can read lives here, in Turkish, so the wording can be
reviewed and changed in one place. Identifiers and comments stay English.

Rules kept in this module:
  * standard library only (Python 3.8+), no third-party import,
  * no side effect at import time (no directory is created, nothing is read),
  * thresholds and allowlists are shared with the Ansible playbooks/docs: the
    canonical wave order and the dealer-number pattern come from docs/02 and
    docs/10 exactly as admin/lib/targets.sh defines them.
"""

# ---------------------------------------------------------------------------
# Identity and version
# ---------------------------------------------------------------------------
PROGRAM_NAME = "bfos"
VERSION = "1.0.0"
SCREEN_TITLE = "BLUEFORCE FIELD OS"
SCREEN_SUBTITLE = "Saha cihazı operatör konsolu"
PROGRAM_DESCRIPTION = "Blueforce saha cihazı operatör konsolu (Türkçe)"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
DEFAULT_LOG_FILE = "/var/log/blueforce-console.log"
LOG_FALLBACK_SUBDIR = ("blueforce", "blueforce-console.log")
LOG_FILE_MODE = 0o600
LOG_DIR_MODE = 0o700

INSTALLER_REL = "scripts/install/blueforce-install.sh"
PLAYBOOK_DIR_REL = "ansible/playbooks"
DIAGNOSTICS_DIR_REL = "scripts/diagnostics"
GROUP_VARS_REL = "ansible/inventory/group_vars/all.yml"
INVENTORY_DIR_REL = "ansible/inventory"
INVENTORY_EXAMPLE_REL = "ansible/inventory/hosts.example.yml"
INVENTORY_CANDIDATES = ("hosts.yml", "hosts.yaml", "hosts", "hosts.ini")

STATE_FILE = "/var/lib/blueforce/state.json"  # nosec - read-only whitelist
INSTALL_STATE_FILE = "/var/lib/blueforce/install-state"
INSTALL_LOG_FILE = "/var/log/blueforce-install.log"
TOOL_BIN_DIR = "/usr/local/bin"
ADMIN_KEY_FILE = "~/.ssh/blueforce_id_ed25519"
SUPPORT_BUNDLE_OUT_DIR = "/var/tmp"

# ---------------------------------------------------------------------------
# Rules, allowlists and thresholds (mirrors admin/lib/targets.sh + docs/10)
# ---------------------------------------------------------------------------
DEALER_PATTERN = r"^[0-9]{8}$"
HOST_PATTERN = r"^bf-[0-9]{8}$"

# Canonical rollout order. One place, so the menu, the gate checks and the
# fleet-wide loop can never disagree.
WAVES = ("lab", "pilot_1", "pilot_2", "wave_1", "wave_2", "production")
PRODUCTION_WAVE = "production"

# Target selection modes.
MODE_ANY = "any"
MODE_WAVE = "wave"
MODE_RELEASE = "release"

# Scope names derived from the playbook file itself.
SCOPE_SIMPLE = "simple"
SCOPE_WAVE = "wave"
SCOPE_RELEASE = "release"

SERVICE_ALLOWLIST = ("blueforce-agent", "docker", "ssh", "sshd", "systemd-journald", "cron")
SCRIPT_DIRS = ("/opt/blueforce/bin", "/usr/local/sbin")

DISK_WARN_MIN = 1
DISK_WARN_MAX = 100
DEFAULT_REBOOT_GRACE = 300
DEFAULT_LOG_LINES = 500

# Non-secret identity/lifecycle keys of state.json (whitelist, mirrors bf-menu).
STATE_ALLOWED_KEYS = ("phase", "enrollment_status", "fleet_status", "device_id", "provisioning_id")

# Central endpoint keys read from group_vars/all.yml for the preparation screens.
CENTRAL_ENDPOINT_KEYS = (
    "wg_subnet",
    "wg_interface",
    "wg_hub_endpoint",
    "monitoring_endpoint",
    "monitoring_job",
    "update_repo_url",
    "update_repo_suite",
    "meg_image_tag",
    "support_bundle_dir",
)

# Local diagnostics tools the console can drive (resolved in /usr/local/bin
# first, then in the checkout under scripts/diagnostics/).
DIAGNOSTIC_TOOLS = (
    "bf-status",
    "bf-diagnostics",
    "bf-check-local",
    "bf-check-enrollment",
    "bf-check-ready",
    "bf-release",
    "bf-remote-status",
    "bf-support-bundle",
    "bf-hardware-inventory.sh",
)

TOOL_ENROLL_STATUS = "bf-enrollment-status"
TOOL_LIVE_HW_CHECK = "bf-live-hw-check"

# Language: this console is Turkish-only on purpose (user decision). The option
# exists so a future translation has a single switch to grow into.
SUPPORTED_LANGS = ("tr",)
DEFAULT_LANG = "tr"

# Layout and exit codes (the bash console uses the same contract).
CONSOLE_WIDTH = 78
EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2

# Minimal Python version this console supports.
MIN_PYTHON = (3, 8)

# ---------------------------------------------------------------------------
# ANSI palette
# ---------------------------------------------------------------------------
ANSI = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "magenta": "\033[35m",
    "cyan": "\033[36m",
}


class Palette:
    """ANSI codes, or empty strings when colour is switched off."""

    __slots__ = (
        "enabled",
        "reset",
        "bold",
        "dim",
        "red",
        "green",
        "yellow",
        "blue",
        "magenta",
        "cyan",
    )

    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled
        for name, code in ANSI.items():
            setattr(self, name, code if enabled else "")

    def paint(self, text: str, *names: str) -> str:
        """Wrap TEXT in the given colour names (ignored when disabled)."""
        if not self.enabled or not names:
            return text
        prefix = "".join(getattr(self, name) for name in names)
        return "{0}{1}{2}".format(prefix, text, self.reset)


# ---------------------------------------------------------------------------
# Turkish messages
# ---------------------------------------------------------------------------
# Generic messages
MSG_QUIT = "Konsoldan çıkılıyor."
MSG_BACK = "Geri"
MSG_QUIT_ITEM = "Çıkış"
MSG_AT_TOP = "Zaten ana menüdesiniz."
MSG_UNKNOWN_CHOICE = "Geçersiz seçim: '{choice}'. Lütfen menüdeki numaralardan birini yazın."
MSG_MENU_RANGE = "Lütfen 1 ile {max} arasında bir numara yazın."
MSG_PRESS_ENTER = "Devam etmek için Enter'a basın"
MSG_CANCELLED = "İptal edildi; hiçbir şey çalıştırılmadı."
MSG_CANCELLED_RUN = "İşlem iptal edildi, komut çalıştırılmadı."
MSG_INVALID_INPUT = "Girdi anlaşılamadı: {value}"
MSG_REQUIRED = "Bu alan boş bırakılamaz."
MSG_NOT_A_TTY = "Bu ekran etkileşimli bir uçbirim gerektiriyor; çıkılıyor."

# Interpreter / environment
MSG_PYTHON_MISSING = (
    "HATA: python3 bulunamadı. bfos operatör konsolu için Python 3.8 veya üzeri gerekir.\n"
    "Yedek yol (bash): sudo admin/bf-menu   ya da kuruluysa: sudo bf-menu"
)
MSG_PYTHON_OLD = (
    "HATA: Python sürümü çok eski: {version}. bfos için Python 3.8+ gerekir.\n"
    "Yedek yol (bash): sudo admin/bf-menu"
)
MSG_LANG_UNSUPPORTED = "Bu konsol yalnızca Türkçe çalışır; '{value}' desteklenmiyor. Kullanılabilir: {supported}."
MSG_REPO_INVALID = (
    "HATA: {path} bir Blueforce deposu gibi görünmüyor (ansible/ ve scripts/ bulunamadı).\n"
    "Depoyu klonlayıp konsolu oradan çalıştırın veya --repo YOL ile yolu belirtin."
)
MSG_ANSIBLE_MISSING = (
    "ansible-playbook bu makinede kurulu değil; filo işlemleri çalıştırılamaz.\n"
    "Merkez makinaya kurun: sudo apt install ansible   (veya: pipx install ansible-core)"
)
MSG_INVENTORY_MISSING = (
    "Ansible envanteri bulunamadı: {dir}\n"
    "Gerçek envanteri oluşturun: cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml "
    "ve bf-<8 haneli bayi no> cihazları doldurun."
)
MSG_INVENTORY_EXAMPLE_ONLY = (
    "Yalnızca örnek envanter var (örnek cihaz kimlikleri içerir): {path}\n"
    "Gerçek cihazlara karşı kullanmayın; kopyalayıp gerçek kimlikleri yazın."
)
MSG_INVENTORY_UNREADABLE = "Envanter okunamıyor: {path}"
MSG_ROOT_REQUIRED = (
    "Bu işlem BU cihazda root yetkisi gerektirir.\n"
    "Konsolu tekrar sudo ile başlatın: sudo admin/bf"
)
MSG_TOOL_MISSING = (
    "{tool} bulunamadı (/usr/local/bin altında ve depo içinde yok).\n"
    "Kurulacak komut: sudo install -m 0755 scripts/diagnostics/{tool} /usr/local/bin/{tool}"
)
MSG_INSTALLER_MISSING = (
    "Kurulum betiği bulunamadı: {path}\n"
    "--repo ile doğru depo yolunu gösterin."
)
MSG_PLAYBOOK_MISSING = (
    "Playbook bulunamadı: {path}\n"
    "Konsolu deponun içinden çalıştırın (--repo YOL)."
)

# Target selection
MSG_TARGET_NONE = "Hedef seçilmedi; komut üretilmedi."
MSG_TARGET_EMPTY = "Cihaz seçilmedi."
MSG_TARGET_DEALER_INVALID = (
    "Geçersiz bayi numarası: '{value}'. 8 hane olmalı, boşluk ve harf olmamalı (örn. 12010101)."
)
MSG_TARGET_UNKNOWN = "'{value}' bir bayi numarası (8 hane), grup ya da 'all' değil."
MSG_TARGET_DEVICE_UNKNOWN = (
    "{host} envanterde yok ({inventory}).\n"
    "Cihazı önce ilgili dalga grubuna ekleyin."
)
MSG_TARGET_DEVICE_NO_WAVE = (
    "{host} onaylı bir dalgada değil. Dalga kapsamlı işlemler böyle bir cihazı reddeder (fail-closed)."
)
MSG_TARGET_GROUP_UNKNOWN = "'{group}' grubu envanterde yok. Bilinen gruplar: {groups}"
MSG_TARGET_GROUP_NOT_WAVE = (
    "'{group}' onaylı bir dalga değil. Dalga kapsamlı işlemler için: {waves}"
)
MSG_TARGET_GROUP_EMPTY = "'{group}' grubu boş; boş hedef reddedildi."
MSG_TARGET_ALL_EMPTY = "Envanterde hiç cihaz yok; boş hedef reddedildi."
MSG_TARGET_RELEASE_DEVICE = (
    "Sürüm kapılı işlemler dalga kapsamlıdır: tek cihaz seçilemez, dalga grubu seçin."
)
MSG_TARGET_RELEASE_ALL = (
    "Sürüm kapılı işlemler için filo geneli reddedildi: güncelleme dalga dalga yapılır."
)
MSG_TARGET_KNOWN_GROUPS = "Bilinen gruplar: {groups}"

# Gates
MSG_GATE_PLAN_TITLE = "Güvenlik kapıları"
MSG_GATE_ALREADY = "Bu işlem için ek kapı onayı gerekmiyor."
MSG_GATE_WAVE_TOKEN = (
    "Dalga onayı istendi: '{wave}'. Sürüm kapılı işlemler yalnızca yazılı dalga onayıyla koşar."
)
MSG_GATE_WAVE_TOKEN_ASK = "Onay için dalga adını aynen yazın ({wave}): "
MSG_GATE_WAVE_REFUSED = "Dalga onayı verilmedi; işlem yapılmadı."
MSG_GATE_GATE_FLAG = "Onayla birlikte playbook'a -e wave_gate_confirmed=true iletilecek."
MSG_GATE_PRODUCTION = (
    "DALGA 'production' CANLI FİLODUR. Playbook, operation/üretim onayı olmadan koşmayı reddeder."
)
MSG_GATE_PRODUCTION_ASK = "Canlı filo onayı için 'production' yazın: "
MSG_GATE_PRODUCTION_APPROVAL = (
    "ÜRETİM ONAYI: bu komut canlı filoyu değiştirir ve -e production_override=true iletilecek. Onaylıyor musunuz?"
)
MSG_GATE_PRODUCTION_REFUSED = "Üretim onayı verilmedi; işlem yapılmadı."
MSG_GATE_FLEET_TOKEN = (
    "FİLO GENELİ: komut envanterdeki tüm cihazları ({count}) hedefliyor. Bu en geniş kapsamdır."
)
MSG_GATE_FLEET_TOKEN_ASK = "Filo geneli onayı için 'all' yazın: "
MSG_GATE_FLEET_REFUSED = "Filo geneli onayı verilmedi; işlem yapılmadı."
MSG_GATE_WAVE_BY_WAVE = (
    "Bu playbook dalga kapsamlı: filo, dalga dalga işlenir ve ilk hatada DURUR.\n"
    "Sıra: {order}"
)
MSG_GATE_WAVE_LOOP_ASK = "Dalga '{wave}' ({count} cihaz) için onay vermek üzere dalga adını yazın: "
MSG_GATE_WAVE_SKIPPED = "'{wave}' dalgası operatör tarafından atlandı."
MSG_GATE_WAVE_FAILED = "'{wave}' dalgası başarısız oldu (çıkış kodu {rc}); sıra DURDURULDU, sonraki dalgaya dokunulmadı."
MSG_GATE_WAVE_NOT_RUN = "'{wave}' dalgası tamamlanmadı; sıra DURDURULDU."
MSG_GATE_START_FIRST = "İlk dalga ile başlansın mı?"
MSG_GATE_ORDER = "lab → pilot_1 → pilot_2 → wave_1 → wave_2 → production"
MSG_GATE_SCOPE_MISMATCH = (
    "RED: {playbook} için konsol kapsamı '{declared}' bekliyor, playbook '{actual}' diyor.\n"
    "Playbook kendi kapılarının kaynağıdır; konsol tablosu güncellenmeden bu playbook çalıştırılmaz."
)
MSG_GATE_NO_TARGET = "Hedef seçilmedi; komut üretilmedi (kapı kuralı)."

# Prompts / extra variables
MSG_PROMPT_DEALER = "Bayi numarası (8 hane): "
MSG_PROMPT_TARGET = "Hedef (bayi no, grup ya da 'all'): "
MSG_PROMPT_CHOICE = "Seçim > "
MSG_PROMPT_PACKAGES = "Paketler (virgülle ayrılmış, paket=sürüm): "
MSG_PROMPT_SERVICE = "Servis adı: "
MSG_PROMPT_SCRIPT = "Betik yolu (mutlak): "
MSG_PROMPT_SCRIPT_ARGS = "Betik argümanları (isteğe bağlı): "
MSG_PROMPT_GRACE = "Yeniden başlatma için bekleme süresi (saniye) [{default}]: "
MSG_PROMPT_DISK = "Uyarı eşiği yüzdesi (boş = playbook varsayılanı 80): "
MSG_PROMPT_LOG_LINES = "Cihaz başına log satırı [{default}]: "
MSG_PROMPT_VERSION = "Beklenen Field OS sürümü (boş = sapma denetimi yok): "

MSG_PKG_HINT = "Yalnız kesin sürüm: paket=sürüm (aralık, 'latest' ve boş liste reddedilir)."
MSG_PKG_REQUIRED = "En az bir sabitlenmiş paket gerekir."
MSG_PKG_INVALID = "Geçersiz pin: '{value}'. Beklenen biçim: paket=sürüm (örn. docker-ce=5:27.0.3-1~ubuntu.24.04~noble)."
MSG_PKG_LATEST = (
    "Reddedildi: '{value}' kesin bir sürüm değil. 'latest' politikası yoktur; "
    "pinlenmiş sürüm yazın (docs/10)."
)
MSG_SERVICE_HINT = "İzinli servisler: {allowlist}"
MSG_SERVICE_INVALID = "Reddedildi: '{value}' izinli servis listesinde değil (playbook da reddederdi)."
MSG_SCRIPT_ABSOLUTE = "Betik yolu mutlak olmalı (/ ile başlamalı)."
MSG_SCRIPT_OUTSIDE = "Reddedildi: '{value}' izinli dizinlerin dışında ({dirs})."
MSG_GRACE_INVALID = "Bekleme süresi tam sayı saniye olmalı."
MSG_PCT_INVALID = "Eşik {min} ile {max} arasında olmalı."
MSG_LINES_INVALID = "Satır sayısı pozitif bir tam sayı olmalı."

# Command / run flow
MSG_COMMAND_TITLE = "Çalıştırılacak komut"
MSG_RUN_ASK = "Bu komut çalıştırılsın mı? [y=çalıştır / c=--check ile çalıştır / N=iptal]: "
MSG_DESTRUCTIVE_WARN = "DURUM DEĞİŞTİREN İŞLEM: {label}"
MSG_DESTRUCTIVE_SUB = "Onaylamadan önce yukarıdaki komutu okuyun; seçilen cihazları değiştirir."
MSG_DESTRUCTIVE_GATE = (
    "Yıkıcı işlem kapısı: {label} seçilen cihazları değiştirir. "
    "Bu onaydan sonra komut üretilir ve çalıştırmadan önce ayrıca sorulur."
)
MSG_ASK_YES_NO = "{question} [e/H]: "
MSG_CHECK_MODE = "Check modu: komut --check ile çalışacak, hiçbir değişiklik uygulanmayacak."
MSG_DRY_RUN = "DENEME (dry-run) MODU: komutlar yazılır, asla çalıştırılmaz."
MSG_DRY_RUN_WARN = "dry-run: yukarıdaki komut ÇALIŞTIRILMADI."
MSG_RUN_OK = "Komut başarıyla tamamlandı (çıkış kodu 0)."
MSG_RUN_FAIL = "Komut {rc} çıkış koduyla başarısız oldu."
MSG_RUN_ABORTED = "Komut {signal} ile kesildi."
MSG_LOG_FALLBACK = "{requested} yazılamıyor; denetim kaydı {fallback} dosyasına yazılıyor (mod 600)."
MSG_LOG_NONE = "Yazılabilir denetim kaydı bulunamadı; bu oturum kaydedilmeyecek."

# Simple (default) menu
SIMPLE_MENU_TITLE = SCREEN_TITLE
SIMPLE_MENU_SUBTITLE = "Bu cihazı kurmak ve durumunu görmek için 1 veya 2 yazın"
SIMPLE_ITEM_INSTALL_LABEL = "Kur"
SIMPLE_ITEM_INSTALL_DESC = "Bu cihazı Field OS standardına getir (kurulum ekranı)"
SIMPLE_ITEM_STATUS_LABEL = "Durum"
SIMPLE_ITEM_STATUS_DESC = "Kurulum ve cihaz durumunu göster (salt okunur)"
SIMPLE_ITEM_EXIT_LABEL = "Çıkış"
SIMPLE_ITEM_EXIT_DESC = "Konsoldan çık"
SIMPLE_ADVANCED_LABEL = "Detaylı mod"
SIMPLE_ADVANCED_DESC = "Filo işlemleri, merkez hazırlığı, araçlar ve 21 playbook"

# Full (detailed) menu
FULL_MENU_TITLE = "Detaylı mod"
FULL_MENU_SUBTITLE = "Tüm operasyonlar; güvenlik kapıları her işlemde geçerlidir"
CAT_INSTALL = "Kurulum"
CAT_DEVICES = "Cihaz işlemleri"
CAT_CENTRAL = "Merkez hazırlığı"
CAT_TOOLS = "Araçlar"
CAT_INFO = "Cihaz bilgisi"

MSG_FULL_MODE_HINT = "Detaylı mod açık: filo işlemleri ve araçlar görünür."
MSG_SIMPLE_MODE_HINT = "Basit mod: 1) Kur, 2) Durum, 3) Çıkış. Detaylı özellikler için 'd' yazın ya da --full ile başlatın."

# Audit log
AUDIT_SESSION = "SESSION"
AUDIT_TARGET = "TARGET"
AUDIT_RUN = "RUN"
AUDIT_DRYRUN = "DRYRUN"
AUDIT_OK = "OK"
AUDIT_FAIL = "FAIL"
AUDIT_CANCEL = "CANCEL"
AUDIT_STOP = "STOP"

# Non-interactive listings
LIST_TITLE_REPORTS = "Salt okunur filo raporları (cihazlara dokunmaz)"
LIST_TITLE_MAINTENANCE = "Filo bakım işlemleri (yıkıcı olanlar iki kez onay ister)"
LIST_NOTE_WAVE = "scope=wave  ->  -e operation_wave=<dalga> -e operation_confirmed=true"
LIST_NOTE_RELEASE = "scope=release ->  -e release_wave=<dalga> + yazılı dalga onayı"
LIST_NOTE_PLAYBOOK = "Kapsam her playbook dosyasından okunur; uyuşmazsa çalıştırılmaz."
