#!/usr/bin/env python3
"""Unit tests for the bfos operator console (standard library only).

Run:

    python3 -m unittest tests.test_bfos -v
    python3 -m unittest discover -s tests

Everything here is hermetic: no device, no Ansible, no terminal, no root and no
network. Playbooks are read from the real checkout (they are the source of
truth for their own gates) and every command is captured by a fake spawner, so
nothing is ever executed.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from bfos import cli, config, operations, runner, tui  # noqa: E402
from bfos.operations import (  # noqa: E402
    GatesGranted,
    Inventory,
    Refused,
    Repository,
    STEP_APPROVAL,
    STEP_TOKEN,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
class FakeSpawn:
    """Captures argv instead of running anything."""

    def __init__(self, codes=None):
        self.calls = []
        self.codes = list(codes or [])

    def __call__(self, argv):
        self.calls.append(list(argv))
        if self.codes:
            return self.codes.pop(0)
        return 0


class ScriptedConsole(tui.Console):
    """A Console fed from a list; an exhausted list behaves like EOF."""

    def __init__(self, answers=(), **kwargs):
        self._answers = list(answers)
        self._index = 0
        super().__init__(
            out=io.StringIO(),
            interactive=False,
            palette=config.Palette(False),
            reader=self._next,
            **kwargs
        )

    def _next(self, prompt):
        if self._index >= len(self._answers):
            return None
        value = self._answers[self._index]
        self._index += 1
        return value

    def output(self):
        return self.out.getvalue()


def make_temp_repo(base, inventory_text=None, playbook_overrides=None):
    """A minimal repository: real playbooks (copied), its own inventory and scripts.

    The playbooks are **copied**, never symlinked: a test that deletes or edits a
    playbook must never be able to reach the real checkout.
    """
    os.makedirs(os.path.join(base, "ansible", "inventory", "group_vars"), exist_ok=True)
    os.makedirs(os.path.join(base, "scripts", "install"), exist_ok=True)
    os.makedirs(os.path.join(base, "scripts", "diagnostics"), exist_ok=True)
    shutil.copytree(os.path.join(REPO_ROOT, "ansible", "playbooks"),
                    os.path.join(base, "ansible", "playbooks"))
    real_group_vars = os.path.join(REPO_ROOT, "ansible", "inventory", "group_vars", "all.yml")
    if os.path.isfile(real_group_vars):
        shutil.copy(real_group_vars, os.path.join(base, "ansible", "inventory", "group_vars", "all.yml"))
    if inventory_text is not None:
        with open(os.path.join(base, "ansible", "inventory", "hosts.yml"), "w", encoding="utf-8") as handle:
            handle.write(inventory_text)
    shutil.copy(os.path.join(REPO_ROOT, "scripts", "install", "blueforce-install.sh"),
                os.path.join(base, "scripts", "install", "blueforce-install.sh"))
    stub = os.path.join(base, "scripts", "diagnostics", "bf-status")
    with open(stub, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\necho stub\n")
    os.chmod(stub, 0o755)
    for name in ("bf-diagnostics", "bf-check-local", "bf-check-enrollment", "bf-check-ready"):
        path = os.path.join(base, "scripts", "diagnostics", name)
        shutil.copy(stub, path)
        os.chmod(path, 0o755)
    for name, text in (playbook_overrides or {}).items():
        with open(os.path.join(base, "ansible", "playbooks", name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return Repository(base)


SIMPLE_INVENTORY = """\
all:
  children:
    blueforce:
      children:
        lab:
          hosts:
            bf-12010101:
              ansible_host: 10.42.0.11
            bf-12010102:
              ansible_host: 10.42.0.12
        pilot_1:
          hosts:
            bf-12010201:
              ansible_host: 10.42.1.11
        production:
          hosts:
            bf-12010601:
              ansible_host: 10.42.5.11
      vars:
        ansible_user: blueforce
"""


# ---------------------------------------------------------------------------
# Catalogue and scope: the playbook is the source of truth
# ---------------------------------------------------------------------------
class TestCatalogue(unittest.TestCase):
    def setUp(self):
        self.repo = Repository(REPO_ROOT)

    def test_21_operations_and_unique_rows(self):
        self.assertEqual(21, len(operations.ALL_OPERATIONS))
        self.assertEqual(11, len(operations.REPORT_OPERATIONS))
        self.assertEqual(10, len(operations.MAINTENANCE_OPERATIONS))
        idents = [op.ident for op in operations.ALL_OPERATIONS]
        playbooks = [op.playbook for op in operations.ALL_OPERATIONS]
        self.assertEqual(len(idents), len(set(idents)))
        self.assertEqual(len(playbooks), len(set(playbooks)))

    def test_catalogue_matches_the_playbook_directory(self):
        on_disk = sorted(
            name for name in os.listdir(self.repo.path(config.PLAYBOOK_DIR_REL))
            if name.endswith(".yml") and not name.startswith(".")
        )
        catalogued = sorted(op.playbook for op in operations.ALL_OPERATIONS)
        self.assertEqual(on_disk, catalogued)

    def test_every_declared_scope_matches_the_playbook_file(self):
        for op in operations.ALL_OPERATIONS:
            with self.subTest(playbook=op.playbook):
                self.assertEqual(op.declared_scope, self.repo.verify_scope(op))

    def test_scope_drift_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp, playbook_overrides={
                "bf-ping.yml": "---\n- hosts: all\n  vars:\n    release_wave: lab\n  tasks: []\n"
            })
            ping = operations.find_operation("ping")
            with self.assertRaises(Refused) as caught:
                repo.verify_scope(ping)
            self.assertIn("bf-ping.yml", caught.exception.message)

    def test_missing_playbook_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp)
            os.unlink(os.path.join(tmp, "ansible", "playbooks", "bf-ping.yml"))
            with self.assertRaises(Refused):
                repo.verify_scope(operations.find_operation("ping"))

    def test_destructive_flags_match_the_docs(self):
        self.assertFalse(operations.find_operation("ping").destructive)
        self.assertTrue(operations.find_operation("reboot").destructive)
        self.assertTrue(operations.find_operation("deploy-update").destructive)
        self.assertEqual(config.SCOPE_RELEASE, operations.find_operation("reboot").declared_scope)
        self.assertEqual(config.SCOPE_RELEASE, operations.find_operation("deploy-update").declared_scope)

    def test_target_modes_follow_the_scope(self):
        self.assertEqual(config.MODE_ANY, operations.find_operation("ping").target_mode)
        self.assertEqual(config.MODE_WAVE, operations.find_operation("gui-off").target_mode)
        self.assertEqual(config.MODE_RELEASE, operations.find_operation("deploy-update").target_mode)


class TestScopeDerivation(unittest.TestCase):
    def test_scope_from_variables(self):
        self.assertEqual(config.SCOPE_RELEASE, operations.playbook_scope("x: {{ release_wave }}"))
        self.assertEqual(config.SCOPE_WAVE, operations.playbook_scope("x: {{ operation_wave }}"))
        self.assertEqual(config.SCOPE_SIMPLE, operations.playbook_scope("hosts: blueforce"))

    def test_full_line_comments_do_not_count(self):
        text = "# release_wave is documented here\nhosts: blueforce\n"
        self.assertEqual(config.SCOPE_SIMPLE, operations.playbook_scope(text))

    def test_word_boundaries_are_respected(self):
        self.assertEqual(config.SCOPE_SIMPLE, operations.playbook_scope("release_waves: []"))

    def test_inline_comment_parity_with_bash(self):
        # The bash console strips only full-line comments, and so does this one:
        # a variable named in a trailing comment still counts, which keeps the
        # two consoles from disagreeing about a playbook.
        text = "hosts: blueforce  # release_wave\n"
        self.assertEqual(config.SCOPE_RELEASE, operations.playbook_scope(text))


# ---------------------------------------------------------------------------
# Identity and inventory
# ---------------------------------------------------------------------------
class TestIdentity(unittest.TestCase):
    def test_dealer_number_pattern(self):
        self.assertTrue(operations.dealer_is_valid("12010101"))
        self.assertFalse(operations.dealer_is_valid("1201010"))
        self.assertFalse(operations.dealer_is_valid("120101011"))
        self.assertFalse(operations.dealer_is_valid("1201010a"))
        self.assertFalse(operations.dealer_is_valid(" 12010101"))
        self.assertFalse(operations.dealer_is_valid(""))

    def test_host_and_device_id_mapping(self):
        self.assertEqual("bf-12010101", operations.dealer_to_host("12010101"))
        self.assertEqual("BF-12010101", operations.dealer_to_device_id("12010101"))
        self.assertEqual("12010101", operations.host_to_dealer("bf-12010101"))
        self.assertIsNone(operations.host_to_dealer("web-01"))

    def test_waves_are_the_canonical_six(self):
        self.assertEqual(
            ("lab", "pilot_1", "pilot_2", "wave_1", "wave_2", "production"), config.WAVES)
        self.assertTrue(operations.is_wave("production"))
        self.assertFalse(operations.is_wave("blueforce"))


class TestInventory(unittest.TestCase):
    def setUp(self):
        self.inventory = Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml")

    def test_groups_and_counts(self):
        self.assertEqual(("lab", "pilot_1", "production"), self.inventory.group_names())
        self.assertEqual(2, len(self.inventory.hosts_of("lab")))
        self.assertEqual(("bf-12010101", "bf-12010102"), self.inventory.hosts_of("lab"))
        self.assertEqual(4, self.inventory.count_all())
        self.assertTrue(self.inventory.resolved)

    def test_vars_block_is_not_read_as_a_host(self):
        self.assertNotIn("ansible_user", self.inventory.all_hosts())

    def test_wave_order_and_host_wave(self):
        self.assertEqual(("lab", "pilot_1", "production"), self.inventory.waves_present())
        self.assertEqual("lab", self.inventory.host_wave("bf-12010101"))
        self.assertEqual("production", self.inventory.host_wave("bf-12010601"))
        self.assertIsNone(self.inventory.host_wave("bf-99999999"))

    def test_example_inventory_from_the_repo_parses(self):
        example = Repository(REPO_ROOT).path(config.INVENTORY_EXAMPLE_REL)
        inventory = Inventory.load(example)
        self.assertEqual(6, len(inventory.waves_present()))
        self.assertEqual(15, inventory.count_all())
        self.assertEqual(5, len(inventory.hosts_of("pilot_1")))

    def test_example_inventory_is_never_auto_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp)
            shutil.copy(os.path.join(REPO_ROOT, config.INVENTORY_EXAMPLE_REL),
                        repo.path(config.INVENTORY_EXAMPLE_REL))
            with self.assertRaises(Refused) as caught:
                repo.find_inventory()
            self.assertIn("hosts.example.yml", caught.exception.detail)
            self.assertIn("hosts.yml", caught.exception.message)

    def test_unreadable_explicit_inventory_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp)
            with self.assertRaises(Refused):
                repo.find_inventory(os.path.join(tmp, "nope.yml"))

    def test_missing_inventory_yields_an_unresolved_view(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp)
            inventory = Inventory.load_repository(repo)
            self.assertFalse(inventory.resolved)
            self.assertEqual("çözümlenmedi", inventory.labels())

    def test_load_repository_reads_hosts_yml(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp, inventory_text=SIMPLE_INVENTORY)
            inventory = Inventory.load_repository(repo)
            self.assertTrue(inventory.resolved)
            self.assertEqual(4, inventory.count_all())


# ---------------------------------------------------------------------------
# Target selection and its refusal paths
# ---------------------------------------------------------------------------
class TestTargets(unittest.TestCase):
    def setUp(self):
        self.inventory = Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml")

    def resolve(self, word, mode=config.MODE_ANY):
        return operations.resolve_target(word, mode, self.inventory)

    def test_single_device(self):
        target = self.resolve("12010101")
        self.assertEqual(operations.KIND_HOST, target.kind)
        self.assertEqual("bf-12010101", target.limit)
        self.assertEqual("lab", target.wave)
        self.assertEqual(1, target.count)

    def test_hostname_is_accepted_as_convenience(self):
        target = self.resolve("bf-12010101")
        self.assertEqual("bf-12010101", target.limit)

    def test_group_and_wave(self):
        self.assertEqual("lab", self.resolve("lab", config.MODE_WAVE).limit)
        self.assertEqual(2, self.resolve("lab", config.MODE_WAVE).count)

    def test_all(self):
        target = self.resolve("all")
        self.assertEqual(operations.KIND_ALL, target.kind)
        self.assertEqual("all", target.limit)
        self.assertEqual(4, target.count)

    def test_bad_dealer_number_is_refused(self):
        for value in ("1201", "1201010x", "120101011", "1201 0101"):
            with self.subTest(value=value):
                with self.assertRaises(Refused) as caught:
                    self.resolve(value)
                self.assertIn("bayi numarası", caught.exception.message)

    def test_unknown_device_is_refused(self):
        with self.assertRaises(Refused) as caught:
            self.resolve("99999999")
        self.assertIn("envanterde yok", caught.exception.message)

    def test_device_outside_a_wave_is_refused_for_wave_scope(self):
        inventory = Inventory.parse(
            "all:\n  children:\n    blueforce:\n      children:\n"
            "        ops:\n          hosts:\n            bf-12019999:\n"
        )
        with self.assertRaises(Refused) as caught:
            operations.resolve_target("12019999", config.MODE_WAVE, inventory)
        self.assertIn("onaylı bir dalgada değil", caught.exception.message)

    def test_release_scope_refuses_a_single_device(self):
        with self.assertRaises(Refused) as caught:
            self.resolve("12010101", config.MODE_RELEASE)
        self.assertIn("dalga grubu", caught.exception.message)

    def test_release_scope_refuses_the_whole_fleet(self):
        with self.assertRaises(Refused) as caught:
            self.resolve("all", config.MODE_RELEASE)
        self.assertIn("reddedildi", caught.exception.message)

    def test_wave_scope_refuses_a_non_wave_group(self):
        inventory = Inventory.parse(
            "all:\n  children:\n    blueforce:\n      children:\n"
            "        ops:\n          hosts:\n            bf-12010101:\n"
        )
        with self.assertRaises(Refused) as caught:
            operations.resolve_target("ops", config.MODE_WAVE, inventory)
        self.assertIn("onaylı bir dalga değil", caught.exception.message)

    def test_unknown_group_is_refused(self):
        with self.assertRaises(Refused) as caught:
            self.resolve("wave_9")
        self.assertIn("grup", caught.exception.message)
        self.assertIn("lab", caught.exception.detail)  # the known groups are listed

    def test_empty_group_and_empty_fleet_are_refused(self):
        empty = Inventory.parse("all:\n  children:\n    blueforce:\n      children:\n        lab:\n          hosts:\n")
        with self.assertRaises(Refused):
            operations.resolve_target("lab", config.MODE_WAVE, empty)
        with self.assertRaises(Refused):
            operations.resolve_target("all", config.MODE_ANY, empty)

    def test_empty_word_is_refused(self):
        with self.assertRaises(Refused):
            self.resolve("")

    def test_wave_sequence_is_in_rollout_order(self):
        self.assertEqual((("lab", 2), ("pilot_1", 1), ("production", 1)),
                         operations.wave_sequence(self.inventory))


# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------
class TestGatePlan(unittest.TestCase):
    def plan(self, ident, scope, word, mode=None, wave_gate=False):
        op = operations.find_operation(ident)
        inventory = Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml")
        target = operations.resolve_target(word, mode or op.target_mode, inventory)
        return operations.confirmation_plan(op, scope, target, wave=target.wave,
                                            wave_gate_supported=wave_gate)

    def test_simple_readonly_operation_needs_no_gate(self):
        self.assertEqual([], self.plan("ping", config.SCOPE_SIMPLE, "12010101"))

    def test_wave_scoped_read_only_report_needs_no_token(self):
        # bash parity: bf_confirm_wave_gate returns immediately for a
        # non-production wave, so a wave-scoped report asks no token.
        self.assertEqual([], self.plan("collect-logs", config.SCOPE_WAVE, "lab"))

    def test_wave_scoped_destructive_operation_only_adds_the_second_approval(self):
        steps = self.plan("gui-off", config.SCOPE_WAVE, "lab")
        self.assertEqual(["destructive_approval"], [step.key for step in steps])

    def test_release_scope_requires_a_written_wave_token(self):
        steps = self.plan("deploy-update", config.SCOPE_RELEASE, "lab", wave_gate=True)
        token = steps[0]
        self.assertEqual(STEP_TOKEN, token.kind)
        self.assertEqual("lab", token.token)
        self.assertIn("dalga onayı", token.message.lower())
        self.assertIn(operations.VAR_WAVE_GATE_CONFIRMED, token.unlocks)

    def test_release_wave_token_unlocks_nothing_when_the_playbook_has_no_gate(self):
        steps = self.plan("reboot", config.SCOPE_RELEASE, "lab", wave_gate=False)
        self.assertEqual((), steps[0].unlocks)

    def test_production_needs_the_typed_word_and_a_separate_approval(self):
        steps = self.plan("deploy-update", config.SCOPE_RELEASE, "production",
                          mode=config.MODE_RELEASE, wave_gate=True)
        kinds = [(step.kind, step.key) for step in steps]
        # The production approval *is* the destructive second confirmation: it
        # names the flag it unlocks, so no generic duplicate is added after it.
        self.assertEqual([(STEP_TOKEN, "production_token"), (STEP_APPROVAL, "production_approval")], kinds)
        self.assertEqual("production", steps[0].token)
        self.assertIn(operations.VAR_PRODUCTION_OVERRIDE, steps[1].unlocks)
        self.assertIn(operations.VAR_ALLOW_PRODUCTION_REBOOT, steps[1].unlocks)

    def test_destructive_operation_asks_twice(self):
        with_destructive = self.plan("gui-off", config.SCOPE_WAVE, "lab")
        without = self.plan("collect-logs", config.SCOPE_WAVE, "lab")
        self.assertIn("destructive_approval", [step.key for step in with_destructive])
        self.assertNotIn("destructive_approval", [step.key for step in without])
        self.assertIn("Yıkıcı işlem kapısı", with_destructive[0].message)

    def test_production_wave_of_a_wave_scoped_playbook_also_needs_both_steps(self):
        steps = self.plan("gui-off", config.SCOPE_WAVE, "production")
        self.assertEqual(["production_token", "production_approval"],
                         [step.key for step in steps])

    def test_fleet_wide_simple_run_requires_the_word_all(self):
        steps = self.plan("ping", config.SCOPE_SIMPLE, "all")
        self.assertEqual(1, len(steps))
        self.assertEqual("all", steps[0].token)
        self.assertIn("fleet_wide", steps[0].unlocks)

    def test_fleet_wide_gated_run_leaves_the_token_to_the_per_wave_loop(self):
        # The fleet-wide target itself has no wave, so no wave token belongs at
        # this level: run_fleet_waves asks each wave's name once, per wave, and
        # the per-wave plan is then applied without re-asking it.
        fleet_steps = self.plan("gui-off", config.SCOPE_WAVE, "all", mode=config.MODE_ANY)
        self.assertEqual(["destructive_approval"], [step.key for step in fleet_steps])
        per_wave = self.plan("gui-off", config.SCOPE_WAVE, "lab")
        self.assertEqual(["destructive_approval"], [step.key for step in per_wave])
        release = self.plan("deploy-update", config.SCOPE_RELEASE, "lab", wave_gate=True)
        self.assertEqual("lab", release[0].token)

    def test_granting_sets_only_the_offered_flags(self):
        steps = self.plan("deploy-update", config.SCOPE_RELEASE, "lab", wave_gate=True)
        gates = GatesGranted()
        self.assertFalse(gates.wave_gate_confirmed)
        granted = gates.grant(steps[0])
        self.assertTrue(granted.wave_gate_confirmed)
        self.assertFalse(granted.production_override)


# ---------------------------------------------------------------------------
# Extra variables
# ---------------------------------------------------------------------------
class TestExtraVars(unittest.TestCase):
    def test_package_pins(self):
        pins = operations.parse_packages("docker-ce=1:27.0.3, wireguard=1.0")
        self.assertEqual(["docker-ce=1:27.0.3", "wireguard=1.0"], pins)
        self.assertEqual('["docker-ce=1:27.0.3","wireguard=1.0"]',
                         operations.packages_expression(pins))

    def test_bad_package_pins_are_refused(self):
        for value in ("", "docker-ce", "docker-ce=latest=", "=1.2", "docker-ce=latest"):
            with self.subTest(value=value):
                with self.assertRaises(Refused):
                    operations.parse_packages(value)

    def test_latest_is_refused_with_a_policy_message(self):
        with self.assertRaises(Refused) as caught:
            operations.parse_packages("docker-ce=latest")
        self.assertIn("latest", caught.exception.message)

    def test_service_allowlist(self):
        self.assertEqual("docker", operations.parse_service("docker"))
        with self.assertRaises(Refused) as caught:
            operations.parse_service("nginx")
        self.assertIn("izinli servis", caught.exception.message)

    def test_script_paths_are_confined(self):
        self.assertEqual([("script_path", "/opt/blueforce/bin/check.sh")],
                         operations.parse_script("/opt/blueforce/bin/check.sh"))
        pairs = operations.parse_script("/usr/local/sbin/x.sh", "--dry-run")
        self.assertEqual([("script_path", "/usr/local/sbin/x.sh"), ("script_args", "--dry-run")], pairs)
        for value in ("relative.sh", "/tmp/x.sh", "/opt/blueforce/binsneaky.sh"):
            with self.subTest(value=value):
                with self.assertRaises(Refused):
                    operations.parse_script(value)

    def test_grace_period(self):
        self.assertEqual("300", operations.parse_grace(""))
        self.assertEqual("60", operations.parse_grace("60"))
        for value in ("-1", "abc", "1.5"):
            with self.subTest(value=value):
                with self.assertRaises(Refused):
                    operations.parse_grace(value)

    def test_disk_threshold(self):
        self.assertEqual([], operations.parse_disk_pct(""))
        self.assertEqual([("disk_warn_pct", "90")], operations.parse_disk_pct("90"))
        for value in ("0", "101", "abc"):
            with self.subTest(value=value):
                with self.assertRaises(Refused):
                    operations.parse_disk_pct(value)

    def test_log_lines_and_version(self):
        self.assertEqual("500", operations.parse_log_lines(""))
        self.assertEqual("10", operations.parse_log_lines("10"))
        with self.assertRaises(Refused):
            operations.parse_log_lines("0")
        self.assertEqual([], operations.parse_expected_version(""))
        self.assertEqual([("fieldos_expected_version", "1.0.0")],
                         operations.parse_expected_version("1.0.0"))

    def test_build_extra_vars_dispatch(self):
        self.assertEqual([], operations.build_extra_vars(operations.PROMPT_NONE, {}))
        self.assertEqual([("log_lines", "250")],
                         operations.build_extra_vars(operations.PROMPT_LOG_LINES, {"log_lines": "250"}))
        with self.assertRaises(Refused):
            operations.build_extra_vars("bilinmeyen", {})


# ---------------------------------------------------------------------------
# Command building
# ---------------------------------------------------------------------------
class TestCommandBuilding(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = make_temp_repo(self.tmp.name, inventory_text=SIMPLE_INVENTORY)
        self.inventory = Inventory.load(self.repo.path(os.path.join(config.INVENTORY_DIR_REL, "hosts.yml")))

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, ident, word, mode=None, extra=(), gates=None, check=False):
        op = operations.find_operation(ident)
        target = operations.resolve_target(word, mode or op.target_mode, self.inventory)
        return operations.build_ansible_command(
            self.repo, self.inventory.path, op, op.declared_scope, target,
            wave=target.wave, extra_vars=extra, gates=gates or GatesGranted(), check_mode=check,
        )

    def test_simple_scope_gets_only_a_limit(self):
        argv = self.build("ping", "12010101")
        self.assertEqual([
            "ansible-playbook", "-i", self.inventory.path,
            self.repo.playbook_path("bf-ping.yml"), "--limit", "bf-12010101",
        ], argv)
        self.assertNotIn("-e", argv)

    def test_wave_scope_sets_wave_and_confirmation(self):
        argv = self.build("gui-off", "lab")
        self.assertIn("-e", argv)
        self.assertIn("operation_wave=lab", argv)
        self.assertIn("operation_confirmed=true", argv)
        self.assertNotIn("production_override=true", argv)

    def test_production_wave_adds_the_override_only_when_granted(self):
        without = self.build("gui-off", "production")
        self.assertNotIn("production_override=true", without)
        with_override = self.build("gui-off", "production", gates=GatesGranted(production_override=True))
        self.assertIn("production_override=true", with_override)

    def test_release_scope_flags(self):
        argv = self.build("deploy-update", "lab")
        self.assertIn("release_wave=lab", argv)
        self.assertNotIn("wave_gate_confirmed=true", argv)
        gated = self.build("deploy-update", "lab", gates=GatesGranted(wave_gate_confirmed=True))
        self.assertIn("wave_gate_confirmed=true", gated)

    def test_reboot_confirmation_is_always_added_for_the_reboot_playbook(self):
        argv = self.build("reboot", "lab")
        self.assertIn("reboot_confirmed=true", argv)
        self.assertNotIn("allow_production_reboot=true", argv)

    def test_production_release_run_carries_every_gate_flag(self):
        argv = self.build("reboot", "production", mode=config.MODE_RELEASE,
                          gates=GatesGranted(wave_gate_confirmed=True, production_override=True,
                                             allow_production_reboot=True))
        for flag in ("release_wave=production", "allow_production_reboot=true",
                     "reboot_confirmed=true"):
            self.assertIn(flag, argv)
        # bf-reboot.yml does not declare production_override: the builder never
        # invents a variable the playbook does not know (parity rule).
        self.assertNotIn("production_override=true", argv)

    def test_production_override_is_passed_to_the_playbook_that_declares_it(self):
        argv = self.build("deploy-update", "production", mode=config.MODE_RELEASE,
                          gates=GatesGranted(wave_gate_confirmed=True, production_override=True))
        self.assertIn("release_wave=production", argv)
        self.assertIn("wave_gate_confirmed=true", argv)
        self.assertIn("production_override=true", argv)

    def test_check_mode_appends_the_flag(self):
        self.assertEqual("--check", self.build("ping", "lab", check=True)[-1])

    def test_extra_vars_are_appended_before_the_check_flag(self):
        argv = self.build("deploy-update", "lab",
                          extra=[("update_packages", '[\"docker-ce=1:27\"]')], check=True)
        self.assertIn('update_packages=["docker-ce=1:27"]', argv)
        self.assertEqual("--check", argv[-1])

    def test_no_command_without_a_target(self):
        op = operations.find_operation("ping")
        with self.assertRaises(Refused):
            operations.build_ansible_command(self.repo, self.inventory.path, op,
                                             config.SCOPE_SIMPLE, None)

    def test_wave_scope_without_a_wave_is_refused(self):
        op = operations.find_operation("gui-off")
        target = operations.Target(operations.KIND_HOST, "bf-12010101", "", 1, "cihaz")
        with self.assertRaises(Refused):
            operations.build_ansible_command(self.repo, self.inventory.path, op,
                                             config.SCOPE_WAVE, target, wave="")

    def test_release_scope_with_a_non_wave_target_is_refused(self):
        op = operations.find_operation("deploy-update")
        target = operations.Target(operations.KIND_GROUP, "ops", "", 3, "grup")
        with self.assertRaises(Refused):
            operations.build_ansible_command(self.repo, self.inventory.path, op,
                                             config.SCOPE_RELEASE, target, wave="ops")

    def test_no_playbook_variable_is_added_that_the_playbook_does_not_declare(self):
        # bf-gui-off.yml declares production_override but no release_wave; the
        # builder must never hand a playbook a variable it did not declare.
        argv = self.build("collect-logs", "lab", extra=[("log_lines", "100")])
        self.assertIn("log_lines=100", argv)
        self.assertNotIn("release_wave=lab", argv)


class TestLocalCommands(unittest.TestCase):
    def test_installer_command(self):
        argv = operations.build_install_command("/repo/scripts/install/blueforce-install.sh", "12010101",
                                                offline=True, resume=True, check_mode=True)
        self.assertEqual([
            "bash", "/repo/scripts/install/blueforce-install.sh", "--dealer-id", "12010101",
            "--offline", "--resume", "--check",
        ], argv)

    def test_installer_command_rejects_a_bad_dealer_number(self):
        with self.assertRaises(Refused):
            operations.build_install_command("/x/install.sh", "1201")

    def test_tool_command(self):
        self.assertEqual(["bf-remote-status", "--check"],
                         operations.build_tool_command("bf-remote-status", ("--check",)))

    def test_module_names_is_a_tuple(self):
        self.assertIsInstance(operations.module_names(Repository(REPO_ROOT)), tuple)

    def test_tool_path_resolution(self):
        repo = Repository(REPO_ROOT)
        resolved = repo.tool_path("bf-status")
        self.assertTrue(resolved.endswith(os.path.join("scripts", "diagnostics", "bf-status"))
                        or resolved.startswith(config.TOOL_BIN_DIR))
        with self.assertRaises(Refused):
            repo.tool_path("bf-does-not-exist")

    def test_installer_missing_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_temp_repo(tmp)
            os.unlink(repo.path(config.INSTALLER_REL))
            with self.assertRaises(Refused):
                repo.installer_path()


# ---------------------------------------------------------------------------
# Redaction and the audit log
# ---------------------------------------------------------------------------
class TestRedaction(unittest.TestCase):
    def test_assignments_are_redacted(self):
        text = ("-e password=hunter2 -e api_key=abcd1234 -e PSK=deadbeef "
                "-e private_key_path=/root/id_rsa -e credential=a1b2c3")
        cleaned = runner.redact(text)
        for secret in ("hunter2", "abcd1234", "deadbeef", "a1b2c3"):
            self.assertNotIn(secret, cleaned)
        self.assertIn("<redacted>", cleaned)

    def test_pem_blocks_are_redacted(self):
        pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3NzaC1yc2E\n-----END OPENSSH PRIVATE KEY-----"
        self.assertEqual("<redacted>", runner.redact(pem))

    def test_truncated_pem_header_is_still_marked(self):
        self.assertNotIn("AAAAB3NzaC1yc2E", runner.redact("-----BEGIN RSA PRIVATE KEY-----\nAAAAB3NzaC1yc2E"))

    def test_ordinary_commands_are_untouched(self):
        line = ('ansible-playbook -i /opt/blueforce-linux/ansible/inventory/hosts.yml '
                '/opt/blueforce-linux/ansible/playbooks/bf-deploy-update.yml --limit lab '
                '-e release_wave=lab -e update_packages=["docker-ce=1:27.0.3"]')
        self.assertEqual(line, runner.redact(line))

    def test_empty_input(self):
        self.assertEqual("", runner.redact(""))


class TestAuditLog(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "blueforce-console.log")

    def test_log_is_created_with_mode_600(self):
        audit = runner.AuditLog(requested=self.path, state_home=self.tmp.name)
        audit.initialise()
        self.assertTrue(audit.ready)
        self.assertEqual(self.path, audit.path)
        self.assertEqual("", audit.warning)
        self.assertEqual(0o600, stat.S_IMODE(os.stat(self.path).st_mode))

    def test_existing_world_readable_log_is_tightened(self):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write("")
        os.chmod(self.path, 0o644)
        audit = runner.AuditLog(requested=self.path, state_home=self.tmp.name)
        audit.initialise()
        self.assertEqual(0o600, stat.S_IMODE(os.stat(self.path).st_mode))

    def test_unwritable_path_falls_back_to_the_state_directory(self):
        audit = runner.AuditLog(requested="/proc/1/definitely-not-writable/console.log",
                                state_home=self.tmp.name)
        audit.initialise()
        self.assertTrue(audit.ready)
        self.assertEqual(runner.fallback_log_path(self.tmp.name), audit.path)
        self.assertIn("mod 600", audit.warning)
        self.assertEqual(0o600, stat.S_IMODE(os.stat(audit.path).st_mode))

    def test_never_writes_a_secret(self):
        audit = runner.AuditLog(requested=self.path, state_home=self.tmp.name)
        audit.initialise()
        audit.write(config.AUDIT_RUN, "ansible-playbook -e password=topsecret1 -e psk=deadbeef")
        with open(self.path, "r", encoding="utf-8") as handle:
            content = handle.read()
        self.assertNotIn("topsecret1", content)
        self.assertNotIn("deadbeef", content)
        self.assertIn("<redacted>", content)
        self.assertIn("[RUN]", content)

    def test_no_output_is_written_when_no_log_is_available(self):
        audit = runner.AuditLog(requested="/proc/1/definitely-not-writable/console.log",
                                state_home="/proc/1/definitely-not-writable")
        audit.initialise()
        self.assertFalse(audit.ready)
        self.assertEqual(config.MSG_LOG_NONE, audit.warning)
        audit.write(config.AUDIT_RUN, "yazılmayacak")  # must not raise


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
class TestRunner(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.audit = runner.AuditLog(requested=os.path.join(self.tmp.name, "log"),
                                     state_home=self.tmp.name)
        self.audit.initialise()
        self.spawn = FakeSpawn()

    def make(self, answers, dry_run=False, check_mode=False):
        console = ScriptedConsole(answers)
        return console, runner.Runner(console, audit=self.audit, dry_run=dry_run,
                                      check_mode=check_mode, spawn=self.spawn)

    def log_text(self):
        with open(self.audit.path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_dry_run_executes_nothing(self):
        console, run = self.make([], dry_run=True)
        result = run.confirm_and_run(["ansible-playbook", "--version"], "deneme")
        self.assertTrue(result.dry_run)
        self.assertFalse(result.executed)
        self.assertEqual([], self.spawn.calls)
        self.assertIn("ÇALIŞTIRILMADI", console.output())
        self.assertIn("[DRYRUN]", self.log_text())

    def test_confirmed_run_reports_the_exit_code(self):
        console, run = self.make(["y"])
        self.spawn.codes = [0]
        result = run.confirm_and_run(["ansible-playbook", "pb.yml", "--limit", "lab"], "işlem",
                                     destructive=True)
        self.assertTrue(result.executed)
        self.assertEqual(0, result.rc)
        self.assertTrue(result.ok)
        self.assertEqual([["ansible-playbook", "pb.yml", "--limit", "lab"]], self.spawn.calls)
        self.assertIn("[OK]", self.log_text())
        self.assertIn("başarıyla tamamlandı", console.output())

    def test_check_answer_appends_check(self):
        console, run = self.make(["c"])
        run.confirm_and_run(["ansible-playbook", "pb.yml"], "işlem")
        self.assertEqual([["ansible-playbook", "pb.yml", "--check"]], self.spawn.calls)
        self.assertIn("--check", self.log_text())

    def test_anything_else_cancels(self):
        for answer in ("", "h", "hayır", "n"):
            with self.subTest(answer=answer):
                self.spawn.calls = []
                console, run = self.make([answer])
                result = run.confirm_and_run(["ansible-playbook", "pb.yml"], "işlem")
                self.assertTrue(result.cancelled)
                self.assertEqual([], self.spawn.calls)
                self.assertIn("[CANCEL]", self.log_text())

    def test_eof_cancels_instead_of_running(self):
        console, run = self.make([])
        result = run.confirm_and_run(["ansible-playbook", "pb.yml"], "işlem")
        self.assertTrue(result.cancelled)
        self.assertEqual([], self.spawn.calls)

    def test_failure_is_reported(self):
        console, run = self.make(["y"])
        self.spawn.codes = [2]
        result = run.confirm_and_run(["ansible-playbook", "pb.yml"], "işlem")
        self.assertEqual(2, result.rc)
        self.assertFalse(result.ok)
        self.assertIn("[FAIL]", self.log_text())
        self.assertIn("çıkış koduyla başarısız", console.output())

    def test_readonly_run_does_not_ask(self):
        console, run = self.make([])
        run.run_readonly(["bf-status"], title="bf-status")
        self.assertEqual([["bf-status"]], self.spawn.calls)

    def test_command_is_shown_before_it_runs(self):
        console, run = self.make(["h"])
        run.confirm_and_run(["ansible-playbook", "--limit", "lab"], "işlem")
        output = console.output()
        self.assertIn("Çalıştırılacak komut", output)
        self.assertIn("ansible-playbook --limit lab", output)

    def test_command_string_quotes_arguments(self):
        self.assertEqual("ansible-playbook -e 'a b'", runner.command_string(
            ["ansible-playbook", "-e", "a b"]))


# ---------------------------------------------------------------------------
# TUI contract without a terminal
# ---------------------------------------------------------------------------
class TestTuiContract(unittest.TestCase):
    def test_simple_menu_has_exactly_three_basic_actions(self):
        screen = tui.simple_menu()
        items = [entry.label for _, entry in screen.items()]
        self.assertEqual(["Kur", "Durum", "Çıkış"], items)
        self.assertEqual(("1", "2", "3", "d"), screen.keys())

    def test_simple_view_hides_the_detailed_features(self):
        text = tui.render_screen(tui.simple_menu())
        self.assertIn(config.SCREEN_TITLE, text)
        for hidden in (config.CAT_DEVICES, config.CAT_CENTRAL, config.CAT_TOOLS, config.CAT_INFO, ".yml"):
            self.assertNotIn(hidden, text)
        self.assertIn("Detaylı mod", text)

    def test_detailed_menu_has_the_five_categories(self):
        screen = tui.detailed_menu()
        labels = [entry.label for _, entry in screen.items()]
        self.assertEqual([config.CAT_INSTALL, config.CAT_DEVICES, config.CAT_CENTRAL,
                          config.CAT_TOOLS, config.CAT_INFO], labels)
        self.assertEqual(("1", "2", "3", "4", "5", "s"), screen.keys())

    def test_every_screen_offers_back_and_quit(self):
        repo = Repository(REPO_ROOT)
        screens = [
            tui.simple_menu(), tui.detailed_menu(),
            tui.install_menu(cli.App.install_items()),
            tui.devices_menu(11, 10), tui.central_menu(), tui.tools_menu(),
            tui.info_menu(), tui.target_menu(),
        ]
        self.assertTrue(screen_collection_is_nonempty(screens))
        for screen in screens:
            with self.subTest(screen=screen.title):
                text = tui.render_screen(screen)
                self.assertIn("0) Geri", text)
                self.assertIn("q) Çıkış", text)

    def test_colours_are_ansi_and_can_be_switched_off(self):
        plain = tui.render_screen(tui.simple_menu(), config.Palette(False))
        colourful = tui.render_screen(tui.simple_menu(), config.Palette(True))
        self.assertNotIn("\033[", plain)
        self.assertIn("\033[", colourful)
        self.assertIn(config.SCREEN_TITLE, plain)

    def test_color_enabled_rules(self):
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
            self.assertFalse(tui.color_enabled(is_tty=True))
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("NO_COLOR", None)
            self.assertTrue(tui.color_enabled(is_tty=True))
            self.assertFalse(tui.color_enabled(is_tty=False))
        self.assertFalse(tui.color_enabled(mode="never", is_tty=True))
        self.assertTrue(tui.color_enabled(mode="always", is_tty=False))

    def test_menu_choice_interpretation(self):
        keys = ("1", "2", "3", "d")
        self.assertEqual((tui.CHOICE_BACK, ""), tui.interpret_menu_choice("", keys))
        self.assertEqual((tui.CHOICE_BACK, ""), tui.interpret_menu_choice("0", keys))
        self.assertEqual((tui.CHOICE_QUIT, ""), tui.interpret_menu_choice("q", keys))
        self.assertEqual((tui.CHOICE_QUIT, ""), tui.interpret_menu_choice("Q", keys))
        self.assertEqual((tui.CHOICE_ITEM, "2"), tui.interpret_menu_choice("2", keys))
        self.assertEqual((tui.CHOICE_INVALID, "9"), tui.interpret_menu_choice("9", keys))
        self.assertEqual((tui.CHOICE_INVALID, "abc"), tui.interpret_menu_choice("abc", keys))

    def test_invalid_choice_gets_a_turkish_warning(self):
        console = ScriptedConsole(["7"])
        outcome, _ = console.ask_menu_choice(tui.simple_menu())
        self.assertEqual(tui.CHOICE_INVALID, outcome)
        self.assertIn("Geçersiz seçim", console.output())

    def test_eof_quits_the_menu(self):
        console = ScriptedConsole([])
        self.assertIsNone(console.read("Seçim > "))
        self.assertEqual((tui.CHOICE_QUIT, ""), console.ask_menu_choice(tui.simple_menu()))

    def test_turkish_confirmations(self):
        console = ScriptedConsole(["e", "h", "", "evet"])
        self.assertTrue(console.confirm("Onay?"))
        self.assertFalse(console.confirm("Onay?"))
        self.assertFalse(console.confirm("Onay?"))
        self.assertTrue(console.confirm("Onay?"))
        self.assertIn("[e/H]", console.output())

    def test_invalid_yes_no_is_re_asked(self):
        console = ScriptedConsole(["belki", "e"])
        self.assertTrue(console.confirm("Onay?"))
        self.assertIn("Girdi anlaşılamadı", console.output())

    def test_token_confirmation_requires_the_exact_word(self):
        console = ScriptedConsole(["lab", "lab-1", "LAB"])
        self.assertTrue(console.confirm_token("uyarı", "lab", "yazın: "))
        self.assertFalse(console.confirm_token("uyarı", "lab", "yazın: "))
        self.assertFalse(console.confirm_token("uyarı", "lab", "yazın: "))

    def test_ask_run_mapping_matches_the_runner(self):
        self.assertEqual(tui.RUN, runner.RUN_MODE_RUN)
        self.assertEqual(tui.CHECK, runner.RUN_MODE_CHECK)
        self.assertEqual(tui.CANCEL, runner.RUN_MODE_CANCEL)
        console = ScriptedConsole(["y", "c", "x"])
        self.assertEqual(tui.RUN, console.ask_run())
        self.assertEqual(tui.CHECK, console.ask_run())
        self.assertEqual(tui.CANCEL, console.ask_run())


def screen_collection_is_nonempty(screens):
    return len(screens) == 8


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
class TestCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = mock.patch.dict(os.environ, {
            "XDG_STATE_HOME": self.tmp.name,
            "BF_CONSOLE_LOG": os.path.join(self.tmp.name, "console.log"),
            "BF_REPO": "",
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_parser_accepts_the_documented_flags(self):
        args = build_args(["--full", "--dry-run", "--check", "--repo", "/x", "--inventory", "/y",
                           "--lang", "tr", "--no-color"])
        self.assertTrue(args.full and args.dry_run and args.check and args.no_color)
        self.assertEqual("/x", args.repo)
        self.assertEqual("/y", args.inventory)
        self.assertEqual("tr", args.lang)

    def test_version(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            code = cli.main(["--version"])
        self.assertEqual(config.EXIT_OK, code)
        self.assertEqual("bfos {0}\n".format(config.VERSION), out.getvalue())

    def test_unsupported_language_is_refused_in_turkish(self):
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            code = cli.main(["--lang", "en"])
        self.assertEqual(config.EXIT_USAGE, code)
        self.assertIn("yalnızca Türkçe", err.getvalue())

    def test_invalid_repository_is_a_usage_error(self):
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            code = cli.main(["--repo", os.path.join(self.tmp.name, "not-a-repo")])
        self.assertEqual(config.EXIT_USAGE, code)
        self.assertIn("Blueforce deposu", err.getvalue())

    def test_list_is_non_interactive_and_covers_21_operations(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            code = cli.main(["--list", "--log-file", os.path.join(self.tmp.name, "console.log")])
        self.assertEqual(config.EXIT_OK, code)
        text = out.getvalue()
        self.assertIn("kapsam=simple", text)
        self.assertIn("kapsam=release", text)
        self.assertEqual(21, sum(1 for line in text.splitlines() if "kapsam=" in line))

    def test_list_targets_without_an_inventory_still_explains(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            code = cli.main(["--list-targets"])
        self.assertEqual(config.EXIT_OK, code)
        self.assertIn("DALGALAR", out.getvalue())

    def test_resolve_repo_finds_the_checkout(self):
        self.assertEqual(REPO_ROOT, cli.resolve_repo("").root)

    def test_catalogue_lines_are_turkish(self):
        text = "\n".join(cli.catalogue_lines())
        self.assertIn("Salt okunur filo raporları", text)
        self.assertIn("yıkıcı=evet", text)


def build_args(argv):
    with mock.patch("sys.stdout", io.StringIO()):
        return cli.build_parser().parse_args(argv)


# ---------------------------------------------------------------------------
# The admin/bf entry point
# ---------------------------------------------------------------------------
class TestAdminEntryPoint(unittest.TestCase):
    PATH = os.path.join(REPO_ROOT, "admin", "bf")

    def test_file_exists_and_is_executable(self):
        self.assertTrue(os.path.isfile(self.PATH))
        self.assertTrue(os.access(self.PATH, os.X_OK))

    def test_file_is_valid_python(self):
        with open(self.PATH, "r", encoding="utf-8") as handle:
            source = handle.read()
        compile(source, self.PATH, "exec")

    def test_python_entry_point_calls_bfos_cli(self):
        completed = subprocess.run([sys.executable, self.PATH, "--version"],
                                   capture_output=True, text=True, check=False)
        self.assertEqual(0, completed.returncode)
        self.assertEqual("bfos {0}".format(config.VERSION), completed.stdout.strip())

    def test_missing_python3_prints_a_turkish_error_and_the_bash_fallback(self):
        with tempfile.TemporaryDirectory() as empty:
            completed = subprocess.run(
                ["/bin/sh", self.PATH],
                capture_output=True, text=True, check=False,
                env={"PATH": empty, "LC_ALL": "C.UTF-8"},
            )
        self.assertEqual(3, completed.returncode)
        self.assertIn("python3 bulunamadı", completed.stderr)
        self.assertIn("bf-menu", completed.stderr)

    def test_repository_root_is_discovered(self):
        completed = subprocess.run([sys.executable, self.PATH, "--list"],
                                   capture_output=True, text=True, check=False,
                                   env=dict(os.environ, XDG_STATE_HOME=tempfile.gettempdir()))
        self.assertEqual(0, completed.returncode)
        self.assertIn("kapsam=wave", completed.stdout)


# ---------------------------------------------------------------------------
# Operator flows end to end (no terminal, nothing executed)
# ---------------------------------------------------------------------------
class TestAppFlows(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = make_temp_repo(self.tmp.name, inventory_text=SIMPLE_INVENTORY)
        self.inventory = Inventory.load(
            self.repo.path(os.path.join(config.INVENTORY_DIR_REL, "hosts.yml")))
        self.spawn = FakeSpawn()
        # A fake ansible-playbook on PATH so have_ansible() is true without
        # installing anything; the fake spawner still captures every command.
        self.bin = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bin, exist_ok=True)
        ansible = os.path.join(self.bin, "ansible-playbook")
        with open(ansible, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        os.chmod(ansible, 0o755)
        self.env = mock.patch.dict(os.environ, {"PATH": self.bin + os.pathsep + os.environ["PATH"]})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.audit = runner.AuditLog(requested=os.path.join(self.tmp.name, "console.log"),
                                     state_home=self.tmp.name)
        self.audit.initialise()

    def make_app(self, answers):
        console = ScriptedConsole(answers)
        run = runner.Runner(console, audit=self.audit, spawn=self.spawn)
        app = cli.App(repo=self.repo, console=console, runner_=run, inventory=self.inventory,
                      full_mode=True)
        return app, console

    def log_text(self):
        with open(self.audit.path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_release_gated_operation_on_a_wave_requires_token_and_confirmation(self):
        app, console = self.make_app(
            ["2", "2", "10", "lab", "docker-ce=1:27.0.3", "lab", "e", "y"])
        code = app.run()
        self.assertEqual(config.EXIT_OK, code)
        self.assertEqual(1, len(self.spawn.calls))
        argv = self.spawn.calls[0]
        self.assertEqual("ansible-playbook", argv[0])
        self.assertEqual(["--limit", "lab"], argv[argv.index("--limit"):argv.index("--limit") + 2])
        for expected in ("release_wave=lab", "wave_gate_confirmed=true",
                         'update_packages=["docker-ce=1:27.0.3"]'):
            self.assertIn(expected, argv)
        self.assertNotIn("--check", argv)
        self.assertIn("[RUN]", self.log_text())
        self.assertIn("başarıyla tamamlandı", console.output())

    def test_wave_token_withheld_runs_nothing(self):
        app, console = self.make_app(["2", "2", "10", "lab", "docker-ce=1:27.0.3", "pilot_1"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("Dalga onayı verilmedi", console.output())

    def test_production_run_requires_the_typed_word_and_the_override(self):
        app, _ = self.make_app(
            ["2", "2", "10", "production", "docker-ce=1:27.0.3", "production", "e", "y"])
        app.run()
        self.assertEqual(1, len(self.spawn.calls))
        argv = self.spawn.calls[0]
        for expected in ("release_wave=production", "production_override=true",
                         "wave_gate_confirmed=true"):
            self.assertIn(expected, argv)

    def test_production_run_without_the_override_approval_runs_nothing(self):
        app, console = self.make_app(
            ["2", "2", "10", "production", "docker-ce=1:27.0.3", "production", "h"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("Üretim onayı verilmedi", console.output())

    def test_wrong_production_word_is_refused(self):
        app, console = self.make_app(
            ["2", "2", "10", "production", "docker-ce=1:27.0.3", "Production"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("Üretim onayı verilmedi", console.output())

    def test_fleet_wide_wave_loop_stops_at_the_first_failure(self):
        self.spawn.codes = [1]  # the lab wave fails immediately
        app, console = self.make_app(["2", "2", "5", "all", "e", "lab", "e", "y"])
        app.run()
        self.assertEqual(1, len(self.spawn.calls), "no later wave may be touched")
        self.assertEqual("lab", self.spawn.calls[0][self.spawn.calls[0].index("--limit") + 1])
        self.assertIn("[STOP]", self.log_text())
        self.assertIn("DURDURULDU", console.output())

    def test_fleet_wide_simple_run_requires_the_word_all(self):
        app, console = self.make_app(["2", "1", "1", "all", "yanliş"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("Filo geneli onayı verilmedi", console.output())

    def test_fleet_wide_simple_run_proceeds_with_the_word_all(self):
        app, _ = self.make_app(["2", "1", "1", "all", "all", "y"])
        app.run()
        self.assertEqual(1, len(self.spawn.calls))
        self.assertEqual("all", self.spawn.calls[0][self.spawn.calls[0].index("--limit") + 1])

    def test_fleet_wide_loop_skips_a_wave_whose_name_is_not_typed(self):
        app, console = self.make_app(["2", "2", "5", "all", "e", "pilot_1", "lab"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("atlandı", console.output())
        self.assertIn("[CANCEL]", self.log_text())

    def test_read_only_operation_records_the_target(self):
        app, _ = self.make_app(["2", "1", "1", "lab", "y"])
        app.run()
        self.assertEqual([["ansible-playbook", "-i", self.inventory.path,
                           self.repo.playbook_path("bf-ping.yml"), "--limit", "lab"]], self.spawn.calls)
        self.assertIn("[TARGET] ping hedef=lab", self.log_text())

    def test_invalid_dealer_number_is_reported_and_nothing_runs(self):
        app, console = self.make_app(["2", "1", "1", "1", "1234"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("Geçersiz bayi numarası", console.output())

    def test_unknown_target_word_is_reported(self):
        app, console = self.make_app(["2", "1", "1", "wave_9"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("bir bayi numarası (8 hane), grup ya da 'all' değil", console.output())

    def test_scope_drift_refuses_to_run_the_operation(self):
        repo = make_temp_repo(os.path.join(self.tmp.name, "drift"), playbook_overrides={
            "bf-ping.yml": "---\n- hosts: all\n  vars:\n    release_wave: lab\n  tasks: []\n"
        })
        app, console = self.make_app([])
        app.repo = repo
        app.run_operation(operations.find_operation("ping"))
        self.assertEqual([], self.spawn.calls)
        self.assertIn("RED", console.output())

    def test_dry_run_mode_executes_nothing(self):
        console = ScriptedConsole(["2", "1", "1", "lab"])
        run = runner.Runner(console, audit=self.audit, dry_run=True, spawn=self.spawn)
        app = cli.App(repo=self.repo, console=console, runner_=run, inventory=self.inventory,
                      full_mode=True)
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("ÇALIŞTIRILMADI", console.output())

    def test_check_mode_appends_check_to_the_fleet_command(self):
        console = ScriptedConsole(["2", "1", "1", "lab", "y"])
        run = runner.Runner(console, audit=self.audit, check_mode=True, spawn=self.spawn)
        app = cli.App(repo=self.repo, console=console, runner_=run, inventory=self.inventory,
                      full_mode=True, check_mode=True)
        app.run()
        self.assertEqual("--check", self.spawn.calls[0][-1])

    def test_simple_mode_status_is_read_only(self):
        console = ScriptedConsole(["2"])
        run = runner.Runner(console, audit=self.audit, spawn=self.spawn)
        app = cli.App(repo=self.repo, console=console, runner_=run, inventory=self.inventory)
        code = app.run()
        self.assertEqual(config.EXIT_OK, code)
        text = console.output()
        self.assertIn("KİMLİK", text)
        self.assertIn("Durum", text)
        self.assertIn("bf-status", text)

    def test_simple_mode_quit_leaves_cleanly(self):
        console = ScriptedConsole(["q"])
        run = runner.Runner(console, audit=self.audit, spawn=self.spawn)
        app = cli.App(repo=self.repo, console=console, runner_=run, inventory=self.inventory)
        self.assertEqual(config.EXIT_OK, app.run())
        self.assertIn("Konsoldan çıkılıyor", console.output())

    def test_simple_mode_d_shortcut_opens_the_detailed_menu(self):
        console = ScriptedConsole(["d", "s", "q"])
        run = runner.Runner(console, audit=self.audit, spawn=self.spawn)
        app = cli.App(repo=self.repo, console=console, runner_=run, inventory=self.inventory)
        app.run()
        self.assertIn(config.CAT_DEVICES, console.output())

    @unittest.skipIf(os.geteuid() == 0, "root check cannot fail as root")
    def test_local_install_requires_root(self):
        app, console = self.make_app(["1", "2", "12010101", "h", "h"])
        app.run()
        self.assertEqual([], self.spawn.calls)
        self.assertIn("root yetkisi gerektirir", console.output())

    def test_install_preflight_uses_check_mode_and_needs_no_root(self):
        app, _ = self.make_app(["1", "1", "12010101"])
        app.run()
        self.assertEqual(1, len(self.spawn.calls))
        argv = self.spawn.calls[0]
        self.assertEqual("bash", argv[0])
        self.assertIn("--dealer-id", argv)
        self.assertIn("--check", argv)

    def test_compare_with_the_bash_console_contract(self):
        """The python command must match the documented bash -e set for a wave run."""
        app, _ = self.make_app(["2", "2", "7", "lab", "100", "y"])
        app.run()
        argv = self.spawn.calls[0]
        # bash: ansible-playbook -i INV PB --limit lab -e operation_wave=lab
        #       -e operation_confirmed=true -e log_lines=100
        self.assertEqual([
            "ansible-playbook", "-i", self.inventory.path,
            self.repo.playbook_path("bf-collect-logs.yml"), "--limit", "lab",
            "-e", "operation_wave=lab", "-e", "operation_confirmed=true",
            "-e", "log_lines=100",
        ], argv)


# ---------------------------------------------------------------------------
# Read-only reports
# ---------------------------------------------------------------------------
class TestReports(unittest.TestCase):
    def test_targets_report(self):
        inventory = Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml")
        text = "\n".join(operations.targets_lines(inventory))
        self.assertIn("DALGALAR (yayılma sırası)", text)
        self.assertIn("lab", text)
        self.assertIn("envanterde yok", text)  # waves the inventory does not have

    def test_wave_gate_state_explains_the_rule(self):
        inventory = Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml")
        text = "\n".join(operations.wave_gate_state_lines(inventory))
        self.assertIn("production", text)
        self.assertIn("production_override", text)

    def test_central_checklist_is_turkish(self):
        text = "\n".join(operations.central_checklist_lines())
        self.assertIn("MERKEZ HAZIRLIK LİSTESİ", text)

    def test_central_endpoints_read_group_vars(self):
        text = "\n".join(operations.central_endpoint_lines(Repository(REPO_ROOT)))
        self.assertIn("wg_hub_endpoint", text)
        self.assertNotIn("operation_wave", text.replace("operation_wave", "", 0))  # no secret/noise keys

    def test_central_readiness_reports_placeholders(self):
        text = "\n".join(operations.central_readiness_lines(
            Repository(REPO_ROOT), Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml")))
        self.assertIn("PLACEHOLDER", text)
        self.assertIn("[OK] Envanter", text)

    def test_state_whitelist_keeps_tokens_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"phase": "READY", "device_id": "BF-12010101",
                           "enrollment_token": "supersecret"}, handle)
            values = operations.state_values(path)
            self.assertEqual({"phase": "READY", "device_id": "BF-12010101"}, values)

    def test_state_lines_explain_a_missing_file(self):
        text = "\n".join(operations.state_lines("/nonexistent/state.json"))
        self.assertIn("kurulmamış olabilir", text)

    def test_environment_report_lists_the_console(self):
        text = "\n".join(operations.environment_lines(
            Repository(REPO_ROOT), "/tmp/x.log",
            Inventory.parse(SIMPLE_INVENTORY, path="hosts.yml"), dry_run=True, check_mode=False))
        self.assertIn("bfos {0}".format(config.VERSION), text)
        self.assertIn("dry-run               : evet", text)

    def test_endpoint_splitting(self):
        self.assertEqual(("vpn.example.com", 51820), operations.split_endpoint("vpn.example.com:51820"))
        self.assertEqual(("monitoring.example.com", 8428),
                         operations.split_endpoint("http://monitoring.example.com:8428"))
        self.assertEqual(("mirror.example.com", 80),
                         operations.split_endpoint("http://mirror.example.com/ubuntu"))
        self.assertEqual(("", None), operations.split_endpoint(""))

    def test_file_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "f")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("")
            os.chmod(path, 0o600)
            self.assertEqual("600", operations.file_mode(path))
            self.assertEqual("?", operations.file_mode(os.path.join(tmp, "missing")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
