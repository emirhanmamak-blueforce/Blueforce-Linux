# `migration/` — location pointer

This directory exists only as a **pointer**. The migration tooling is not here.

- **Actual location:** `scripts/migration/windows/`
  (`BF-WindowsPreMigrationInventory.ps1`, `BF-WindowsDataExport.ps1`, `README.md`)
- **Requested location:** `migration/windows/` (the layout the original brief
  described).

The repository keeps every operational script under `scripts/`
(`scripts/{install,maintenance,diagnostics,recovery,migration}`), so the Windows
pre-migration tooling lives in `scripts/migration/windows/` for consistency with
`blueforce-install.sh`, `bf-status`, `bf-hardware-inventory.sh` and the
diagnostics set. The same rule placed `bf-live-hw-check` under
`scripts/diagnostics/` instead of `scripts/live/`.

## Where to go

| Need | Path |
|---|---|
| Windows inventory / data-export scripts + full usage | `scripts/migration/windows/README.md` |
| Requested-name ↔ repo-name mapping table | `scripts/migration/windows/README.md` |
| Migration procedure, acceptance gate, rollback | `docs/28-WINDOWS-TO-LINUX-MIGRATION.md` |
| Location/name deviation audit entry (§B-6) | `docs/32-REPOSITORY-AUDIT-AND-CONFLICTS.md` |
| Post-migration read-only hardware gate | `scripts/diagnostics/bf-live-hw-check` |
| Static safety tests for the migration tooling | `tests/check-migration-static.sh` |

No script, wrapper or symlink is placed here on purpose: two real locations for
the same tooling would drift, and the static test asserts the single canonical
directory (`scripts/migration/windows/`).
