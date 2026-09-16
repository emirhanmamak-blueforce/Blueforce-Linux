"""Command execution and the audit log for the bfos console.

Separation of duties:

  * :mod:`bfos.operations` decides *what* may run and produces an argv list,
  * this module decides *whether* it runs (confirmation, dry-run, check mode),
    executes it with :mod:`subprocess`, reports the exit code, and writes the
    audit record.

Guarantees kept from the bash console (``admin/bf-menu``):

  * the command is always printed **before** it is confirmed and run,
  * ``--dry-run`` executes nothing at all,
  * the audit log is mode 600 (directories 700) and falls back to
    ``$XDG_STATE_HOME/blueforce/`` when ``/var/log`` is not writable,
  * no secret reaches the log: a single sanitizer redacts
    ``password=``/``token=``/``secret=``/``api_key=``/``private_key=``/``psk=``
    style values and whole PEM blocks,
  * raw command output is shown on screen and never copied into the log.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Sequence

from . import config

# ---------------------------------------------------------------------------
# Secret redaction -- the single choke point before anything is logged
# ---------------------------------------------------------------------------
_SECRET_KEY = r"(?:password|passwd|passphrase|secret|token|api[_-]?key|private[_-]?key|preshared[_-]?key|psk|credential)"
_SECRET_ASSIGN_RE = re.compile(
    r"((?:" + _SECRET_KEY + r")[A-Za-z0-9_.-]*\s*[=:])\s*(\S+)",
    re.IGNORECASE,
)
_PEM_LINE_RE = re.compile(r"BEGIN [A-Z0-9 ]*PRIVATE KEY")
_PEM_BLOCK_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)

REDACTED = "<redacted>"


def redact(text: str) -> str:
    """Return TEXT with secret-looking values and PEM blocks removed.

    Deliberately blunt: log records are written for every command, so the
    sanitizer must be safe for text that was never meant to be a secret. A PEM
    header without its matching footer (truncated line, interrupted paste) is
    treated as the start of a secret: everything from the header on is dropped,
    because a half-copied key is still a key.
    """
    if not text:
        return text
    cleaned = _PEM_BLOCK_RE.sub(REDACTED, text)
    header = _PEM_LINE_RE.search(cleaned)
    if header:
        cleaned = cleaned[:header.start()] + REDACTED
    cleaned = _SECRET_ASSIGN_RE.sub(lambda match: match.group(1) + REDACTED, cleaned)
    return cleaned


# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------
def fallback_log_path(state_home: Optional[str] = None, home: Optional[str] = None) -> str:
    base = state_home or os.environ.get("XDG_STATE_HOME") or os.path.join(
        home or os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, *config.LOG_FALLBACK_SUBDIR)


def _prepare_log_file(path: str) -> bool:
    """Create or tighten PATH to mode 600; True when it is usable."""
    directory = os.path.dirname(path) or "."
    try:
        if os.path.exists(path):
            if not os.path.isfile(path) or not os.access(path, os.W_OK):
                return False
            os.chmod(path, config.LOG_FILE_MODE)
        else:
            if not os.path.isdir(directory):
                os.makedirs(directory, mode=config.LOG_DIR_MODE, exist_ok=True)
            if not os.access(directory, os.W_OK):
                return False
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, config.LOG_FILE_MODE)
            os.close(fd)
            os.chmod(path, config.LOG_FILE_MODE)
    except OSError:
        return False
    return _is_private(path)


def _is_private(path: str) -> bool:
    """True when only the owner can read the log (never log into a world-readable file)."""
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return False
    return (mode & 0o077) == 0


@dataclass
class AuditLog:
    """Append-only audit trail. Never receives raw command output."""

    requested: str = config.DEFAULT_LOG_FILE
    state_home: Optional[str] = None
    home: Optional[str] = None
    path: Optional[str] = None
    ready: bool = False
    warning: str = ""

    def initialise(self) -> None:
        for candidate in (self.requested, fallback_log_path(self.state_home, self.home)):
            if not candidate:
                continue
            if _prepare_log_file(candidate):
                self.path = candidate
                self.ready = True
                if candidate != self.requested:
                    self.warning = config.MSG_LOG_FALLBACK.format(
                        requested=self.requested, fallback=candidate
                    )
                return
        self.ready = False
        self.warning = config.MSG_LOG_NONE

    def write(self, level: str, message: str, timestamp: Optional[str] = None) -> None:
        if not self.ready or not self.path:
            return
        stamp = timestamp or _utc_now()
        record = "{0} [{1}] {2}\n".format(stamp, level, redact(message))
        try:
            with open(self.path, "a", encoding="utf-8") as handle:
                handle.write(record)
        except OSError:
            # A failing log must never break an operator's session.
            self.ready = False


def _utc_now() -> str:
    import datetime

    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------
RUN_MODE_RUN = "run"
RUN_MODE_CHECK = "check"
RUN_MODE_CANCEL = "cancel"


@dataclass
class RunResult:
    argv: List[str] = field(default_factory=list)
    executed: bool = False
    dry_run: bool = False
    check: bool = False
    cancelled: bool = False
    rc: Optional[int] = None
    signal_name: str = ""

    @property
    def ok(self) -> bool:
        return self.executed and self.rc == 0


def command_string(argv: Sequence[str]) -> str:
    """A copy/pasteable shell line (like ``printf %q`` in the bash console)."""
    return " ".join(shlex.quote(part) for part in argv)


def default_spawn(argv: Sequence[str]) -> int:
    """Run ARGV with inherited stdio and return its exit code."""
    try:
        completed = subprocess.run(list(argv), check=False)
        return completed.returncode
    except FileNotFoundError:
        return 127
    except PermissionError:
        return 126
    except KeyboardInterrupt:
        return 130


class Runner:
    """Show, confirm and execute commands; record every decision."""

    def __init__(
        self,
        console,
        audit: Optional[AuditLog] = None,
        dry_run: bool = False,
        check_mode: bool = False,
        spawn: Optional[Callable[[Sequence[str]], int]] = None,
    ) -> None:
        self.console = console
        self.audit = audit or AuditLog()
        self.dry_run = dry_run
        self.check_mode = check_mode
        self._spawn = spawn or default_spawn

    # -- helpers -----------------------------------------------------------
    def show_command(self, argv: Sequence[str], title: str = config.MSG_COMMAND_TITLE) -> str:
        printable = command_string(argv)
        self.console.section(title)
        self.console.write("   " + printable)
        self.console.write("")
        return printable

    def _check_flag(self, argv: List[str]) -> List[str]:
        if "--check" not in argv:
            return argv + ["--check"]
        return argv

    def _spawn_exit_code(self, argv: Sequence[str]) -> RunResult:
        try:
            rc = self._spawn(argv)
        except KeyboardInterrupt:
            return RunResult(argv=list(argv), executed=True, rc=130, signal_name="SIGINT")
        return RunResult(argv=list(argv), executed=True, rc=rc)

    # -- public API --------------------------------------------------------
    def run_readonly(self, argv: Sequence[str], title: str) -> RunResult:
        """Run a read-only tool: printed, not confirmed (mirrors bf_show_local_cmd)."""
        self.show_command(argv, title=title)
        if self.dry_run:
            self.console.warn(config.MSG_DRY_RUN_WARN)
            self.audit.write(config.AUDIT_DRYRUN, command_string(argv))
            return RunResult(argv=list(argv), dry_run=True)
        self.audit.write(config.AUDIT_RUN, command_string(argv))
        result = self._spawn_exit_code(argv)
        if result.rc == 0:
            self.audit.write(config.AUDIT_OK, "exit=0 :: " + command_string(argv))
        else:
            self.console.warn(config.MSG_RUN_FAIL.format(rc=result.rc))
            self.audit.write(config.AUDIT_FAIL, "exit={0} :: {1}".format(result.rc, command_string(argv)))
        return result

    def confirm_and_run(
        self,
        argv: Sequence[str],
        label: str,
        destructive: bool = False,
        check_mode: Optional[bool] = None,
    ) -> RunResult:
        """Print the command, ask, then run it (or cancel / dry-run)."""
        self.show_command(argv)
        if self.dry_run:
            self.console.warn(config.MSG_DRY_RUN_WARN)
            self.audit.write(config.AUDIT_DRYRUN, command_string(argv))
            return RunResult(argv=list(argv), dry_run=True)

        if destructive:
            self.console.warn(config.MSG_DESTRUCTIVE_WARN.format(label=label))
            self.console.warn(config.MSG_DESTRUCTIVE_SUB)

        mode = self.console.ask_run(config.MSG_RUN_ASK)
        if mode == RUN_MODE_RUN:
            final = list(argv)
        elif mode == RUN_MODE_CHECK:
            final = self._check_flag(list(argv))
            self.console.info(config.MSG_CHECK_MODE)
        else:
            self.console.info(config.MSG_CANCELLED_RUN)
            self.audit.write(config.AUDIT_CANCEL, "operatör iptal etti :: " + command_string(argv))
            return RunResult(argv=list(argv), cancelled=True)

        self.audit.write(config.AUDIT_RUN, command_string(final))
        result = self._spawn_exit_code(final)
        result.check = "--check" in final
        if result.rc == 0:
            self.console.ok(config.MSG_RUN_OK)
            self.audit.write(config.AUDIT_OK, "exit=0 :: " + command_string(final))
        else:
            self.console.error(config.MSG_RUN_FAIL.format(rc=result.rc))
            self.audit.write(config.AUDIT_FAIL, "exit={0} :: {1}".format(result.rc, command_string(final)))
        return result

    # -- checks ------------------------------------------------------------
    @staticmethod
    def have_ansible() -> bool:
        return _which("ansible-playbook") is not None

    @staticmethod
    def have_python() -> bool:
        return sys.version_info >= config.MIN_PYTHON

    @staticmethod
    def is_root() -> bool:
        return os.geteuid() == 0


def _which(name: str) -> Optional[str]:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None
