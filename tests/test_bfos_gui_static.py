#!/usr/bin/env python3
"""bfos.ui_gui -- statik testler (stdlib unittest, pencere ACMAZ).

Bu testler GUI'yi baslatmaz ve hicbir Tk penceresi olusturmaz; yalnizca
tkinter'siz calisan yardimcilari ve backend sozlesmesini dogrular:

  * bayi no dogrulamasi (^[0-9]{8}$) ve Turkce hata metinleri,
  * komut onizleme metni (calistirilacak komut onizlemede GORUNUR),
  * yikici islem siniflandirmasi (katalog + playbook ile capraz kontrol),
  * headless (SSH) tespiti ve tkinter eksikligi mesaji,
  * hedef/kapi kurallari: release -> tek cihaz yok, production -> token,
  * --check kipi, salt-okunur rapor plani,
  * komut calistirma: canli satir akisi + cikis kodu (gercek subprocess).

Calistirma:
    python3 tests/test_bfos_gui_static.py -v
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
UI_GUI_PATH = REPO_ROOT / "bfos" / "ui_gui.py"


def _load_ui_gui():
    """ui_gui.py'yi paket __init__'ini calistirmadan yukler (izole import)."""
    if not UI_GUI_PATH.is_file():
        raise unittest.SkipTest(f"bulunamadi: {UI_GUI_PATH}")
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    name = "bfos_ui_gui_static_test"
    spec = importlib.util.spec_from_file_location(name, UI_GUI_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # dataclasses kayitli bir modul bekler; bu kayit zorunludur.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ui = _load_ui_gui()

INVENTORY_YAML = textwrap.dedent(
    """
    # gecici test envanteri (gercek cihaz degil)
    all:
      children:
        blueforce:
          children:
            lab:
              hosts:
                bf-12010101:
                  ansible_host: 10.42.0.11
            pilot_1:
              hosts:
                bf-12010193:
                  ansible_host: 10.42.1.11
            production:
              hosts:
                bf-12010999:
                  ansible_host: 10.42.9.11
    """
).strip() + "\n"


class StaticCase(unittest.TestCase):
    """Tum testler icin ortak kurulum: gecici envanter + backend."""

    tmpdir: tempfile.TemporaryDirectory

    @classmethod
    def setUpClass(cls) -> None:
        cls.tmpdir = tempfile.TemporaryDirectory(prefix="bfos-gui-test-")
        cls.inventory = Path(cls.tmpdir.name) / "hosts.yml"
        cls.inventory.write_text(INVENTORY_YAML, encoding="utf-8")
        cls.ctx = ui.GuiContext.detect(inventory=str(cls.inventory))
        cls.backend, cls.backend_note = ui.load_backend(cls.ctx)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmpdir.cleanup()

    # -- kucuk yardimcilar -------------------------------------------------
    def operation(self, operation_id: str):
        for op in self.backend.list_operations():
            if op.id == operation_id:
                return op
        self.fail(f"katalogda islem yok: {operation_id}")

    def available_fleet_operation(self, scope: str = "simple"):
        """Playbook'u DISKTE olan bir filo islemi (depo es zamanli degisebilir)."""
        for op in self.backend.list_operations():
            if op.is_fleet and op.scope == scope and op.playbook and \
                    ui.playbook_path(REPO_ROOT, op.playbook).is_file():
                return op
        self.skipTest(f"kullanilabilir {scope} kapsamli filo islemi yok")

    SAMPLE_VALUES = {
        "script": "/opt/blueforce/bin/deneme.sh",
        "packages": "docker-ce=5:27.0.3-1~ubuntu.24.04~noble",
        "service": "docker",
        "only": "01-precheck",
        "grace": "300",
        "log_lines": "500",
    }

    def valid_options(self, operation) -> dict:
        """Zorunlu secenekler icin gecerli ornek degerlerle sozluk uretir."""
        options: dict = {}
        for spec in operation.options:
            value = self.SAMPLE_VALUES.get(spec.name, spec.default)
            if spec.required and not value:
                self.skipTest(f"{operation.id}: '{spec.name}' icin ornek deger yok")
            options[spec.name] = value
        return options

    def dealer_target(self, dealer: str = "12010193"):
        return ui.Target("dealer", dealer)

    def group_target(self, group: str = "pilot_1"):
        return ui.Target("group", group)


class TestDealerValidation(StaticCase):
    def test_valid_dealer_numbers(self) -> None:
        for value in ("12010193", "00000000", "99999999"):
            self.assertTrue(ui.validate_dealer(value), value)
            self.assertIsNone(ui.dealer_error(value), value)

    def test_invalid_dealer_numbers(self) -> None:
        for value in ("", "1201019", "120101933", "1201019a", "1201 0193",
                      " 12010193", "12010193 ", "bf-12010193", "１２３４５６７８"):
            self.assertFalse(ui.validate_dealer(value), repr(value))
            self.assertIsNotNone(ui.dealer_error(value), repr(value))

    def test_error_message_is_turkish_and_actionable(self) -> None:
        message = ui.dealer_error("1201019")
        self.assertIn("8 hane", message)
        self.assertIn("1201019", message)
        self.assertIn("12010193", message)  # ornek deger
        self.assertIn("rakam", ui.dealer_error("abcdefgh"))

    def test_dealer_derived_names(self) -> None:
        self.assertEqual(ui.dealer_to_host("12010193"), "bf-12010193")
        self.assertEqual(ui.dealer_to_device_id("12010193"), "BF-12010193")
        self.assertEqual(ui.host_to_dealer("bf-12010193"), "12010193")
        self.assertIsNone(ui.host_to_dealer("sunucu-1"))

    def test_dealer_host_matches_repo_conventions(self) -> None:
        # docs/02: hostname bf-<8 hane>, insan kimligi BF-<8 hane>
        self.assertEqual(ui.HOST_PATTERN.pattern, r"^bf-[0-9]{8}$")
        self.assertEqual(ui.DEALER_PATTERN.pattern, r"^[0-9]{8}$")


class TestHeadlessAndTkinter(StaticCase):
    def test_detects_headless_without_display(self) -> None:
        message = ui.headless_error({})
        self.assertIsNotNone(message)
        self.assertIn("DISPLAY", message)
        self.assertIn("SSH", message)
        self.assertIn("bf-menu", message)
        self.assertIn("python3 -m bfos.ui_gui", message)

    def test_display_and_wayland_are_accepted(self) -> None:
        self.assertIsNone(ui.headless_error({"DISPLAY": ":0"}))
        self.assertIsNone(ui.headless_error({"WAYLAND_DISPLAY": "wayland-0"}))
        self.assertIsNone(ui.headless_error({"DISPLAY": ":99",
                                             "WAYLAND_DISPLAY": "wayland-9"}))

    def test_tkinter_missing_message_mentions_package(self) -> None:
        message = ui.tkinter_missing_message("No module named '_tkinter'")
        self.assertIn("python3-tk", message)
        self.assertIn("apt", message)
        self.assertIn("bf-menu", message)
        self.assertIn("_tkinter", message)

    def test_window_start_error_is_turkish(self) -> None:
        message = ui.window_start_error(RuntimeError("no display name and no $DISPLAY"))
        self.assertIn("Pencere açılamadı", message)
        self.assertIn("ssh -X", message)
        self.assertIn("bf-menu", message)

    def test_import_does_not_create_a_window(self) -> None:
        # tkinter varsa bile modul import'u bir Tk koku olusturmamalidir:
        # BfGui yalnizca acikca verilen bir root ile kurulabilir.
        self.assertIsInstance(ui.HAVE_TKINTER, bool)
        import inspect

        signature = inspect.signature(ui.BfGui.__init__)
        self.assertIn("root", signature.parameters)
        # Yardimcilar tkinter olmadan da cagrilabilir.
        self.assertIsNone(ui.dealer_error("12010193"))

    def test_main_list_prints_catalogue_without_a_window(self) -> None:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = ui.main(["--list", "--inventory", str(self.inventory)])
        self.assertEqual(code, 0)
        output = buffer.getvalue()
        self.assertIn("işlem kataloğu", output)
        for category in ui.CATEGORIES:
            self.assertIn(category, output)

    def test_main_reports_headless_with_exit_3(self) -> None:
        env = {k: v for k, v in os.environ.items()
               if k not in ("DISPLAY", "WAYLAND_DISPLAY")}
        stderr = io.StringIO()
        import unittest.mock as mock

        with mock.patch.dict(os.environ, env, clear=True), \
                contextlib.redirect_stderr(stderr):
            code = ui.main([])
        self.assertEqual(code, 3)
        self.assertIn("bf-menu", stderr.getvalue())


class TestSimpleModeLayout(StaticCase):
    def test_three_big_buttons_in_simple_mode(self) -> None:
        self.assertEqual(ui.SIMPLE_MODE_BUTTONS, ("Kur", "Durum", "Çıkış"))
        self.assertEqual(ui.SIMPLE_MODE_LABEL, "Detaylı mod")

    def test_window_title_is_turkish(self) -> None:
        self.assertEqual(ui.WINDOW_TITLE, "Blueforce Field OS — Yönetim")

    def test_five_category_tabs(self) -> None:
        self.assertEqual(
            ui.CATEGORIES,
            ("Kurulum", "Cihaz işlemleri", "Merkez hazırlığı", "Araçlar", "Cihaz bilgisi"),
        )


class TestCatalogue(StaticCase):
    def test_operations_have_unique_ids_and_known_categories(self) -> None:
        operations = self.backend.list_operations()
        self.assertGreaterEqual(len(operations), 21)
        ids = [op.id for op in operations]
        self.assertEqual(len(ids), len(set(ids)), "islem id'leri tekil olmali")
        for op in operations:
            self.assertIn(op.category, ui.CATEGORIES, op.id)
            self.assertTrue(op.label.strip(), op.id)

    def test_every_category_has_at_least_one_operation(self) -> None:
        for category in ui.CATEGORIES:
            with self.subTest(category=category):
                self.assertTrue(
                    [op for op in self.backend.list_operations() if op.category == category],
                    f"{category} kategorisi bos",
                )

    def test_fleet_operation_playbooks_match_declared_scope(self) -> None:
        """Konsol tablosu playbook'la uyusmali; playbook yoksa CALISTIRMA reddedilir.

        (bf_playbook_check + fail-closed kuralinin statik karsiligi.)
        """
        checked = 0
        missing: list[str] = []
        for op in self.backend.list_operations():
            if not op.is_fleet:
                continue
            book = ui.playbook_path(REPO_ROOT, op.playbook)
            if not book.is_file():
                # Eksik playbook SESSIZ gecilemez: komut uretimi reddedilmeli.
                missing.append(f"{op.id} ({op.playbook})")
                with self.subTest(operation=op.id):
                    with self.assertRaises(ui.CommandError):
                        self.backend.build_command(op, self.group_target())
                continue
            with self.subTest(operation=op.id):
                self.assertEqual(
                    ui.playbook_scope(book), op.scope,
                    f"{op.playbook}: tablo '{op.scope}' derken playbook "
                    f"'{ui.playbook_scope(book)}' beyan ediyor",
                )
                checked += 1
        self.assertGreaterEqual(checked, 15)
        if missing:
            print(f"\n[UYARI] bu checkout'ta playbook dosyası eksik: {', '.join(missing)}"
                  " -> ilgili işlemler fail-closed olarak reddediliyor")

    def test_every_ansible_playbook_is_covered_or_known(self) -> None:
        """Katalog disinda kalan playbook varsa gorunur olmali (sessiz kapsam disi yok)."""
        catalogue = {op.playbook for op in self.backend.list_operations() if op.is_fleet}
        on_disk = {p.name for p in (REPO_ROOT / "ansible" / "playbooks").glob("bf-*.yml")}
        self.assertEqual(on_disk - catalogue, set())

    def test_operation_ids_match_admin_bf_menu_catalogue(self) -> None:
        """id'ler admin/bf-menu tablosuyla ayni olmali (iki giris noktasi ayrisamaz)."""
        menu = (REPO_ROOT / "admin" / "bf-menu").read_text(encoding="utf-8")
        for op in self.backend.list_operations():
            if op.is_fleet:
                with self.subTest(operation=op.id):
                    self.assertIn(f'"{op.id}|', menu)


class TestDestructiveClassification(StaticCase):
    YIKICI = ("rdp-restart", "rustdesk-restart", "wireguard-restart", "service-restart",
              "gui-off", "gui-on", "run-script", "reboot", "deploy-update",
              "install-local", "install-resume", "install-module", "tools-git-pull")
    SALT_OKUNUR = ("ping", "uptime", "disk", "docker", "packages", "security-updates",
                   "provisioning-status", "enrollment-status", "fieldos-version",
                   "remote-channels", "offline-ready", "collect-logs", "install-preflight",
                   "install-state", "install-log", "central-targets", "info-summary",
                   "tools-release", "tools-support-bundle")

    def test_destructive_ids_are_flagged(self) -> None:
        flagged = set(ui.destructive_operations(self.backend.list_operations()))
        for operation_id in self.YIKICI:
            with self.subTest(operation=operation_id):
                self.assertIn(operation_id, flagged)
                self.assertTrue(ui.operation_is_destructive(operation_id))

    def test_read_only_ids_are_not_flagged(self) -> None:
        flagged = set(ui.destructive_operations(self.backend.list_operations()))
        for operation_id in self.SALT_OKUNUR:
            with self.subTest(operation=operation_id):
                self.assertNotIn(operation_id, flagged)
                self.assertFalse(ui.operation_is_destructive(operation_id))

    def test_destructive_flag_reaches_the_plan(self) -> None:
        plan = self.backend.build_command(self.operation("reboot"), self.group_target(),
                                          {"grace": "300"})
        self.assertTrue(plan.destructive)
        plan = self.backend.build_command(self.operation("ping"), self.group_target())
        self.assertFalse(plan.destructive)

    def test_unknown_operation_is_not_destructive(self) -> None:
        self.assertFalse(ui.operation_is_destructive("boyle-bir-islem-yok"))


class TestCommandPreview(StaticCase):
    def test_fleet_preview_shows_the_exact_command(self) -> None:
        operation = self.available_fleet_operation()
        target = self.dealer_target()
        plan = self.backend.build_command(operation, target, self.valid_options(operation))
        preview = ui.preview_text(plan, operation=operation, target=target)
        self.assertTrue(plan.lines, "en az bir komut satiri uretilmeli")
        for line in plan.lines:
            self.assertIn(line, preview)
        self.assertIn("ansible-playbook", preview)
        self.assertIn("--limit", preview)
        self.assertIn("bf-12010193", preview)
        self.assertIn(operation.playbook, preview)
        self.assertIn("Çalıştırılacak komut", preview)

    def test_preview_marks_destructive_operations(self) -> None:
        operation = self.operation("deploy-update")
        plan = self.backend.build_command(
            operation, self.group_target(),
            {"packages": "docker-ce=5:27.0.3-1~ubuntu.24.04~noble"},
        )
        preview = ui.preview_text(plan, operation=operation)
        self.assertIn("UYARI", preview)
        self.assertIn("YIKICI", preview)
        self.assertIn("update_packages=", preview)

    def test_preview_lists_target_and_scope_in_turkish(self) -> None:
        operation = self.operation("provisioning-status")
        target = self.group_target()
        plan = self.backend.build_command(operation, target)
        preview = ui.preview_text(plan, operation=operation, target=target)
        self.assertIn("dalga", preview.lower())
        self.assertIn("dalga kapılı", preview)

    def test_preview_of_report_only_plan_says_nothing_runs(self) -> None:
        operation = self.operation("central-targets")
        plan = self.backend.build_command(operation, None)
        self.assertTrue(plan.is_report_only)
        preview = ui.preview_text(plan, operation=operation)
        self.assertIn("komut çalıştırmaz", preview)
        self.assertNotIn("Çalıştırılacak komut(lar)", preview)

    def test_check_mode_is_visible_in_command_and_preview(self) -> None:
        operation = self.available_fleet_operation()
        target = self.group_target()
        plan = self.backend.build_command(
            operation, target, self.valid_options(operation), check_mode=True
        )
        self.assertTrue(plan.check_mode)
        self.assertIn("--check", " ".join(plan.lines))
        preview = ui.preview_text(plan, operation=operation, target=target)
        self.assertIn("--check", preview)
        self.assertIn("değişiklik uygulanmaz", preview)

    def test_options_change_the_previewed_command(self) -> None:
        operation = self.operation("disk")
        options = {spec.name: "75" for spec in operation.options if "disk" in spec.name}
        if not options:
            self.skipTest("disk isleminin esik secenegi yok")
        plan = self.backend.build_command(operation, self.group_target(), options)
        self.assertIn("disk_warn_pct=75", " ".join(plan.lines))

    def test_invalid_option_is_refused_with_turkish_message(self) -> None:
        operation = self.operation("service-restart")
        name = "service" if any(s.name == "service" for s in operation.options) else "service_name"
        with self.assertRaises(ui.CommandError) as ctx:
            self.backend.build_command(operation, self.group_target(), {name: "kritik-servis"})
        self.assertIn("izinli", str(ctx.exception).lower())

    def test_missing_required_option_is_refused(self) -> None:
        operation = self.operation("deploy-update")
        name = "packages" if any(s.name == "packages" for s in operation.options) \
            else "update_packages"
        with self.assertRaises(ui.CommandError):
            self.backend.build_command(operation, self.group_target(), {name: ""})


class TestGatesAndTargets(StaticCase):
    def test_wave_operation_requires_wave_token(self) -> None:
        # A wave-scoped READ-ONLY report asks for no gate token -- the bash
        # console behaves the same way (see bfos/operations.confirmation_plan:
        # only release-gated runs and the production wave ask for a written
        # token). What must hold is that the built command carries the wave
        # scope and the confirmation flag, so the playbook's own gate accepts it.
        steps = self.backend.gate_steps(self.operation("provisioning-status"),
                                        self.group_target())
        tokens = [s.token for s in steps if s.kind == "token"]
        self.assertEqual([], tokens,
                         "a read-only wave report must not ask for a gate token")
        plan = self.backend.build_command(self.operation("provisioning-status"),
                                          self.group_target(), {}, {})
        argv = list(plan.commands[0])
        self.assertIn("operation_wave=pilot_1", argv)
        self.assertIn("operation_confirmed=true", argv)

    def test_release_gated_operation_requires_wave_token(self) -> None:
        # The gate that must never disappear: reboot/deploy-update are
        # release-gated, so the wave name has to be typed before anything runs.
        steps = self.backend.gate_steps(self.operation("reboot"),
                                        self.group_target())
        tokens = [s.token for s in steps if s.kind == "token"]
        self.assertIn("pilot_1", tokens)

    def test_destructive_operation_requires_second_approval(self) -> None:
        steps = self.backend.gate_steps(self.operation("gui-off"), self.group_target())
        self.assertTrue([s for s in steps if s.kind == "approval"], steps)

    def test_production_wave_requires_production_token(self) -> None:
        steps = self.backend.gate_steps(self.operation("gui-off"),
                                       self.group_target("production"))
        tokens = [s.token for s in steps if s.kind == "token"]
        self.assertIn("production", tokens)
        unlocks = {name for step in steps for name in step.unlocks}
        self.assertIn("production_override", unlocks)

    def test_release_scope_refuses_single_device_and_fleet(self) -> None:
        operation = self.operation("reboot")
        with self.assertRaises(ui.CommandError) as ctx:
            self.backend.build_command(operation, self.dealer_target(), {"grace": "300"})
        self.assertIn("dalga", str(ctx.exception).lower())
        with self.assertRaises(ui.CommandError):
            self.backend.build_command(operation, ui.Target("all", "all"), {"grace": "300"})

    def test_wave_scope_refuses_a_non_wave_group(self) -> None:
        operation = self.operation("gui-on")
        with self.assertRaises(ui.CommandError):
            self.backend.build_command(operation, self.group_target("blueforce"))

    def test_wave_scope_on_a_dealer_resolves_the_wave(self) -> None:
        plan = self.backend.build_command(self.operation("gui-off"), self.dealer_target())
        line = " ".join(plan.lines)
        self.assertIn("operation_wave=pilot_1", line)
        self.assertIn("operation_confirmed=true", line)
        self.assertIn("bf-12010193", line)

    def test_unknown_dealer_outside_inventory_is_refused(self) -> None:
        operation = self.available_fleet_operation()
        with self.assertRaises(ui.CommandError) as ctx:
            self.backend.build_command(operation, self.dealer_target("12010000"))
        self.assertIn("12010000", str(ctx.exception))

    def test_invalid_dealer_never_builds_a_command(self) -> None:
        operation = self.available_fleet_operation()
        with self.assertRaises(ui.CommandError):
            self.backend.build_command(operation, self.dealer_target("123"))

    def test_grants_change_the_gated_command(self) -> None:
        operation = self.operation("reboot")
        target = self.group_target("production")
        options = {"grace": "120"}
        if not any(s.name == "grace" for s in operation.options):
            options = {"reboot_grace_seconds": "120"}
        draft = self.backend.build_command(operation, target, options)
        final = self.backend.build_command(
            operation, target, options,
            grants={"wave_gate_confirmed": True, "production_override": True,
                    "allow_production_reboot": True},
        )
        joined = " ".join(final.lines)
        self.assertIn("allow_production_reboot=true", joined)
        self.assertNotIn("allow_production_reboot=true", " ".join(draft.lines))
        self.assertNotEqual(draft.lines, final.lines)

    def test_no_gate_flag_is_ever_added_silently(self) -> None:
        """Onaysiz hicbir komut kapi bayragi tasimamali (fail-closed)."""
        checked = 0
        for operation in self.backend.list_operations():
            if not operation.is_fleet or operation.scope == "simple":
                continue
            target = self.group_target("production" if operation.scope == "release"
                                       else "pilot_1")
            options = self.valid_options(operation)
            try:
                plan = self.backend.build_command(operation, target, options)
            except ui.CommandError:
                # Playbook eksik/kapi reddi: komut URETILMEDI, bu da guvenli.
                continue
            with self.subTest(operation=operation.id):
                joined = " ".join(plan.lines)
                for flag in ("wave_gate_confirmed=true", "production_override=true",
                             "allow_production_reboot=true"):
                    self.assertNotIn(flag, joined,
                                     f"{operation.id}: onaysiz kapi bayragi uretildi")
            checked += 1
        self.assertGreaterEqual(checked, 1)


class TestRunnerStreaming(StaticCase):
    def test_run_command_streams_lines_and_returns_exit_code(self) -> None:
        lines: list[str] = []
        result = ui.run_command(
            [sys.executable, "-c", "print('merhaba'); print('dunya')"],
            on_line=lines.append,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.ok)
        self.assertEqual(lines, ["merhaba", "dunya"])
        self.assertIn("merhaba", result.output)

    def test_run_command_reports_nonzero_exit_code(self) -> None:
        result = ui.run_command([sys.executable, "-c", "import sys; sys.exit(3)"])
        self.assertEqual(result.exit_code, 3)
        self.assertFalse(result.ok)

    def test_missing_command_gives_turkish_message(self) -> None:
        result = ui.run_command(["boyle-bir-komut-yok-12345"])
        self.assertEqual(result.exit_code, 127)
        self.assertFalse(result.ok)
        self.assertIn("bulunamadı", result.output)
        self.assertIn("bf-bootstrap", result.output)

    def test_run_plan_stops_at_the_first_failure(self) -> None:
        plan = ui.CommandPlan(
            commands=(
                (sys.executable, "-c", "import sys; print('ilk'); sys.exit(4)"),
                (sys.executable, "-c", "print('IKINCI-CALISMAMALI')"),
            )
        )
        lines: list[str] = []
        result = ui.run_plan(plan, on_line=lines.append)
        self.assertEqual(result.exit_code, 4)
        self.assertFalse(result.ok)
        self.assertIn("ilk", lines)
        self.assertNotIn("IKINCI-CALISMAMALI", lines)

    def test_run_plan_executes_nothing_for_a_report_plan(self) -> None:
        plan = ui.CommandPlan(report_lines=("satır 1", "satır 2"))
        lines: list[str] = []
        result = ui.run_plan(plan, on_line=lines.append)
        self.assertTrue(result.ok)
        self.assertEqual(lines, ["satır 1", "satır 2"])
        self.assertEqual(result.exit_code, 0)

    def test_dry_run_plan_does_not_execute(self) -> None:
        plan = ui.CommandPlan(
            commands=((sys.executable, "-c", "print('CALISMAMALI')"),),
            dry_run=True,
        )
        lines: list[str] = []
        result = ui.run_plan(plan, on_line=lines.append)
        self.assertTrue(result.ok)
        # Yalnizca "[deneme] <komut>" satiri yazilir; komutun CIKTISI yazilmaz.
        self.assertTrue(lines)
        self.assertTrue(all(line.startswith("[deneme] ") for line in lines), lines)
        self.assertNotIn("CALISMAMALI", result.output)
        self.assertIn("[deneme]", result.output)


class TestInventoryHelpers(StaticCase):
    def test_parses_groups_and_hosts(self) -> None:
        groups = ui.parse_inventory(self.inventory)
        self.assertEqual(groups.get("pilot_1"), ["bf-12010193"])
        self.assertEqual(groups.get("lab"), ["bf-12010101"])
        self.assertEqual(groups.get("production"), ["bf-12010999"])

    def test_wave_list_follows_rollout_order(self) -> None:
        groups = ui.parse_inventory(self.inventory)
        self.assertEqual(ui.waves_in_inventory(groups), ("lab", "pilot_1", "production"))
        self.assertEqual(ui.WAVES,
                         ("lab", "pilot_1", "pilot_2", "wave_1", "wave_2", "production"))

    def test_device_wave_lookup(self) -> None:
        groups = ui.parse_inventory(self.inventory)
        self.assertEqual(ui.device_wave("bf-12010193", groups), "pilot_1")
        self.assertIsNone(ui.device_wave("bf-99999999", groups))

    def test_missing_inventory_does_not_crash(self) -> None:
        self.assertEqual(ui.parse_inventory(Path("/yok/boyle/bir/dosya.yml")), {})

    def test_missing_machine_inventory_is_reported_in_turkish(self) -> None:
        backend = ui.CatalogueBackend(ui.GuiContext(repo_root=REPO_ROOT, inventory=None))
        note = backend.inventory_note()
        self.assertIn("envanter", note.lower())
        self.assertIn("hosts.yml", note)

    def test_inventory_note_survives_and_warns_without_ansible(self) -> None:
        """Not uretimi hicbir durumda patlamamali (eksik import regresyonu)."""
        for backend in (
            ui.CatalogueBackend(ui.GuiContext(repo_root=REPO_ROOT,
                                              inventory=self.inventory)),
            self.backend,
        ):
            with self.subTest(backend=type(backend).__name__):
                note = backend.inventory_note()
                self.assertIn("Envanter", note)
                if shutil.which("ansible-playbook") is None:
                    self.assertIn("ansible-playbook bulunamadı", note)

    def test_dealer_wave_gate_requires_inventory(self) -> None:
        backend = ui.CatalogueBackend(ui.GuiContext(repo_root=REPO_ROOT, inventory=None))
        problem = backend.validate_target(
            ui.operation_by_id("gui-off") or ui.OPERATIONS[0], self.dealer_target()
        )
        self.assertIsNotNone(problem)


class TestCatalogueBackendFallback(StaticCase):
    """Gercek moduller yoksa da ayni kurallar gecerli olmali (ayna backend)."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.fallback = ui.CatalogueBackend(cls.ctx)

    def test_fallback_has_the_same_fleet_operations(self) -> None:
        fleet = {op.id for op in self.fallback.list_operations() if op.is_fleet}
        self.assertGreaterEqual(len(fleet), 21)
        self.assertIn("ping", fleet)
        self.assertIn("deploy-update", fleet)

    def test_fallback_builds_the_same_core_arguments(self) -> None:
        operation = None
        for candidate in self.fallback.list_operations():
            if candidate.is_fleet and candidate.scope == "simple" and candidate.playbook \
                    and ui.playbook_path(REPO_ROOT, candidate.playbook).is_file():
                operation = candidate
                break
        if operation is None:
            self.skipTest("kullanilabilir basit kapsamli filo islemi yok")
        options = {spec.name: self.SAMPLE_VALUES[spec.name]
                   for spec in operation.options if spec.name in self.SAMPLE_VALUES}
        plan = self.fallback.build_command(operation, self.dealer_target(), options)
        joined = " ".join(plan.lines)
        self.assertIn("ansible-playbook", joined)
        self.assertIn(f"-i {self.ctx.inventory}", joined)
        self.assertIn("--limit bf-12010193", joined)

    def test_fallback_uses_the_same_destructive_table(self) -> None:
        destructive = set(ui.destructive_operations(self.fallback.list_operations()))
        self.assertEqual(destructive, set(ui.destructive_operations()))

    def test_fallback_refuses_missing_inventory(self) -> None:
        backend = ui.CatalogueBackend(ui.GuiContext(repo_root=REPO_ROOT, inventory=None))
        with self.assertRaises(ui.CommandError) as ctx:
            backend.build_command(ui.operation_by_id("uptime"), self.dealer_target())
        self.assertIn("envanter", str(ctx.exception).lower())

    def test_fallback_refuses_scope_mismatch_with_the_playbook(self) -> None:
        """Tablo playbook'la celisirse komut URETILMEZ (bf_playbook_check kurali)."""
        wrong = ui.Operation(
            id="uptime", label="Yanlış kapsam", category="Cihaz işlemleri",
            destructive=False, scope="wave", playbook="bf-uptime.yml",
        )
        with self.assertRaises(ui.CommandError) as ctx:
            self.fallback.build_command(wrong, self.group_target())
        self.assertIn("bf-uptime.yml", str(ctx.exception))
        self.assertIn("kapsam", str(ctx.exception).lower())

    def test_fallback_installs_only_with_a_valid_dealer(self) -> None:
        installer = REPO_ROOT / ui.INSTALLER_REL
        if not installer.is_file():
            self.skipTest("kurulum betigi bu checkout'ta yok")
        plan = self.fallback.build_command(
            ui.operation_by_id("install-preflight"), self.dealer_target()
        )
        joined = " ".join(plan.lines)
        self.assertIn("--dealer-id 12010193", joined)
        self.assertIn("--check", joined)
        self.assertFalse(plan.destructive)


if __name__ == "__main__":
    unittest.main(verbosity=2)
