"""Command line interface and operator flows for the bfos console.

Responsibilities:

  * argument parsing (``--full``, ``--dry-run``, ``--check``, ``--repo``,
    ``--inventory``, ``--log-file``, ``--version``, ``--lang``, ``--list``,
    ``--list-targets``, ``--no-color``),
  * repository discovery and the startup checks (inventory, Ansible, audit log),
  * the two presentations: the simple default view and ``--full`` detailed mode,
  * every operator flow: local install, fleet operations with their gates, the
    central preparation screens, the tools and the read-only information.

Everything that decides *what may run* lives in :mod:`bfos.operations`, and
everything that *runs* lives in :mod:`bfos.runner`; this module only wires the
two together and talks to the operator.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Dict, List, Optional, Sequence, Tuple

from . import config, operations, runner, tui
from .operations import (
    GateStep,
    GatesGranted,
    Inventory,
    Operation,
    Refused,
    Repository,
    Target,
)


class Quit(Exception):
    """The operator asked to leave the console."""


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=config.PROGRAM_NAME,
        description="{0} — {1}".format(config.PROGRAM_DESCRIPTION, config.VERSION),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        add_help=False,
        epilog=(
            "Örnekler:\n"
            "  sudo bfos                     basit mod: 1) Kur  2) Durum  3) Çıkış\n"
            "  sudo bfos --full              detaylı mod: 21 playbook, merkez hazırlığı, araçlar\n"
            "  bfos --dry-run --full         komutları yalnız göster, hiçbir şey çalıştırma\n"
            "  bfos --list                   işlem kataloğu (etkileşimsiz)\n"
            "  bfos --list-targets           envanterdeki dalgalar, gruplar ve cihazlar\n"
            "\n"
            "Güvenlik: her komut önce ekranda gösterilir ve onay ister; production dalgası\n"
            "ayrı onay (+ production_override=true), sürüm kapılı işlemler yazılı dalga onayı,\n"
            "yıkıcı işlemler ikinci onay ister. Denetim kaydı: {log} (mod 600).\n"
        ).format(log=config.DEFAULT_LOG_FILE),
    )
    parser.add_argument("-h", "--help", action="help", help="bu yardımı göster ve çık")
    parser.add_argument("-V", "--version", action="store_true", help="sürümü göster ve çık")
    parser.add_argument("--full", action="store_true",
                        help="detaylı mod: tüm kategoriler ve 21 playbook görünür")
    parser.add_argument("--dry-run", action="store_true",
                        help="komutları yaz, hiçbir şey çalıştırma")
    parser.add_argument("--check", action="store_true",
                        help="komutları --check ile üret (salt okunur; değişiklik uygulanmaz)")
    parser.add_argument("--repo", metavar="YOL", default="",
                        help="Blueforce deposu (varsayılan: konsolun bulunduğu depo)")
    parser.add_argument("--inventory", metavar="YOL", default="",
                        help="Ansible envanteri (varsayılan: <repo>/ansible/inventory/hosts.yml)")
    parser.add_argument("--log-file", metavar="YOL", default=config.DEFAULT_LOG_FILE,
                        help="denetim kaydı (varsayılan: {0}, mod 600)".format(config.DEFAULT_LOG_FILE))
    parser.add_argument("--lang", metavar="DİL", default=config.DEFAULT_LANG,
                        help="arayüz dili (yalnız: {0})".format(", ".join(config.SUPPORTED_LANGS)))
    parser.add_argument("--no-color", action="store_true", help="ANSI renklerini kapat (NO_COLOR da geçerli)")
    parser.add_argument("--list", action="store_true",
                        help="işlem kataloğunu yaz ve çık (etkileşimsiz)")
    parser.add_argument("--list-targets", action="store_true",
                        help="envanter hedeflerini yaz ve çık (etkileşimsiz)")
    return parser


def resolve_repo(explicit: str = "") -> Repository:
    """Locate the Blueforce checkout.

    An explicit ``--repo`` (or ``BF_REPO``) is a commitment, not a hint: when it
    does not look like the repository the console refuses to run instead of
    silently falling back to another checkout.
    """
    for candidate in (explicit, os.environ.get("BF_REPO", "")):
        if not candidate:
            continue
        repo = Repository(candidate)
        if repo.looks_valid():
            return repo
        raise Refused(config.MSG_REPO_INVALID.format(path=candidate))
    package_parent = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for candidate in (package_parent, os.getcwd()):
        repo = Repository(candidate)
        if repo.looks_valid():
            return repo
    raise Refused(config.MSG_REPO_INVALID.format(path=package_parent))


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
class App:
    """The operator flows. All I/O goes through :class:`bfos.tui.Console`."""

    def __init__(
        self,
        repo: Repository,
        console: tui.Console,
        runner_: runner.Runner,
        inventory: Inventory,
        full_mode: bool = False,
        check_mode: bool = False,
        inventory_error: str = "",
        inventory_arg: str = "",
    ) -> None:
        self.repo = repo
        self.console = console
        self.runner = runner_
        self.inventory = inventory
        self.full_mode = full_mode
        self.check_mode = check_mode
        self.inventory_error = inventory_error
        self.inventory_arg = inventory_arg

    # -- infrastructure ----------------------------------------------------
    def require_inventory(self) -> bool:
        """Fleet operations need a readable inventory: explain, never guess."""
        try:
            path = self.repo.find_inventory(self.inventory_arg)
        except Refused as exc:
            self.console.exception(exc)
            return False
        if path != self.inventory.path:
            self.inventory = Inventory.load(path)
        return True

    def require_ansible(self) -> bool:
        if self.runner.have_ansible():
            return True
        self.console.error(config.MSG_ANSIBLE_MISSING)
        return False

    def require_root(self) -> bool:
        if self.runner.is_root():
            return True
        self.console.error(config.MSG_ROOT_REQUIRED)
        return False

    def ask_menu(self, screen: tui.Screen) -> Optional[str]:
        """Render a screen until a valid key is chosen.

        Returns the chosen key, or ``None`` when the operator goes back.
        Raises :class:`Quit` when the operator quits.
        """
        while True:
            self.console.screen(screen)
            outcome, payload = self.console.ask_menu_choice(screen)
            if outcome == tui.CHOICE_QUIT:
                raise Quit()
            if outcome == tui.CHOICE_BACK:
                return None
            if outcome == tui.CHOICE_ITEM:
                return payload

    def pause(self) -> None:
        self.console.pause()

    # -- entry point -------------------------------------------------------
    def run(self) -> int:
        try:
            if self.full_mode:
                self.console.note(config.MSG_FULL_MODE_HINT)
                self.detailed_loop()
            else:
                self.simple_loop()
        except Quit:
            self.console.note(config.MSG_QUIT)
        return config.EXIT_OK

    # ------------------------------------------------------------------
    # Simple mode
    # ------------------------------------------------------------------
    def simple_loop(self) -> None:
        while True:
            key = self.ask_menu(tui.simple_menu())
            if key is None:
                self.console.note(config.MSG_AT_TOP)
                continue
            if key == "1":
                self.simple_install()
            elif key == "2":
                self.simple_status()
            elif key == "3":
                raise Quit()
            elif key == "d":
                self.full_mode = True
                self.console.note(config.MSG_FULL_MODE_HINT)
                self.detailed_loop()
            else:  # pragma: no cover - ask_menu only returns known keys
                self.console.warn(config.MSG_UNKNOWN_CHOICE.format(choice=key))

    def simple_install(self) -> None:
        """Guided local install: dealer number, then the installer."""
        self.console.section("Kurulum — bu cihaz")
        self.console.note("Bu cihaz Field OS standardına getirilir. Yalnız bu cihaz; filo cihazlarına dokunulmaz.")
        dealer = self.ask_dealer()
        if dealer is None:
            return
        try:
            installer = self.repo.installer_path()
        except Refused as exc:
            self.console.exception(exc)
            self.pause()
            return
        offline = self.console.confirm("Çevrimdışı kurulum (yerel paket deposu) kullanılsın mı?")
        if offline is None:
            raise Quit()
        if not self.require_root():
            self.pause()
            return
        argv = operations.build_install_command(
            installer, dealer, offline=offline, check_mode=self.check_mode
        )
        label = "kurulum: {0}".format(operations.dealer_to_device_id(dealer))
        self.console.info("Hedef cihaz: {0} ({1})".format(
            operations.dealer_to_device_id(dealer), operations.dealer_to_host(dealer)))
        self.runner.confirm_and_run(argv, label=label, destructive=True)
        self.pause()

    def simple_status(self) -> None:
        """Read-only status: identity, provisioning state, health tool."""
        self.console.section("Durum — bu cihaz")
        self.console.show_lines(operations.identity_lines())
        self.console.write("")
        self.console.show_lines(operations.state_lines())
        self.console.write("")
        result = self.run_tool("bf-status", title="bf-status (salt okunur)")
        if result is None:
            self.console.note("bf-status kurulu değil; yukarıdaki özet gösterildi.")
        self.console.note("Bu ekran hiçbir şeyi değiştirmez.")
        self.pause()

    def detailed_loop(self) -> None:
        while True:
            key = self.ask_menu(tui.detailed_menu())
            if key is None:
                self.console.note(config.MSG_AT_TOP)
                continue
            if key == "1":
                self.category_install()
            elif key == "2":
                self.category_devices()
            elif key == "3":
                self.category_central()
            elif key == "4":
                self.category_tools()
            elif key == "5":
                self.category_info()
            elif key == "s":
                self.full_mode = False
                self.console.note(config.MSG_SIMPLE_MODE_HINT)
                self.simple_loop()
                return

    # ------------------------------------------------------------------
    # Shared input helpers
    # ------------------------------------------------------------------
    def ask_dealer(self) -> Optional[str]:
        """Ask for a dealer number until it matches ^[0-9]{8}$ (or back/quit)."""
        while True:
            value = self.console.read(config.MSG_PROMPT_DEALER)
            if value is None:
                return None
            value = value.strip()
            if value == "" or value == "0":
                return None
            if operations.dealer_is_valid(value):
                return value
            self.console.warn(config.MSG_TARGET_DEALER_INVALID.format(value=value))

    def ask_extra_vars(self, operation: Operation) -> Optional[List[Tuple[str, str]]]:
        """Collect and validate the extra -e variables for one operation."""
        prompt = operation.prompt
        if prompt == operations.PROMPT_NONE:
            return []
        answers: Dict[str, str] = {}
        if prompt == operations.PROMPT_PACKAGES:
            self.console.note(config.MSG_PKG_HINT)
            value = self.console.read(config.MSG_PROMPT_PACKAGES)
            answers["packages"] = "" if value is None else value
        elif prompt == operations.PROMPT_SERVICE:
            self.console.note(config.MSG_SERVICE_HINT.format(allowlist=" ".join(config.SERVICE_ALLOWLIST)))
            value = self.console.read(config.MSG_PROMPT_SERVICE)
            answers["service"] = "" if value is None else value
        elif prompt == operations.PROMPT_SCRIPT:
            self.console.note("İzinli dizinler: {0}".format(" ".join(config.SCRIPT_DIRS)))
            path = self.console.read(config.MSG_PROMPT_SCRIPT)
            answers["script"] = "" if path is None else path
            args = self.console.read(config.MSG_PROMPT_SCRIPT_ARGS)
            answers["script_args"] = "" if args is None else args
        elif prompt == operations.PROMPT_GRACE:
            value = self.console.ask_with_default(
                config.MSG_PROMPT_GRACE.format(default=config.DEFAULT_REBOOT_GRACE),
                str(config.DEFAULT_REBOOT_GRACE),
            )
            answers["grace"] = "" if value is None else value
        elif prompt == operations.PROMPT_DISK_PCT:
            value = self.console.read(config.MSG_PROMPT_DISK)
            answers["disk_pct"] = "" if value is None else value
        elif prompt == operations.PROMPT_LOG_LINES:
            value = self.console.ask_with_default(
                config.MSG_PROMPT_LOG_LINES.format(default=config.DEFAULT_LOG_LINES),
                str(config.DEFAULT_LOG_LINES),
            )
            answers["log_lines"] = "" if value is None else value
        elif prompt == operations.PROMPT_VERSION:
            value = self.console.read(config.MSG_PROMPT_VERSION)
            answers["expected_version"] = "" if value is None else value
        try:
            return operations.build_extra_vars(prompt, answers)
        except Refused as exc:
            self.console.exception(exc)
            self.pause()
            return None

    # ------------------------------------------------------------------
    # Target selection
    # ------------------------------------------------------------------
    def select_target(self, mode: str) -> Optional[Target]:
        """Interactive target picker (mirrors bf_target_select)."""
        while True:
            screen = tui.target_menu()
            if mode == config.MODE_RELEASE:
                screen = tui.Screen(
                    title=screen.title,
                    subtitle="Sürüm kapılı işlemler dalga kapsamlıdır: tek cihaz seçilemez",
                    entries=screen.entries,
                    notes=("Yalnız onaylı dalga grupları kabul edilir; filo geneli reddedilir.",),
                )
            self.console.screen(screen)
            value = self.console.read(config.MSG_PROMPT_TARGET)
            if value is None:
                return None
            choice = value.strip()
            if choice == "" or choice == "0":
                return None
            if choice.lower() == "q":
                raise Quit()
            if choice == "1":
                dealer = self.ask_dealer()
                if dealer is None:
                    continue
                word = dealer
            elif choice == "2":
                word = self.pick_group(mode)
                if word is None:
                    continue
            elif choice == "3":
                word = "all"
            elif choice == "4":
                typed = self.console.read("Hedef (bayi no, grup ya da 'all'): ")
                if typed is None:
                    return None
                word = typed.strip()
            else:
                # Anything else is treated as a directly typed target, exactly
                # like the bash prompt's "type the target" option.
                word = choice
            try:
                return operations.resolve_target(word, mode, self.inventory)
            except Refused as exc:
                self.console.exception(exc)
                self.pause()

    def pick_group(self, mode: str) -> Optional[str]:
        if not self.inventory.resolved:
            self.console.warn(config.MSG_INVENTORY_MISSING.format(
                dir=self.repo.path(config.INVENTORY_DIR_REL)))
            return None
        groups = self.inventory.group_names() if mode == config.MODE_ANY else self.inventory.waves_present()
        if not groups:
            self.console.warn("Envanterde kullanılabilir grup yok.")
            return None
        self.console.section("Envanterdeki gruplar")
        for index, group in enumerate(groups, start=1):
            count = len(self.inventory.hosts_of(group))
            suffix = "onaylı dalga" if operations.is_wave(group) else "grup"
            self.console.write(tui.render_item(str(index), group, "{0} cihaz, {1}".format(count, suffix),
                                               self.console.palette))
        value = self.console.read("Grup numarası > ")
        if value is None:
            return None
        value = value.strip()
        if value.isdigit() and 1 <= int(value) <= len(groups):
            return groups[int(value) - 1]
        self.console.warn(config.MSG_MENU_RANGE.format(max=len(groups)))
        return None

    # ------------------------------------------------------------------
    # Fleet operations
    # ------------------------------------------------------------------
    def run_operation(self, operation: Operation) -> None:
        """Full flow for one operation: checks, target, gates, execution."""
        try:
            scope = self.repo.verify_scope(operation)
        except Refused as exc:
            self.console.exception(exc)
            self.pause()
            return
        if not self.require_ansible():
            self.pause()
            return
        if not self.require_inventory():
            self.pause()
            return

        self.console.section(operation.label)
        self.console.note(operation.description)
        if operation.declared_scope == config.SCOPE_RELEASE:
            self.console.note("Sürüm kapılı işlem: yalnız onaylı dalga, yazılı dalga onayı zorunlu.")
        target = self.select_target(operation.target_mode)
        if target is None:
            self.console.note(config.MSG_TARGET_NONE)
            return
        extra_vars = self.ask_extra_vars(operation)
        if extra_vars is None:
            return

        if scope == config.SCOPE_WAVE and target.kind == operations.KIND_ALL:
            self.run_fleet_waves(operation, scope, target, extra_vars)
            return
        wave = target.wave
        if scope in (config.SCOPE_WAVE, config.SCOPE_RELEASE) and not wave:
            self.console.error(config.MSG_TARGET_DEVICE_NO_WAVE.format(host=target.limit))
            self.pause()
            return
        self.gated_run(operation, scope, target, wave, extra_vars)
        self.pause()

    def run_fleet_waves(
        self,
        operation: Operation,
        scope: str,
        target: Target,
        extra_vars: Sequence[Tuple[str, str]],
    ) -> None:
        """Wave-scoped operation on the whole fleet: one wave at a time.

        The sequence stops at the first wave that is refused or fails, so no
        later wave is ever touched by accident.
        """
        sequence = operations.wave_sequence(self.inventory)
        if not sequence:
            self.console.error("Envanterde onaylı dalga yok; filo geneli işlem yapılamaz.")
            self.pause()
            return
        self.console.section("Filo geneli — dalga dalga")
        self.console.warn(config.MSG_GATE_WAVE_BY_WAVE.format(order=config.MSG_GATE_ORDER))
        if not self.console.confirm(config.MSG_GATE_START_FIRST):
            self.console.note(config.MSG_CANCELLED)
            return
        for wave, count in sequence:
            self.console.section("Dalga '{0}' — {1} cihaz".format(wave, count))
            answer = self.console.read(config.MSG_GATE_WAVE_LOOP_ASK.format(wave=wave, count=count))
            if answer is None:
                return
            if answer.strip() != wave:
                self.console.info(config.MSG_GATE_WAVE_SKIPPED.format(wave=wave))
                self.runner.audit.write(config.AUDIT_CANCEL, "dalga atlandı: {0}".format(wave))
                continue
            wave_target = Target(
                kind=operations.KIND_GROUP, limit=wave, wave=wave, count=count,
                label="dalga '{0}' ({1} cihaz)".format(wave, count),
            )
            result = self.gated_run(operation, scope, wave_target, wave, extra_vars,
                                    pause=False, wave_token_already_given=True)
            if result is None or not result.ok:
                self.console.error(config.MSG_GATE_WAVE_FAILED.format(
                    wave=wave, rc=(result.rc if result is not None else "-")))
                self.runner.audit.write(config.AUDIT_STOP, "{0} dalgasında durdu: {1}".format(
                    operation.ident, wave))
                self.pause()
                return
            self.pause()

    def gated_run(
        self,
        operation: Operation,
        scope: str,
        target: Target,
        wave: str,
        extra_vars: Sequence[Tuple[str, str]],
        pause: bool = True,
        wave_token_already_given: bool = False,
    ):
        """Apply the confirmation plan, build the command and run it."""
        try:
            wave_gate_supported = self.repo.playbook_uses(
                operation.playbook, operations.VAR_WAVE_GATE_CONFIRMED
            )
        except Refused as exc:
            self.console.exception(exc)
            return None

        plan = operations.confirmation_plan(
            operation, scope, target, wave=wave, wave_gate_supported=wave_gate_supported
        )
        if wave_token_already_given:
            # The fleet-wide loop already made the operator type this wave's
            # name: it is never asked twice for the same wave.
            plan = [step for step in plan if step.key != "wave_token"]
        gates = GatesGranted()
        if plan:
            self.console.section(config.MSG_GATE_PLAN_TITLE)
        for step in plan:
            granted = self.apply_gate_step(step)
            if granted is None:
                return None
            gates = gates.grant(step)

        self.console.section("İşlem özeti")
        self.console.kv("İşlem", operation.label)
        self.console.kv("Playbook", "{0}/{1}".format(config.PLAYBOOK_DIR_REL, operation.playbook))
        self.console.kv("Kapsam", scope)
        self.console.kv("Envanter", self.inventory.labels())
        self.console.kv("Hedef", target.label)
        if wave:
            self.console.kv("Dalga", wave)

        try:
            argv = operations.build_ansible_command(
                self.repo,
                self.inventory.path or "",
                operation,
                scope,
                target,
                wave=wave,
                extra_vars=list(extra_vars),
                gates=gates,
                check_mode=self.check_mode,
            )
        except Refused as exc:
            self.console.exception(exc)
            if pause:
                self.pause()
            return None

        self.runner.audit.write(
            config.AUDIT_TARGET,
            "{0} hedef={1} tür={2} dalga={3}".format(
                operation.ident, target.limit, target.kind, wave or "yok"),
        )
        result = self.runner.confirm_and_run(
            argv, label="{0} — {1}".format(operation.label, target.label),
            destructive=operation.destructive,
        )
        if pause:
            self.pause()
        return result

    def apply_gate_step(self, step: GateStep) -> Optional[bool]:
        """Ask one confirmation. Returns None when the operator does not grant it."""
        if step.kind == operations.STEP_TOKEN:
            granted = self.console.confirm_token(step.message, step.token, step.prompt)
            if granted is None:
                return None
            if not granted:
                self.console.warn(self._token_refusal(step))
                self.pause()
                return None
            return True
        granted = self.console.confirm(step.prompt)
        if granted is None:
            return None
        if not granted:
            self.console.warn(self._approval_refusal(step))
            self.pause()
            return None
        return True

    @staticmethod
    def _token_refusal(step: GateStep) -> str:
        if step.key == "production_token":
            return config.MSG_GATE_PRODUCTION_REFUSED
        if step.key == "fleet_token":
            return config.MSG_GATE_FLEET_REFUSED
        return config.MSG_GATE_WAVE_REFUSED

    @staticmethod
    def _approval_refusal(step: GateStep) -> str:
        if step.key == "production_approval":
            return config.MSG_GATE_PRODUCTION_REFUSED
        return config.MSG_CANCELLED_RUN

    # ------------------------------------------------------------------
    # Category: Kurulum (this device)
    # ------------------------------------------------------------------
    def category_install(self) -> None:
        while True:
            key = self.ask_menu(tui.install_menu(self.install_items()))
            if key is None:
                return
            if key == "1":
                self.install_preflight()
            elif key == "2":
                self.install_apply(resume=False)
            elif key == "3":
                self.install_apply(resume=True)
            elif key == "4":
                self.install_single_module()
            elif key == "5":
                self.show_file(config.INSTALL_STATE_FILE, "Kurulum modül durumu")
                self.pause()
            elif key == "6":
                self.tail_file(config.INSTALL_LOG_FILE, "Kurulum kaydı (son 40 satır)")
                self.pause()

    @staticmethod
    def install_items() -> Tuple[Tuple[str, str], ...]:
        return (
            ("Ön kontrol (--check)", "kurulum betiği --check; hiçbir şey yazmaz"),
            ("Bu cihazı kur", "tam kurulum; bayi numarası sorulur"),
            ("Başarısız kurulumu sürdür", "kurulum betiği --resume"),
            ("Tek modül çalıştır", "kurulum betiği --only"),
            ("Modül durumunu göster", config.INSTALL_STATE_FILE),
            ("Kurulum kaydını göster", "{0} son 40 satır".format(config.INSTALL_LOG_FILE)),
        )

    def install_preflight(self) -> None:
        installer = self.require_installer()
        if installer is None:
            return
        dealer = self.ask_dealer()
        if dealer is None:
            return
        self.console.note("Salt okunur ön kontrol: --check modunda kayıt, durum ve dizin oluşturulmaz.")
        argv = operations.build_install_command(installer, dealer, check_mode=True)
        self.runner.run_readonly(argv, title="Ön kontrol: {0}".format(
            operations.dealer_to_device_id(dealer)))
        self.pause()

    def install_apply(self, resume: bool) -> None:
        installer = self.require_installer()
        if installer is None:
            return
        dealer = self.ask_dealer()
        if dealer is None:
            return
        if not self.require_root():
            self.pause()
            return
        offline = False
        if not resume:
            answer = self.console.confirm("Çevrimdışı kurulum (yerel paket deposu) kullanılsın mı?")
            if answer is None:
                raise Quit()
            offline = answer
            resume_answer = self.console.confirm("Daha önce OK olan modüller atlanılsın mı (--resume)?")
            if resume_answer is None:
                raise Quit()
            resume = resume_answer
        argv = operations.build_install_command(
            installer, dealer, offline=offline, resume=resume, check_mode=self.check_mode
        )
        self.console.info("Hedef cihaz: {0} ({1})".format(
            operations.dealer_to_device_id(dealer), operations.dealer_to_host(dealer)))
        self.runner.confirm_and_run(
            argv, label="kurulum: {0}".format(operations.dealer_to_device_id(dealer)), destructive=True
        )
        self.pause()

    def install_single_module(self) -> None:
        installer = self.require_installer()
        if installer is None:
            return
        modules = operations.module_names(self.repo)
        if not modules:
            self.console.warn("Kurulum modülü bulunamadı: scripts/install/installer/modules/")
            self.pause()
            return
        self.console.section("Kurulum modülleri")
        for index, name in enumerate(modules, start=1):
            self.console.write(tui.render_item(str(index), name, "", self.console.palette))
        value = self.console.read("Modül numarası > ")
        if value is None:
            return
        value = value.strip()
        if not value.isdigit() or not (1 <= int(value) <= len(modules)):
            self.console.warn(config.MSG_MENU_RANGE.format(max=len(modules)))
            self.pause()
            return
        module = modules[int(value) - 1]
        dealer = self.ask_dealer()
        if dealer is None:
            return
        if not self.require_root():
            self.pause()
            return
        argv = operations.build_install_command(
            installer, dealer, only=module, check_mode=self.check_mode
        )
        self.runner.confirm_and_run(
            argv, label="tek modül ({0}): {1}".format(module, operations.dealer_to_device_id(dealer)),
            destructive=True,
        )
        self.pause()

    def require_installer(self) -> Optional[str]:
        try:
            return self.repo.installer_path()
        except Refused as exc:
            self.console.exception(exc)
            self.pause()
            return None

    # ------------------------------------------------------------------
    # Category: Cihaz işlemleri (fleet)
    # ------------------------------------------------------------------
    def category_devices(self) -> None:
        while True:
            key = self.ask_menu(tui.devices_menu(
                len(operations.REPORT_OPERATIONS), len(operations.MAINTENANCE_OPERATIONS)))
            if key is None:
                return
            if key == "1":
                self.operation_list(operations.REPORT_OPERATIONS,
                                    "Salt okunur filo raporları",
                                    "Bu listedeki hiçbir playbook cihazı değiştirmez")
            elif key == "2":
                self.operation_list(operations.MAINTENANCE_OPERATIONS,
                                    "Filo bakım işlemleri",
                                    "Yıkıcı işlemler iki kez onay ister")
            elif key == "3":
                if self.require_inventory():
                    self.console.show_lines(operations.targets_lines(self.inventory))
                self.pause()

    def operation_list(self, ops: Sequence[Operation], title: str, subtitle: str) -> None:
        screen = tui.Screen(
            title=title,
            subtitle=subtitle,
            entries=tuple(tui.item(op.label, op.description) for op in ops),
        )
        key = self.ask_menu(screen)
        if key is None:
            return
        index = int(key) - 1
        if 0 <= index < len(ops):
            self.run_operation(ops[index])

    # ------------------------------------------------------------------
    # Category: Merkez hazırlığı
    # ------------------------------------------------------------------
    def category_central(self) -> None:
        while True:
            key = self.ask_menu(tui.central_menu())
            if key is None:
                return
            if key == "1":
                self.console.show_lines(operations.central_readiness_lines(
                    self.repo, self.inventory, self.inventory_error))
            elif key == "2":
                self.console.show_lines(operations.central_endpoint_lines(self.repo))
            elif key == "3":
                self.console.show_lines(operations.central_probe_lines(self.repo))
            elif key == "4":
                self.console.show_lines(operations.wave_gate_state_lines(self.inventory))
            elif key == "5":
                self.console.show_lines(operations.central_checklist_lines())
            self.pause()

    # ------------------------------------------------------------------
    # Category: Araçlar
    # ------------------------------------------------------------------
    def category_tools(self) -> None:
        while True:
            key = self.ask_menu(tui.tools_menu())
            if key is None:
                return
            if key == "1":
                self.tool_git_pull()
            elif key == "2":
                self.console.show_lines(operations.environment_lines(
                    self.repo, self.runner.audit.path or self.runner.audit.requested,
                    self.inventory, self.runner.dry_run, self.runner.check_mode))
                self.console.kv("Denetim kaydı modu", operations.file_mode(
                    self.runner.audit.path or ""))
                self.pause()
            elif key == "3":
                self.console.show_lines(catalogue_lines())
                self.pause()
            elif key == "4":
                self.run_tool("bf-check-local", args=("--check",))
                self.pause()
            elif key == "5":
                self.run_tool("bf-check-enrollment", args=("--check",))
                self.pause()
            elif key == "6":
                self.run_tool("bf-check-ready", args=("--check",))
                self.pause()
            elif key == "7":
                if self.run_tool("bf-diagnostics") is None:
                    self.run_tool("bf-status")
                self.pause()
            elif key == "8":
                self.run_tool(config.TOOL_LIVE_HW_CHECK)
                self.pause()
            elif key == "9":
                self.run_tool("bf-remote-status", args=("--check",))
                self.pause()
            elif key == "10":
                self.run_tool("bf-release")
                self.pause()
            elif key == "11":
                self.tool_hardware_inventory()
            elif key == "12":
                self.tool_support_bundle()
            elif key == "13":
                self.tail_file(self.runner.audit.path or config.DEFAULT_LOG_FILE,
                               "Konsol denetim kaydı")
                self.pause()

    def run_tool(self, tool: str, args: Sequence[str] = (), title: str = ""):
        """Run a repository diagnostics tool (read-only screen)."""
        try:
            path = self.repo.tool_path(tool)
        except Refused as exc:
            self.console.exception(exc)
            return None
        argv = [path] + list(args)
        return self.runner.run_readonly(argv, title=title or tool)

    def tool_git_pull(self) -> None:
        self.runner.confirm_and_run(
            ["git", "-C", self.repo.root, "pull", "--ff-only"],
            label="depoyu güncelle ({0})".format(self.repo.root), destructive=True,
        )
        self.console.note("Depo değişmiş olabilir; konsolu yeniden başlatın.")
        self.pause()

    def tool_hardware_inventory(self) -> None:
        try:
            path = self.repo.tool_path("bf-hardware-inventory.sh")
        except Refused as exc:
            self.console.exception(exc)
            self.pause()
            return
        dealer = self.ask_dealer()
        if dealer is None:
            return
        out_dir = "/var/lib/blueforce/inventory" if self.runner.is_root() \
            else os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
                              "blueforce", "inventory")
        argv = [path, "--dealer-id", dealer, "--out-dir", out_dir]
        self.runner.run_readonly(argv, title="Donanım envanteri: {0}".format(
            operations.dealer_to_device_id(dealer)))
        self.pause()

    def tool_support_bundle(self) -> None:
        self.run_tool("bf-support-bundle", args=("--out-dir", config.SUPPORT_BUNDLE_OUT_DIR))
        self.pause()

    # ------------------------------------------------------------------
    # Category: Cihaz bilgisi (read-only)
    # ------------------------------------------------------------------
    def category_info(self) -> None:
        while True:
            key = self.ask_menu(tui.info_menu())
            if key is None:
                return
            if key == "1":
                self.console.show_lines(operations.identity_lines())
            elif key == "2":
                self.run_tool("bf-status")
            elif key == "3":
                self.console.show_lines(operations.state_lines())
            elif key == "4":
                self.info_network()
            elif key == "5":
                self.info_resources()
            elif key == "6":
                self.info_packages()
            elif key == "7":
                self.info_services()
            elif key == "8":
                self.info_journal()
            elif key == "9":
                if self.require_inventory():
                    self.console.show_lines(operations.targets_lines(self.inventory))
            elif key == "10":
                self.info_resolve_target()
                continue
            self.pause()

    def _run_readonly(self, argv: Sequence[str], title: str) -> None:
        self.runner.run_readonly(argv, title=title)

    def info_network(self) -> None:
        self._run_readonly(["ip", "-brief", "address"], "Ağ arayüzleri")
        self._run_readonly(["ip", "route", "show", "default"], "Varsayılan rotalar")
        if os.path.isfile("/etc/resolv.conf"):
            self._run_readonly(["awk", "/^nameserver/{print}", "/etc/resolv.conf"],
                               "DNS sunucuları (yalnız nameserver satırları)")
        self._run_readonly(["wg", "show", "wg0", "listen-port"], "WireGuard dinleme portu")
        self._run_readonly(["sh", "-c", "wg show wg0 peers | wc -l"], "WireGuard eş sayısı")
        self._run_readonly(["wg", "show", "wg0", "latest-handshakes"],
                           "WireGuard el sıkışma zamanları (anahtar yok)")
        self.console.note("WireGuard özel ve ön paylaşımlı anahtarları asla istenmez, gösterilmez ve kaydedilmez.")

    def info_resources(self) -> None:
        self._run_readonly(["df", "-h"], "Dosya sistemleri")
        self._run_readonly(["free", "-h"], "Bellek")
        self._run_readonly(["uptime"], "Yük ortalaması ve açık kalma süresi")

    def info_packages(self) -> None:
        self._run_readonly(
            ["dpkg-query", "-W", "-f=${Package} ${Version} ${Status}\n",
             "docker-ce", "wireguard", "rustdesk", "xrdp", "openssh-server"],
            "Kurulu sabit paketler",
        )

    def info_services(self) -> None:
        self._run_readonly(
            ["systemctl", "is-active", "ssh", "sshd", "xrdp", "rustdesk", "docker",
             "wg-quick@wg0", "meshagent", "cron"],
            "Servis durumu (salt okunur)",
        )

    def info_journal(self) -> None:
        self._run_readonly(["journalctl", "-p", "err", "-n", "20", "--no-pager"],
                           "Son journal hataları (20)")

    def info_resolve_target(self) -> None:
        self.console.section("Hedefi çözümle")
        self.console.note("Bayi numarası, grup adı, 'all' ya da bf-<bayi> ana makine adı kabul edilir.")
        value = self.console.read(config.MSG_PROMPT_TARGET)
        if value is None or not value.strip():
            return
        if not self.require_inventory():
            self.pause()
            return
        mode = config.MODE_ANY
        answer = self.console.confirm("Bu hedef dalga kapsamlı bir işlem için mi?")
        if answer:
            mode = config.MODE_WAVE
        try:
            target = operations.resolve_target(value, mode, self.inventory)
        except Refused as exc:
            self.console.exception(exc)
            self.pause()
            return
        self.console.kv("Tür", target.kind)
        self.console.kv("Ansible --limit", target.limit)
        self.console.kv("Dalga", target.wave or "yok")
        self.console.kv("Cihaz sayısı", str(target.count))
        self.console.note("Örnek: ansible-playbook -i {0} {1}/bf-ping.yml --limit {2}".format(
            self.inventory.labels(), config.PLAYBOOK_DIR_REL, target.limit))
        self.pause()

    # ------------------------------------------------------------------
    # Local helpers
    # ------------------------------------------------------------------
    def show_file(self, path: str, title: str) -> None:
        self.console.section(title)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except OSError:
            self.console.warn("{0} okunamadı veya yok.".format(path))
            return
        for line in lines:
            self.console.write("   " + line)

    def tail_file(self, path: str, title: str, lines: int = 40) -> None:
        if not os.path.isfile(path):
            self.console.warn("{0} yok.".format(path))
            return
        self.runner.run_readonly(["tail", "-n", str(lines), path], title=title)


# ---------------------------------------------------------------------------
# Non-interactive listings
# ---------------------------------------------------------------------------
def catalogue_lines() -> List[str]:
    lines: List[str] = []
    for title, ops in ((config.LIST_TITLE_REPORTS, operations.REPORT_OPERATIONS),
                       (config.LIST_TITLE_MAINTENANCE, operations.MAINTENANCE_OPERATIONS)):
        lines.append("")
        lines.append(title)
        for index, op in enumerate(ops, start=1):
            lines.append("   {0:>2}) {1:<34} {2:<36} kapsam={3:<8} yıkıcı={4}".format(
                index, op.ident, op.playbook, op.declared_scope, "evet" if op.destructive else "hayır"))
    lines.append("")
    lines.append(config.LIST_NOTE_WAVE)
    lines.append(config.LIST_NOTE_RELEASE)
    lines.append(config.LIST_NOTE_PLAYBOOK)
    return lines


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.version:
        sys.stdout.write("{0} {1}\n".format(config.PROGRAM_NAME, config.VERSION))
        return config.EXIT_OK

    if args.lang not in config.SUPPORTED_LANGS:
        sys.stderr.write(config.MSG_LANG_UNSUPPORTED.format(
            value=args.lang, supported=", ".join(config.SUPPORTED_LANGS)) + "\n")
        return config.EXIT_USAGE

    try:
        repo = resolve_repo(args.repo)
    except Refused as exc:
        sys.stderr.write(exc.message + "\n")
        if exc.detail:
            sys.stderr.write(exc.detail + "\n")
        return config.EXIT_USAGE

    palette = config.Palette(tui.color_enabled(
        no_color=args.no_color, mode="auto", is_tty=tui.stream_is_tty(sys.stdout)))
    console = tui.Console(palette=palette)

    audit = runner.AuditLog(requested=args.log_file)
    audit.initialise()
    if audit.warning:
        console.warn(audit.warning)

    inventory_error = ""
    try:
        inventory_path = repo.find_inventory(args.inventory)
        inventory = Inventory.load(inventory_path)
    except Refused as exc:
        inventory = Inventory(path=None, groups={})
        inventory_error = exc.message + ("\n" + exc.detail if exc.detail else "")
    except (OSError, ValueError) as exc:
        inventory = Inventory(path=None, groups={})
        inventory_error = config.MSG_INVENTORY_UNREADABLE.format(path=args.inventory) + "\n" + str(exc)

    # Non-interactive listings first: they need no terminal and no Ansible.
    if args.list:
        console.show_lines(catalogue_lines())
        return config.EXIT_OK
    if args.list_targets:
        console.show_lines(operations.targets_lines(inventory))
        return config.EXIT_OK

    console.note("{0} {1} — {2}".format(config.PROGRAM_NAME, config.VERSION, config.SCREEN_SUBTITLE))
    console.kv("Depo", repo.root)
    console.kv("Envanter", inventory.labels())
    console.kv("Denetim kaydı", audit.path or "yok")
    if args.dry_run:
        console.warn(config.MSG_DRY_RUN)
    if args.check:
        console.info(config.MSG_CHECK_MODE)
    if not audit.ready:
        console.warn(config.MSG_LOG_NONE)
    if not inventory.resolved:
        console.warn(inventory_error or config.MSG_INVENTORY_MISSING.format(
            dir=repo.path(config.INVENTORY_DIR_REL)))
        console.note("Filo kategorileri çalışmayacak; yerel kurulum ve bilgi ekranları kullanılabilir.")
    if not runner.Runner.have_ansible():
        console.warn(config.MSG_ANSIBLE_MISSING)

    audit.write(config.AUDIT_SESSION, (
        "{0} {1} başlangıç uid={2} repo={3} dry_run={4} check={5} full={6}"
    ).format(config.PROGRAM_NAME, config.VERSION, os.getuid(), repo.root,
             args.dry_run, args.check, args.full))

    app = App(
        repo=repo,
        console=console,
        runner_=runner.Runner(console, audit=audit, dry_run=args.dry_run, check_mode=args.check),
        inventory=inventory,
        full_mode=args.full,
        check_mode=args.check,
        inventory_error=inventory_error,
        inventory_arg=args.inventory,
    )
    try:
        code = app.run()
    except KeyboardInterrupt:
        console.write("")
        console.note("Kullanıcı tarafından kesildi (Ctrl+C).")
        return 130
    return code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
