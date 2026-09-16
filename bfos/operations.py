"""Operation model for the bfos operator console.

This module is the behaviour contract of the console, ported from the proven
bash console (``admin/bf-menu`` + ``admin/lib/targets.sh``) so the two entry
points can never disagree:

  * the 21 Ansible playbooks of ``ansible/playbooks/`` with their declared
    scope (simple / wave / release) and destructive flag,
  * the local install flow (``scripts/install/blueforce-install.sh``),
  * the local diagnostics tools (``bf-status``, ``bf-diagnostics``,
    ``bf-support-bundle``, ``bf-release``, ``bf-remote-status`` ...),
  * target selection: dealer number ``^[0-9]{8}$``, group/wave, or ``all``,
  * the safety gates: scope cross-check against the playbook file, production
    override, release/wave tokens, destructive second confirmation, the
    fleet-wide wave-by-wave loop that stops at the first failure.

Design rules:
  * no UI and no execution: every function here is pure or reads a file, and
    every command is *produced* as an argv list for :mod:`bfos.runner`,
  * refusals are raised as :class:`Refused` carrying a Turkish operator
    message; nothing is auto-confirmed or silently downgraded,
  * standard library only, Python 3.8+.
"""

from __future__ import annotations

import json
import os
import platform
import re
import socket
import stat
from dataclasses import dataclass, field, replace
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from . import config

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------


class Refused(Exception):
    """A refusal with an operator-facing Turkish explanation.

    ``detail`` holds optional extra lines (hints, remediation) so the UI can
    print the message and the hint separately.
    """

    def __init__(self, message: str, detail: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.detail = detail


# ---------------------------------------------------------------------------
# Identity helpers (mirrors admin/lib/targets.sh)
# ---------------------------------------------------------------------------
DEALER_RE = re.compile(config.DEALER_PATTERN)
HOST_RE = re.compile(config.HOST_PATTERN)


def dealer_is_valid(value: str) -> bool:
    return bool(DEALER_RE.match(value or ""))


def dealer_to_host(dealer: str) -> str:
    return "bf-{0}".format(dealer)


def dealer_to_device_id(dealer: str) -> str:
    return "BF-{0}".format(dealer)


def host_to_dealer(host: str) -> Optional[str]:
    match = HOST_RE.match(host or "")
    return match.group(0)[3:] if match else None


def is_wave(name: str) -> bool:
    return name in config.WAVES


def waves_csv() -> str:
    return ",".join(config.WAVES)


def waves_readable() -> str:
    return ", ".join(config.WAVES)


# ---------------------------------------------------------------------------
# Operation catalogue -- 21 playbooks, one row each
# ---------------------------------------------------------------------------
PROMPT_NONE = "none"
PROMPT_PACKAGES = "packages"
PROMPT_SERVICE = "service"
PROMPT_SCRIPT = "script"
PROMPT_GRACE = "grace"
PROMPT_DISK_PCT = "disk_pct"
PROMPT_LOG_LINES = "log_lines"
PROMPT_VERSION = "expected_version"

CATEGORY_REPORT = "report"
CATEGORY_MAINTENANCE = "maintenance"


@dataclass(frozen=True)
class Operation:
    """One fleet operation, bound to exactly one existing playbook."""

    ident: str
    label: str
    playbook: str
    declared_scope: str
    destructive: bool
    prompt: str
    description: str
    category: str

    @property
    def target_mode(self) -> str:
        """Target mode the operator is offered for this operation."""
        if self.declared_scope == config.SCOPE_RELEASE:
            return config.MODE_RELEASE
        if self.declared_scope == config.SCOPE_WAVE:
            return config.MODE_WAVE
        return config.MODE_ANY


# 2.1 Read-only fleet reports -- no playbook in this list changes a device.
REPORT_OPERATIONS: Tuple[Operation, ...] = (
    Operation("ping", "Erişilebilirlik testi (ping)", "bf-ping.yml", "simple", False, PROMPT_NONE,
              "SSH erişimi kontrol edilir (salt okunur)", CATEGORY_REPORT),
    Operation("uptime", "Çalışma süresi", "bf-uptime.yml", "simple", False, PROMPT_NONE,
              "Açık kalma süresi ve sistem yükü", CATEGORY_REPORT),
    Operation("disk", "Disk kullanımı", "bf-disk-check.yml", "simple", False, PROMPT_DISK_PCT,
              "Disk doluluğu; eşik üstünde uyarı verir", CATEGORY_REPORT),
    Operation("docker", "Docker durumu", "bf-docker-status.yml", "simple", False, PROMPT_NONE,
              "Docker servisi ve konteynerler (salt okunur)", CATEGORY_REPORT),
    Operation("packages", "Paket sürümleri", "bf-package-check.yml", "simple", False, PROMPT_NONE,
              "Sabitlenmiş paketlerin kurulu sürümleri", CATEGORY_REPORT),
    Operation("security-updates", "Bekleyen güvenlik güncellemeleri",
              "bf-security-updates-check.yml", "simple", False, PROMPT_NONE,
              "Yalnız rapor; hiçbir paket kurmaz", CATEGORY_REPORT),
    Operation("provisioning-status", "Kurulum fazı raporu", "bf-provisioning-status.yml", "wave",
              False, PROMPT_NONE, "Cihaz başına state.json fazı", CATEGORY_REPORT),
    Operation("enrollment-status", "Kayıt ve merkez kanıtı", "bf-enrollment-status.yml", "wave",
              False, PROMPT_NONE, "ENROLLED/READY iddiası ↔ merkez kanıtı", CATEGORY_REPORT),
    Operation("fieldos-version", "Field OS sürüm raporu", "bf-fieldos-version.yml", "wave",
              False, PROMPT_VERSION, "Cihaz başına sürüm; isteğe bağlı sapma denetimi",
              CATEGORY_REPORT),
    Operation("remote-channels", "Uzak erişim kanalları", "bf-remote-channels-check.yml", "wave",
              False, PROMPT_NONE, "SSH/xRDP/RustDesk/WireGuard hazırlığı", CATEGORY_REPORT),
    Operation("offline-ready", "Çevrimdışı hazırlık raporu", "bf-offline-ready-check.yml", "wave",
              False, PROMPT_NONE, "İnternetsiz kurulum için yerel ön koşullar", CATEGORY_REPORT),
)

# 2.2 Fleet maintenance -- destructive rows ask a second, explicit question.
MAINTENANCE_OPERATIONS: Tuple[Operation, ...] = (
    Operation("rdp-restart", "RDP servisini yeniden başlat", "bf-rdp-restart.yml", "simple", True,
              PROMPT_NONE, "xrdp servisini yeniden başlatır", CATEGORY_MAINTENANCE),
    Operation("rustdesk-restart", "RustDesk servisini yeniden başlat", "bf-rustdesk-restart.yml",
              "simple", True, PROMPT_NONE, "RustDesk servisini yeniden başlatır",
              CATEGORY_MAINTENANCE),
    Operation("wireguard-restart", "WireGuard servisini yeniden başlat",
              "bf-wireguard-restart.yml", "simple", True, PROMPT_NONE,
              "wg-quick@wg0 servisini yeniden başlatır", CATEGORY_MAINTENANCE),
    Operation("service-restart", "İzinli bir servisi yeniden başlat", "bf-service-restart.yml",
              "simple", True, PROMPT_SERVICE, "Yalnız izinli servis adları kabul edilir",
              CATEGORY_MAINTENANCE),
    Operation("gui-off", "Grafik arayüzü kapat (headless)", "bf-gui-off.yml", "wave", True,
              PROMPT_NONE, "Dalgayı multi-user.target'e alır", CATEGORY_MAINTENANCE),
    Operation("gui-on", "Grafik arayüzü aç (bakım)", "bf-gui-on.yml", "wave", True, PROMPT_NONE,
              "Grafik oturumu yeniden başlatır", CATEGORY_MAINTENANCE),
    Operation("collect-logs", "Log topla / destek paketi", "bf-collect-logs.yml", "wave", False,
              PROMPT_LOG_LINES, "Zaman damgalı journal kaydı ve destek paketi",
              CATEGORY_MAINTENANCE),
    Operation("run-script", "Onaylı betik çalıştır", "bf-run-script.yml", "wave", True,
              PROMPT_SCRIPT, "Yalnız /opt/blueforce/bin ve /usr/local/sbin",
              CATEGORY_MAINTENANCE),
    Operation("reboot", "Kontrollü yeniden başlatma", "bf-reboot.yml", "release", True,
              PROMPT_GRACE, "Sağlık kapılı, sıralı yeniden başlatma", CATEGORY_MAINTENANCE),
    Operation("deploy-update", "Onaylı paket güncellemesi kur", "bf-deploy-update.yml", "release",
              True, PROMPT_PACKAGES, "Sabit sürümlü paketler, sağlık kapılı", CATEGORY_MAINTENANCE),
)

ALL_OPERATIONS: Tuple[Operation, ...] = REPORT_OPERATIONS + MAINTENANCE_OPERATIONS

#: Variables the playbooks use to express their own gates. The console derives
#: the scope from the playbook file and adds a variable only when the playbook
#: actually declares it (a permanent parity rule with admin/bf-menu).
VAR_OPERATION_WAVE = "operation_wave"
VAR_RELEASE_WAVE = "release_wave"
VAR_OPERATION_CONFIRMED = "operation_confirmed"
VAR_WAVE_GATE_CONFIRMED = "wave_gate_confirmed"
VAR_REBOOT_CONFIRMED = "reboot_confirmed"
VAR_PRODUCTION_OVERRIDE = "production_override"
VAR_ALLOW_PRODUCTION_REBOOT = "allow_production_reboot"

GATE_VARIABLES = (
    VAR_OPERATION_WAVE,
    VAR_RELEASE_WAVE,
    VAR_WAVE_GATE_CONFIRMED,
    VAR_REBOOT_CONFIRMED,
    VAR_PRODUCTION_OVERRIDE,
    VAR_ALLOW_PRODUCTION_REBOOT,
)


def find_operation(ident: str) -> Optional[Operation]:
    for operation in ALL_OPERATIONS:
        if operation.ident == ident:
            return operation
    return None


def operations_of(category: str) -> Tuple[Operation, ...]:
    return tuple(op for op in ALL_OPERATIONS if op.category == category)


def catalogue_rows() -> Tuple[Operation, ...]:
    """All operations ordered exactly like the bash catalogue."""
    return tuple(sorted(ALL_OPERATIONS, key=lambda op: (op.category != CATEGORY_REPORT, op.ident)))


# ---------------------------------------------------------------------------
# Playbook file: the source of truth for a playbook's own gates
# ---------------------------------------------------------------------------
def non_comment_text(text: str) -> str:
    """The playbook text without full-line comments.

    Deliberately identical to ``grep -vE '^[[:space:]]*#'`` in bf-menu: a
    trailing comment is kept, so the console and the bash console can never
    disagree about what a playbook declares.
    """
    keep = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    return "\n".join(keep)


def playbook_uses_var(text: str, var: str) -> bool:
    """True when VAR appears as a whole word outside the playbook's comments."""
    pattern = r"\b{0}\b".format(re.escape(var))
    return re.search(pattern, non_comment_text(text)) is not None


def playbook_scope(text: str) -> str:
    """Derive wave / release / simple from the playbook's own variables."""
    if playbook_uses_var(text, VAR_RELEASE_WAVE):
        return config.SCOPE_RELEASE
    if playbook_uses_var(text, VAR_OPERATION_WAVE):
        return config.SCOPE_WAVE
    return config.SCOPE_SIMPLE


class Repository:
    """Read-only view of the Blueforce checkout the console runs from."""

    def __init__(self, root: str) -> None:
        self.root = os.path.abspath(root)

    # -- discovery ---------------------------------------------------------
    def path(self, rel: str) -> str:
        return os.path.join(self.root, rel)

    def looks_valid(self) -> bool:
        return os.path.isdir(self.path("ansible")) and os.path.isdir(self.path("scripts"))

    def playbook_path(self, playbook: str) -> str:
        return self.path(os.path.join(config.PLAYBOOK_DIR_REL, playbook))

    def playbook_text(self, playbook: str) -> str:
        path = self.playbook_path(playbook)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                return handle.read()
        except OSError as exc:
            raise Refused(
                config.MSG_PLAYBOOK_MISSING.format(path=path), str(exc)
            ) from exc

    def verify_scope(self, operation: Operation) -> str:
        """Cross-check the catalogue scope against the playbook file.

        The playbook is the source of truth for its own gates: a table that
        drifted must refuse to run instead of silently dropping a gate.
        """
        text = self.playbook_text(operation.playbook)
        actual = playbook_scope(text)
        if actual != operation.declared_scope:
            raise Refused(
                config.MSG_GATE_SCOPE_MISMATCH.format(
                    playbook=operation.playbook,
                    declared=operation.declared_scope,
                    actual=actual,
                )
            )
        return actual

    def playbook_uses(self, playbook: str, var: str) -> bool:
        return playbook_uses_var(self.playbook_text(playbook), var)

    # -- local assets ------------------------------------------------------
    def installer_path(self) -> str:
        path = self.path(config.INSTALLER_REL)
        if not os.path.isfile(path):
            raise Refused(config.MSG_INSTALLER_MISSING.format(path=path))
        return path

    def tool_path(self, tool: str) -> str:
        """Preferred path of a diagnostics/maintenance tool (bf_tool_path)."""
        candidates = (
            os.path.join(config.TOOL_BIN_DIR, tool),
            self.path(os.path.join(config.DIAGNOSTICS_DIR_REL, tool)),
            self.path(os.path.join("scripts/maintenance", tool)),
        )
        for candidate in candidates:
            if os.access(candidate, os.X_OK) and os.path.isfile(candidate):
                return candidate
        raise Refused(config.MSG_TOOL_MISSING.format(tool=tool))

    def group_vars_path(self) -> Optional[str]:
        path = self.path(config.GROUP_VARS_REL)
        return path if os.path.isfile(path) else None

    # -- inventory ---------------------------------------------------------
    def inventory_candidates(self) -> Tuple[str, ...]:
        base = self.path(config.INVENTORY_DIR_REL)
        return tuple(os.path.join(base, name) for name in config.INVENTORY_CANDIDATES)

    def find_inventory(self, explicit: str = "") -> str:
        """Resolve the Ansible inventory, or refuse with remediation.

        ``hosts.example.yml`` is never selected automatically: it carries
        example device IDs and must only be used after a deliberate copy.
        """
        if explicit:
            if os.path.isfile(explicit) and os.access(explicit, os.R_OK):
                return os.path.abspath(explicit)
            raise Refused(config.MSG_INVENTORY_UNREADABLE.format(path=explicit))
        for candidate in self.inventory_candidates():
            if os.path.isfile(candidate) and os.access(candidate, os.R_OK):
                return candidate
        example = self.path(config.INVENTORY_EXAMPLE_REL)
        detail = ""
        if os.path.isfile(example):
            detail = config.MSG_INVENTORY_EXAMPLE_ONLY.format(path=example)
        raise Refused(
            config.MSG_INVENTORY_MISSING.format(dir=self.path(config.INVENTORY_DIR_REL)),
            detail,
        )


# ---------------------------------------------------------------------------
# Inventory parsing (a deliberately small YAML reader, mirrors targets.sh)
# ---------------------------------------------------------------------------
@dataclass
class Inventory:
    """group -> ordered hosts, parsed from the Ansible inventory."""

    path: Optional[str] = None
    groups: Dict[str, List[str]] = field(default_factory=dict)

    # -- construction ------------------------------------------------------
    @classmethod
    def parse(cls, text: str, path: Optional[str] = None) -> "Inventory":
        groups: Dict[str, List[str]] = {}
        # Stack of (key, indent) for keys whose value is an empty mapping.
        stack: List[Tuple[str, int]] = []
        host_block = False
        host_indent = 0
        host_step: Optional[int] = None
        host_group = ""

        for raw in text.splitlines():
            line = raw.rstrip()
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("-"):
                continue
            if ":" not in line:
                continue
            indent = len(line) - len(line.lstrip(" "))
            key_part, _, value_part = line.partition(":")
            key = key_part.strip().strip("'\"").strip()
            value = value_part.strip()
            if not key:
                continue

            # Close blocks that are at or above this key's indentation.
            while stack and stack[-1][1] >= indent:
                stack.pop()
            if host_block and indent <= host_indent:
                host_block = False

            if key == "hosts" and not value:
                host_block = True
                host_indent = indent
                host_step = None
                host_group = stack[-1][0] if stack else ""
                stack.append((key, indent))
                continue

            if host_block and indent > host_indent:
                if host_step is None:
                    host_step = indent
                if indent == host_step:
                    groups.setdefault(host_group, [])
                    if key not in groups[host_group]:
                        groups[host_group].append(key)
                    stack.append((key, indent))
                    continue

            if not value:
                stack.append((key, indent))

        return cls(path=path, groups=groups)

    @classmethod
    def load(cls, path: str) -> "Inventory":
        with open(path, "r", encoding="utf-8") as handle:
            return cls.parse(handle.read(), path=path)

    @classmethod
    def load_repository(cls, repo: Repository, explicit: str = "") -> "Inventory":
        """Load the inventory, or return an empty one marked as unresolved.

        Callers that must refuse on a missing inventory ask the repository
        directly (:meth:`Repository.find_inventory`); the UI keeps working with
        an unresolved inventory so read-only screens can still explain what is
        missing instead of crashing.
        """
        try:
            resolved = repo.find_inventory(explicit)
        except Refused:
            return cls(path=None, groups={})
        try:
            return cls.load(resolved)
        except (OSError, ValueError):
            return cls(path=None, groups={})

    # -- queries -----------------------------------------------------------
    @property
    def resolved(self) -> bool:
        """True when an inventory was actually found and parsed.

        A path is not required: an inventory parsed from text (tests, callers
        that hold the YAML themselves) is just as usable as a file on disk.
        """
        return self.path is not None or bool(self.groups)

    def labels(self) -> str:
        return self.path or "çözümlenmedi"

    def group_names(self) -> Tuple[str, ...]:
        return tuple(self.groups)

    def hosts_of(self, group: str) -> Tuple[str, ...]:
        return tuple(self.groups.get(group, ()))

    def group_exists(self, group: str) -> bool:
        return group in self.groups

    def host_exists(self, host: str) -> bool:
        return any(host in hosts for hosts in self.groups.values())

    def all_hosts(self) -> Tuple[str, ...]:
        hosts: List[str] = []
        for group_hosts in self.groups.values():
            for host in group_hosts:
                if host not in hosts:
                    hosts.append(host)
        return tuple(hosts)

    def count_all(self) -> int:
        return len(self.all_hosts())

    def waves_present(self) -> Tuple[str, ...]:
        """Canonical waves that exist in the inventory, in rollout order."""
        return tuple(wave for wave in config.WAVES if self.group_exists(wave))

    def host_wave(self, host: str) -> Optional[str]:
        """The approved wave containing HOST, or None."""
        for wave in config.WAVES:
            if host in self.groups.get(wave, ()):
                return wave
        return None


# ---------------------------------------------------------------------------
# Target selection (mirrors bf_target_*)
# ---------------------------------------------------------------------------
KIND_HOST = "host"
KIND_GROUP = "group"
KIND_ALL = "all"


@dataclass(frozen=True)
class Target:
    kind: str
    limit: str
    wave: str
    count: int
    label: str


def _target_host(dealer: str, mode: str, inventory: Inventory) -> Target:
    if not dealer_is_valid(dealer):
        raise Refused(config.MSG_TARGET_DEALER_INVALID.format(value=dealer))
    if mode == config.MODE_RELEASE:
        raise Refused(config.MSG_TARGET_RELEASE_DEVICE)
    if not inventory.resolved:
        raise Refused(config.MSG_TARGET_DEVICE_UNKNOWN.format(
            host=dealer_to_host(dealer), inventory=inventory.labels()))
    host = dealer_to_host(dealer)
    if not inventory.host_exists(host):
        raise Refused(config.MSG_TARGET_DEVICE_UNKNOWN.format(host=host, inventory=inventory.labels()))
    wave = inventory.host_wave(host) or ""
    if not wave and mode != config.MODE_ANY:
        raise Refused(config.MSG_TARGET_DEVICE_NO_WAVE.format(host=host))
    label = "cihaz {0} ({1})".format(dealer_to_device_id(dealer), host)
    if wave:
        label += " — dalga '{0}'".format(wave)
    return Target(kind=KIND_HOST, limit=host, wave=wave, count=1, label=label)


def _target_group(group: str, mode: str, inventory: Inventory) -> Target:
    if not inventory.resolved or not inventory.group_exists(group):
        raise Refused(
            config.MSG_TARGET_GROUP_UNKNOWN.format(
                group=group, groups=" ".join(inventory.group_names()) or "-"
            )
        )
    if mode in (config.MODE_WAVE, config.MODE_RELEASE) and not is_wave(group):
        raise Refused(config.MSG_TARGET_GROUP_NOT_WAVE.format(group=group, waves=waves_readable()))
    count = len(inventory.hosts_of(group))
    if count == 0:
        raise Refused(config.MSG_TARGET_GROUP_EMPTY.format(group=group))
    label = "dalga '{0}' ({1} cihaz)".format(group, count) if is_wave(group) else \
        "grup '{0}' ({1} cihaz)".format(group, count)
    wave = group if is_wave(group) else ""
    return Target(kind=KIND_GROUP, limit=group, wave=wave, count=count, label=label)


def _target_all(mode: str, inventory: Inventory) -> Target:
    if mode == config.MODE_RELEASE:
        raise Refused(config.MSG_TARGET_RELEASE_ALL)
    if not inventory.resolved or inventory.count_all() == 0:
        raise Refused(config.MSG_TARGET_ALL_EMPTY)
    count = inventory.count_all()
    return Target(kind=KIND_ALL, limit="all", wave="", count=count,
                  label="filo geneli ({0} cihaz)".format(count))


def resolve_target(word: str, mode: str, inventory: Inventory) -> Target:
    """Turn one operator word into a validated target.

    Accepts an 8-digit dealer number, a ``bf-<dealer>`` hostname (convenience),
    a group/wave name, or ``all``. Anything else is refused with a Turkish
    explanation; nothing is guessed.
    """
    word = (word or "").strip()
    if not word:
        raise Refused(config.MSG_TARGET_EMPTY)
    if word == "all":
        return _target_all(mode, inventory)
    if dealer_is_valid(word):
        return _target_host(word, mode, inventory)
    if inventory.resolved and inventory.group_exists(word):
        return _target_group(word, mode, inventory)
    if HOST_RE.match(word) and dealer_is_valid(word[3:]):
        return _target_host(word[3:], mode, inventory)
    raise Refused(
        config.MSG_TARGET_UNKNOWN.format(value=word),
        config.MSG_TARGET_KNOWN_GROUPS.format(groups=" ".join(inventory.group_names()) or "-"),
    )


def wave_sequence(inventory: Inventory) -> Tuple[Tuple[str, int], ...]:
    """Waves present in the inventory with their device counts, in order."""
    return tuple((wave, len(inventory.hosts_of(wave))) for wave in inventory.waves_present())


# ---------------------------------------------------------------------------
# Gates: the confirmation plan (what the operator must state explicitly)
# ---------------------------------------------------------------------------
STEP_TOKEN = "token"
STEP_APPROVAL = "approval"


@dataclass(frozen=True)
class GateStep:
    """One explicit confirmation the operator has to give before a run."""

    kind: str
    key: str
    prompt: str
    message: str = ""
    token: str = ""
    unlocks: Tuple[str, ...] = ()


@dataclass
class GatesGranted:
    """Flags granted by the operator's confirmations.

    ``build_ansible_command`` adds a gate variable only when the matching flag
    is granted AND the playbook declares that variable, so a command can never
    become less gated than the playbook expects.
    """

    wave_gate_confirmed: bool = False
    production_override: bool = False
    allow_production_reboot: bool = False
    fleet_wide: bool = False

    def grant(self, step: GateStep) -> "GatesGranted":
        changes = {name: True for name in step.unlocks if hasattr(self, name)}
        return replace(self, **changes) if changes else self


def confirmation_plan(
    operation: Operation,
    scope: str,
    target: Target,
    wave: str = "",
    wave_gate_supported: bool = False,
) -> List[GateStep]:
    """The ordered list of confirmations required for one operation run.

    Rules (all preserved from the bash console):
      * the production wave requires the word ``production`` **and** a separate
        production approval that unlocks ``production_override=true``,
      * a release-gated operation (reboot, deploy-update) requires its wave name
        to be written out before anything is built; a wave-scoped read-only
        report does not (the bash console asks no token for it either),
      * a destructive operation requires a second, explicit approval,
      * a fleet-wide simple run requires the word ``all``.
    """
    steps: List[GateStep] = []
    effective_wave = wave or target.wave

    if scope in (config.SCOPE_WAVE, config.SCOPE_RELEASE):
        if effective_wave == config.PRODUCTION_WAVE:
            message = config.MSG_GATE_PRODUCTION
            if wave_gate_supported:
                message = message + "\n" + config.MSG_GATE_GATE_FLAG
            steps.append(
                GateStep(
                    kind=STEP_TOKEN,
                    key="production_token",
                    prompt=config.MSG_GATE_PRODUCTION_ASK,
                    message=message,
                    token=config.PRODUCTION_WAVE,
                    unlocks=(VAR_WAVE_GATE_CONFIRMED,) if wave_gate_supported else (),
                )
            )
            steps.append(
                GateStep(
                    kind=STEP_APPROVAL,
                    key="production_approval",
                    prompt=config.MSG_GATE_PRODUCTION_APPROVAL,
                    message=config.MSG_GATE_PRODUCTION,
                    unlocks=(VAR_PRODUCTION_OVERRIDE, VAR_ALLOW_PRODUCTION_REBOOT),
                )
            )
        elif effective_wave and scope == config.SCOPE_RELEASE:
            # Release-gated operations never run from a typed word alone: the
            # operator has to name the exact wave that is being released.
            message = config.MSG_GATE_WAVE_TOKEN.format(wave=effective_wave)
            if wave_gate_supported:
                message = message + "\n" + config.MSG_GATE_GATE_FLAG
            steps.append(
                GateStep(
                    kind=STEP_TOKEN,
                    key="wave_token",
                    prompt=config.MSG_GATE_WAVE_TOKEN_ASK.format(wave=effective_wave),
                    message=message,
                    token=effective_wave,
                    unlocks=(VAR_WAVE_GATE_CONFIRMED,) if wave_gate_supported else (),
                )
            )

    if target.kind == KIND_ALL and scope == config.SCOPE_SIMPLE:
        steps.append(
            GateStep(
                kind=STEP_TOKEN,
                key="fleet_token",
                prompt=config.MSG_GATE_FLEET_TOKEN_ASK,
                message=config.MSG_GATE_FLEET_TOKEN.format(count=target.count),
                token="all",
                unlocks=("fleet_wide",),
            )
        )

    if operation.destructive and not any(step.key == "production_approval" for step in steps):
        # The second, explicit approval for a state-changing operation. It is a
        # gate (it happens before the command is even built); the run prompt
        # after the command has been shown is a separate, final confirmation.
        steps.append(
            GateStep(
                kind=STEP_APPROVAL,
                key="destructive_approval",
                prompt=config.MSG_DESTRUCTIVE_SUB,
                message=config.MSG_DESTRUCTIVE_GATE.format(label=operation.label),
            )
        )
    return steps


# ---------------------------------------------------------------------------
# Extra -e variables, validated with the rules the playbooks enforce
# ---------------------------------------------------------------------------
PIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.:-]*=.+$")


def parse_packages(text: str) -> List[str]:
    pins: List[str] = []
    for chunk in (text or "").split(","):
        pin = chunk.strip()
        if not pin:
            continue
        if not PIN_RE.match(pin):
            raise Refused(config.MSG_PKG_INVALID.format(value=pin))
        version = pin.partition("=")[2].strip("=").strip()
        if not version or version.lower().startswith("latest"):
            raise Refused(config.MSG_PKG_LATEST.format(value=pin))
        pins.append(pin)
    if not pins:
        raise Refused(config.MSG_PKG_REQUIRED)
    return pins


def packages_expression(pins: Sequence[str]) -> str:
    """The ``update_packages`` value: ``["pkg=ver",...]`` like bf_prompt_packages.

    Only the value is returned; the caller pairs it with the variable name, so
    exactly one ``update_packages=`` prefix ever reaches the command line.
    """
    return "[{0}]".format(",".join('"{0}"'.format(pin) for pin in pins))


def parse_service(text: str) -> str:
    name = (text or "").strip()
    if name not in config.SERVICE_ALLOWLIST:
        raise Refused(
            config.MSG_SERVICE_INVALID.format(value=name),
            config.MSG_SERVICE_HINT.format(allowlist=" ".join(config.SERVICE_ALLOWLIST)),
        )
    return name


def parse_script(path: str, args: str = "") -> List[Tuple[str, str]]:
    script = (path or "").strip()
    if not script.startswith("/"):
        raise Refused(config.MSG_SCRIPT_ABSOLUTE)
    if not any(script.startswith(directory + "/") for directory in config.SCRIPT_DIRS):
        raise Refused(
            config.MSG_SCRIPT_OUTSIDE.format(value=script, dirs=" ".join(config.SCRIPT_DIRS))
        )
    pairs = [("script_path", script)]
    if (args or "").strip():
        pairs.append(("script_args", args.strip()))
    return pairs


def parse_grace(text: str) -> str:
    value = (text or "").strip() or str(config.DEFAULT_REBOOT_GRACE)
    if not value.isdigit():
        raise Refused(config.MSG_GRACE_INVALID)
    return value


def parse_disk_pct(text: str) -> List[Tuple[str, str]]:
    value = (text or "").strip()
    if not value:
        return []
    if not value.isdigit() or not (config.DISK_WARN_MIN <= int(value) <= config.DISK_WARN_MAX):
        raise Refused(config.MSG_PCT_INVALID.format(min=config.DISK_WARN_MIN, max=config.DISK_WARN_MAX))
    return [("disk_warn_pct", value)]


def parse_log_lines(text: str) -> str:
    value = (text or "").strip() or str(config.DEFAULT_LOG_LINES)
    if not value.isdigit() or int(value) < 1:
        raise Refused(config.MSG_LINES_INVALID)
    return value


def parse_expected_version(text: str) -> List[Tuple[str, str]]:
    value = (text or "").strip()
    return [("fieldos_expected_version", value)] if value else []


def build_extra_vars(prompt: str, answers: Dict[str, str]) -> List[Tuple[str, str]]:
    """Validate the operator's answers for one operation's prompt kind."""
    if prompt == PROMPT_NONE:
        return []
    if prompt == PROMPT_PACKAGES:
        return [("update_packages", packages_expression(parse_packages(answers.get("packages", ""))))]
    if prompt == PROMPT_SERVICE:
        return [("service_name", parse_service(answers.get("service", "")))]
    if prompt == PROMPT_SCRIPT:
        return parse_script(answers.get("script", ""), answers.get("script_args", ""))
    if prompt == PROMPT_GRACE:
        return [("reboot_grace_seconds", parse_grace(answers.get("grace", "")))]
    if prompt == PROMPT_DISK_PCT:
        return parse_disk_pct(answers.get("disk_pct", ""))
    if prompt == PROMPT_LOG_LINES:
        return [("log_lines", parse_log_lines(answers.get("log_lines", "")))]
    if prompt == PROMPT_VERSION:
        return parse_expected_version(answers.get("expected_version", ""))
    raise Refused("Konsol hatası: bilinmeyen soru türü '{0}'.".format(prompt))


# ---------------------------------------------------------------------------
# Command construction
# ---------------------------------------------------------------------------
def build_ansible_command(
    repo: Repository,
    inventory_path: str,
    operation: Operation,
    scope: str,
    target: Optional[Target],
    wave: str = "",
    extra_vars: Sequence[Tuple[str, str]] = (),
    gates: Optional[GatesGranted] = None,
    check_mode: bool = False,
) -> List[str]:
    """Build the ansible-playbook argv for one operation and one target.

    Single choke point: no command is ever built without a target, and a gated
    scope is never built without a wave.
    """
    gates = gates or GatesGranted()
    if target is None:
        raise Refused(config.MSG_GATE_NO_TARGET)
    playbook = operation.playbook

    def uses(var: str) -> bool:
        return repo.playbook_uses(playbook, var)

    argv = [
        "ansible-playbook",
        "-i", inventory_path,
        repo.playbook_path(playbook),
        "--limit", target.limit,
    ]
    effective_wave = wave or target.wave

    if scope == config.SCOPE_WAVE:
        if not effective_wave:
            raise Refused(config.MSG_TARGET_DEVICE_NO_WAVE.format(host=target.limit))
        argv += ["-e", "{0}={1}".format(VAR_OPERATION_WAVE, effective_wave),
                 "-e", "{0}=true".format(VAR_OPERATION_CONFIRMED)]
        if effective_wave == config.PRODUCTION_WAVE and gates.production_override \
                and uses(VAR_PRODUCTION_OVERRIDE):
            argv += ["-e", "{0}=true".format(VAR_PRODUCTION_OVERRIDE)]
    elif scope == config.SCOPE_RELEASE:
        if not effective_wave or not is_wave(effective_wave):
            raise Refused(config.MSG_TARGET_RELEASE_DEVICE)
        argv += ["-e", "{0}={1}".format(VAR_RELEASE_WAVE, effective_wave)]
        if gates.wave_gate_confirmed and uses(VAR_WAVE_GATE_CONFIRMED):
            argv += ["-e", "{0}=true".format(VAR_WAVE_GATE_CONFIRMED)]
        if uses(VAR_REBOOT_CONFIRMED):
            argv += ["-e", "{0}=true".format(VAR_REBOOT_CONFIRMED)]
        if effective_wave == config.PRODUCTION_WAVE:
            if gates.production_override and uses(VAR_PRODUCTION_OVERRIDE):
                argv += ["-e", "{0}=true".format(VAR_PRODUCTION_OVERRIDE)]
            if gates.allow_production_reboot and uses(VAR_ALLOW_PRODUCTION_REBOOT):
                argv += ["-e", "{0}=true".format(VAR_ALLOW_PRODUCTION_REBOOT)]

    for name, value in extra_vars:
        argv += ["-e", "{0}={1}".format(name, value)]
    if check_mode:
        argv.append("--check")
    return argv


def build_install_command(
    installer: str,
    dealer: str,
    offline: bool = False,
    resume: bool = False,
    only: str = "",
    check_mode: bool = False,
) -> List[str]:
    """The local installer argv (bash <installer> --dealer-id ...)."""
    if not dealer_is_valid(dealer):
        raise Refused(config.MSG_TARGET_DEALER_INVALID.format(value=dealer))
    argv = ["bash", installer, "--dealer-id", dealer]
    if offline:
        argv.append("--offline")
    if resume:
        argv.append("--resume")
    if only:
        argv += ["--only", only]
    if check_mode:
        argv.append("--check")
    return argv


def build_tool_command(tool: str, args: Sequence[str] = (), check_mode: bool = False) -> List[str]:
    argv = [tool] + list(args)
    if check_mode:
        argv.append("--check")
    return argv


def module_names(repo: Repository) -> Tuple[str, ...]:
    """Installer modules (``NN-name.sh``) offered by the single-module action."""
    modules_dir = repo.path(os.path.join("scripts/install/installer/modules"))
    try:
        names = sorted(
            entry for entry in os.listdir(modules_dir)
            if re.match(r"^[0-9]{2}-.*\.sh$", entry)
        )
    except OSError:
        return ()
    return tuple(name[:-3] for name in names)


# ---------------------------------------------------------------------------
# Read-only information reports (returned as text lines for the UI)
# ---------------------------------------------------------------------------
def targets_lines(inventory: Inventory) -> List[str]:
    lines: List[str] = []
    lines.append("DALGALAR (yayılma sırası)")
    for wave in config.WAVES:
        if inventory.group_exists(wave):
            lines.append("   {0:<14} {1} cihaz".format(wave, len(inventory.hosts_of(wave))))
        else:
            lines.append("   {0:<14} envanterde yok".format(wave))
    others = [group for group in inventory.group_names() if not is_wave(group)]
    if others:
        lines.append("")
        lines.append("DİĞER GRUPLAR")
        for group in others:
            lines.append("   {0:<14} {1} cihaz".format(group, len(inventory.hosts_of(group))))
    lines.append("")
    lines.append("CİHAZLAR")
    for host in inventory.all_hosts():
        lines.append("   {0}".format(host))
    lines.append("")
    lines.append("Envanter: {0}".format(inventory.labels()))
    lines.append("Toplam cihaz: {0}".format(inventory.count_all()))
    return lines


def wave_gate_state_lines(inventory: Inventory) -> List[str]:
    lines = ["DALGA GEÇİŞ KAPISI DURUMU"]
    for wave in config.WAVES:
        if inventory.group_exists(wave):
            lines.append("   {0:<14} {1} cihaz".format(wave, len(inventory.hosts_of(wave))))
        else:
            lines.append("   {0:<14} envanterde yok".format(wave))
    lines.append("")
    lines.append("Kural: bir dalga, ancak önceki dalga sağlık kapısını ve merkez onayını geçtikten sonra başlar.")
    lines.append("Üretim (production) ayrıca yazılı 'production' onayı ve production_override=true gerektirir.")
    lines.append("Kaynak: docs/10 — güncelleme ve geri alma politikası.")
    return lines


def central_checklist_lines() -> List[str]:
    return [
        "MERKEZ HAZIRLIK LİSTESİ (bilgilendirme)",
        "   1. WireGuard hub: uç nokta, anahtarlar ve her bf-<bayi> için eş tahsisi (docs/08).",
        "   2. Kayıt (enrollment) jeton servisi: tek kullanımlık, TTL sınırlı (docs/29).",
        "   3. İzleme: Prometheus/VictoriaMetrics + Grafana, device_id etiketi BF-<no> (docs/14).",
        "   4. Uzak erişim: RustDesk hbbs/hbbr veya MeshCentral, WireGuard üzerinden (docs/07).",
        "   5. Paket deposu + çevrimdışı anlık görüntü (docs/10, docs/27).",
        "   6. Gerçek ana makine adlarıyla Ansible envanteri ve yönetici SSH anahtarı (docs/02, 06, 09).",
        "Bu konsol 6'yı doğrular, 1-5'i hazırlar; merkez bileşeni kurmaz.",
    ]


def _group_vars_value(path: Optional[str], key: str) -> str:
    if not path or not os.path.isfile(path):
        return ""
    pattern = re.compile(r"^[ \t]*{0}[ \t]*:(.*)$".format(re.escape(key)))
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                match = pattern.match(line.rstrip("\n"))
                if match:
                    value = match.group(1)
                    value = value.split("#", 1)[0].strip()
                    return value.strip("'\"")
    except OSError:
        return ""
    return ""


def central_endpoint_lines(repo: Repository) -> List[str]:
    path = repo.group_vars_path()
    lines = ["MERKEZ UÇ NOKTALARI (group_vars/all.yml)"]
    if path is None:
        lines.append("   group_vars/all.yml bulunamadı: {0}".format(repo.path(config.GROUP_VARS_REL)))
        return lines
    for key in config.CENTRAL_ENDPOINT_KEYS:
        value = _group_vars_value(path, key)
        if value:
            lines.append("   {0:<22} {1}".format(key, value))
    lines.append("")
    lines.append("Değerler group_vars/all.yml dosyasından okunur; burada hiçbir sır saklanmaz veya yazılmaz.")
    return lines


def central_readiness_lines(repo: Repository, inventory: Inventory, inventory_error: str = "") -> List[str]:
    lines = ["MERKEZ HAZIRLIK DURUMU"]
    if inventory.resolved:
        lines.append("   [OK] Envanter: {0} ({1} cihaz)".format(inventory.path, inventory.count_all()))
    else:
        lines.append("   [UYARI] Envanter çözümlenemedi.")
        if inventory_error:
            lines.extend("         " + part for part in inventory_error.splitlines())
    path = repo.group_vars_path()
    if path:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                placeholders = [line.strip() for line in handle if "PLACEHOLDER" in line]
        except OSError:
            placeholders = []
        if placeholders:
            lines.append("   [UYARI] group_vars/all.yml içinde {0} PLACEHOLDER değeri var:".format(len(placeholders)))
            lines.extend("         " + line for line in placeholders)
        else:
            lines.append("   [OK] group_vars/all.yml içinde PLACEHOLDER kalmamış.")
    else:
        lines.append("   [UYARI] ansible/inventory/group_vars/all.yml bulunamadı.")
    key_path = os.path.expanduser(config.ADMIN_KEY_FILE)
    if os.path.isfile(key_path):
        lines.append("   [OK] Yönetici SSH anahtarı var: {0} (içeriği okunmaz/yazılmaz)".format(config.ADMIN_KEY_FILE))
    else:
        lines.append("   [UYARI] Yönetici SSH anahtarı yok: {0} (docs/06)".format(config.ADMIN_KEY_FILE))
    if inventory.path and "example" in os.path.basename(inventory.path):
        lines.append("   [UYARI] Bu örnek bir envanter; gerçek cihazlara yöneltmeyin.")
    return lines


def split_endpoint(endpoint: str) -> Tuple[str, Optional[int]]:
    """Split a configured endpoint into (host, port) — no network access."""
    value = (endpoint or "").strip()
    if not value:
        return "", None
    if "//" in value:
        value = value.split("//", 1)[1]
    value = value.split("/", 1)[0]
    if value.startswith("["):  # IPv6 literal
        host, _, rest = value.partition("]")
        host = host.lstrip("[")
        port = int(rest[1:]) if rest.startswith(":") and rest[1:].isdigit() else None
        return host, port
    if ":" in value:
        host, _, port_text = value.rpartition(":")
        if port_text.isdigit():
            return host, int(port_text)
        return value, None
    if endpoint.startswith("http://"):
        return value, 80
    if endpoint.startswith("https://"):
        return value, 443
    return value, None


def probe_endpoint(host: str, port: Optional[int], timeout: float = 3.0) -> Tuple[str, bool]:
    """Resolve HOST and, when PORT is known, try one TCP connection."""
    if not host:
        return "", False
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except OSError:
        return "", False
    if not infos:
        return "", False
    resolved = str(infos[0][4][0])
    if port is None:
        return resolved, True
    try:
        with socket.create_connection((resolved, port), timeout=timeout):
            return resolved, True
    except OSError:
        return resolved, False


def central_probe_lines(repo: Repository, timeout: float = 3.0) -> List[str]:
    path = repo.group_vars_path()
    lines = ["MERKEZ UÇ NOKTASI DENEMESİ (salt okunur)"]
    if path is None:
        lines.append("   group_vars/all.yml bulunamadı.")
        return lines
    for key in ("wg_hub_endpoint", "monitoring_endpoint", "update_repo_url"):
        endpoint = _group_vars_value(path, key)
        if not endpoint:
            continue
        host, port = split_endpoint(endpoint)
        if not host:
            continue
        resolved, reachable = probe_endpoint(host, port, timeout=timeout)
        if not resolved:
            lines.append("   [UYARI] {0}: çözümlenemedi (yer tutucu olabilir)".format(host))
        elif port is None:
            lines.append("   [OK] {0} -> {1} (port türetilemedi)".format(host, resolved))
        elif reachable:
            lines.append("   [OK] {0}:{1} erişilebilir ({2})".format(host, port, resolved))
        else:
            lines.append("   [UYARI] {0}:{1} erişilemiyor ({2})".format(host, port, resolved))
    return lines


def state_values(path: str = config.STATE_FILE) -> Dict[str, str]:
    """Read state.json through a whitelist of non-secret keys.

    A future token field can never leak into the UI or the audit log.
    """
    values: Dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return values
    if not isinstance(data, dict):
        return values
    for key in config.STATE_ALLOWED_KEYS:
        value = data.get(key)
        if value is None or isinstance(value, bool):
            continue
        values[key] = str(value)
    return values


def identity_lines(hostname: str = "") -> List[str]:
    host = hostname or platform.node() or "bilinmiyor"
    dealer = host_to_dealer(host)
    lines = ["KİMLİK", "   Ana makine adı        : {0}".format(host)]
    if dealer:
        lines.append("   Bayi numarası         : {0}".format(dealer))
        lines.append("   Cihaz kimliği (insan) : {0}".format(dealer_to_device_id(dealer)))
    else:
        lines.append("   [UYARI] Ana makine adı bf-<8 hane> biçiminde değil (docs/02).")
    lines.append("   Çekirdek              : {0}".format(platform.platform()))
    values = state_values()
    for key in ("device_id", "phase"):
        if key in values:
            lines.append("   state.json {0:<10}: {1}".format(key, values[key]))
    return lines


def state_lines(path: str = config.STATE_FILE) -> List[str]:
    lines = ["KURULUM / KAYIT DURUMU"]
    values = state_values(path)
    if not values:
        lines.append("   [UYARI] {0} yok veya okunamadı: cihaz kurulmamış olabilir.".format(path))
        return lines
    for key in config.STATE_ALLOWED_KEYS:
        if key in values:
            lines.append("   {0:<18} {1}".format(key, values[key]))
    lines.append("")
    lines.append("Yalnız yukarıdaki kimlik/yaşam döngüsü alanları okunur; jeton ve anahtarlar asla yazılmaz.")
    lines.append("İleri yönlü durum makinesi: PROVISIONED_OFFLINE -> ENROLLED -> READY (docs/29).")
    return lines


def environment_lines(
    repo: Repository,
    log_file: str,
    inventory: Inventory,
    dry_run: bool,
    check_mode: bool,
) -> List[str]:
    lines = [
        "ORTAM",
        "   Konsol                : {0} {1}".format(config.PROGRAM_NAME, config.VERSION),
        "   Depo                  : {0}".format(repo.root),
        "   Envanter              : {0}".format(inventory.labels()),
        "   Denetim kaydı         : {0}".format(log_file),
        "   dry-run               : {0}".format("evet" if dry_run else "hayır"),
        "   check modu            : {0}".format("evet" if check_mode else "hayır"),
        "   Python                : {0}".format(platform.python_version()),
    ]
    for tool in (config.TOOL_ENROLL_STATUS, config.TOOL_LIVE_HW_CHECK):
        try:
            lines.append("   {0:<21}: {1}".format(tool, repo.tool_path(tool)))
        except Refused:
            lines.append("   {0:<21}: yok".format(tool))
    return lines


def file_mode(path: str) -> str:
    """Octal permission bits of PATH, or "?" when it cannot be read."""
    try:
        return oct(stat.S_IMODE(os.stat(path).st_mode))[2:].zfill(3)
    except OSError:
        return "?"
