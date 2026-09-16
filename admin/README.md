# Blueforce operator console (`bf-menu`)

Numbered terminal console for the Blueforce field fleet. One entry point for the
operator: no command has to be memorised, every command is printed before it
runs, and the dangerous ones ask twice.

Three layers, one screen:

| Layer | What it is | Where |
|---|---|---|
| Local install | This device, brought to the Field OS standard | category **1** |
| Fleet operations | The repository's existing Ansible playbooks, always with an explicit `--limit` | category **2** |
| Read-only information | Device and fleet state, no change anywhere | categories **3, 4, 5** |

The console is a thin front end. It does not reimplement installer logic, does
not invent playbooks, and does not talk to devices itself: it selects the right
`bf-*` tool, playbook and target, then executes exactly that.

---

## 1. Requirements

- Ubuntu LTS field device or admin workstation (the console is plain bash 4+).
- `git` for the checkout; `ansible-core`/`ansible` **only** on the machine that
  drives fleet operations (categories 2 and 3). A field device that only installs
  itself needs neither Ansible nor an inventory.
- `sudo` for category 1 (local install) and for writing to
  `/var/log/blueforce-console.log`.
- Optional, per category: `python3` (reads `state.json`), `wireguard-tools`
  (`wg`), `systemd`, `dpkg`.

## 2. Quick start

```bash
git clone <repository-url> Blueforce-Linux
cd Blueforce-Linux

sudo admin/bf-bootstrap.sh      # optional: links the tools into /usr/local/bin
sudo admin/bf-menu              # or: sudo bf-menu, once bootstrap ran
```

An install is `git`-based on purpose: the running revision is traceable with
`git log`, and the device identity (dealer number) is never baked into an image
— it is typed in the first console session. ISO/firstboot remain a secondary,
optional path (`docs/26`, `docs/27`).

Options:

```
-h, --help            usage
-V, --version         console version
    --repo PATH       repository root (default: parent of this script, symlinks resolved)
    --inventory PATH  Ansible inventory (default: <repo>/ansible/inventory/hosts.yml)
    --log-file PATH   audit log (default: /var/log/blueforce-console.log)
    --dry-run         print every command instead of running it
    --no-color        disable ANSI colors (NO_COLOR is honored too)
    --list            print the operation catalogue and exit (non-interactive)
    --list-targets    print inventory groups and host counts, then exit
```

Environment: `BF_REPO`, `BF_INVENTORY`, `BF_CONSOLE_LOG` mirror the options.

Exit status: `0` success or clean quit, `1` failure, `2` usage error.

## 3. Menu map

`0` is **Back** on every screen, `q` is **Quit** on every screen. The console
never changes anything from a menu that only displays information.

**1) Installation — this device, locally**

| # | Action | Under the hood |
|---|---|---|
| 1 | Pre-flight check | `blueforce-install.sh --dealer-id <no> --check` (writes nothing) |
| 2 | Install this device | `--dealer-id <no> [--offline] [--resume]` |
| 3 | Resume a failed run | `--dealer-id <no> --resume` |
| 4 | Run a single module | `--dealer-id <no> --only <NN-name>` |
| 5 | Show module state | `/var/lib/blueforce/install-state` |
| 6 | Show the installer log | `tail -n 40 /var/log/blueforce-install.log` |

Dealer numbers are validated against `^[0-9]{8}$` before anything runs; a wrong
format stops the flow immediately. Actions 2–4 require root and will say so.

**2) Device operations — the fleet, via Ansible**

*2.1 Read-only reports* (11 operations, nothing is changed):

| # | Operation | Playbook |
|---|---|---|
| 1 | Ping / reachability | `bf-ping.yml` |
| 2 | Uptime | `bf-uptime.yml` |
| 3 | Disk usage | `bf-disk-check.yml` |
| 4 | Docker status | `bf-docker-status.yml` |
| 5 | Package versions | `bf-package-check.yml` |
| 6 | Pending security updates | `bf-security-updates-check.yml` |
| 7 | Provisioning phase report | `bf-provisioning-status.yml` |
| 8 | Enrollment + central evidence | `bf-enrollment-status.yml` |
| 9 | Field OS version report | `bf-fieldos-version.yml` |
| 10 | Remote access channels | `bf-remote-channels-check.yml` |
| 11 | Offline readiness report | `bf-offline-ready-check.yml` |

*2.2 Maintenance* (10 operations, destructive ones ask twice):

| # | Operation | Playbook | Scope |
|---|---|---|---|
| 1 | Restart RDP | `bf-rdp-restart.yml` | simple |
| 2 | Restart RustDesk | `bf-rustdesk-restart.yml` | simple |
| 3 | Restart WireGuard | `bf-wireguard-restart.yml` | simple |
| 4 | Restart an allowlisted service | `bf-service-restart.yml` | simple |
| 5 | GUI off (headless) | `bf-gui-off.yml` | wave |
| 6 | GUI on (maintenance) | `bf-gui-on.yml` | wave |
| 7 | Collect logs / support bundle | `bf-collect-logs.yml` | wave |
| 8 | Run an approved script | `bf-run-script.yml` | wave |
| 9 | Controlled reboot | `bf-reboot.yml` | release |
| 10 | Deploy approved update | `bf-deploy-update.yml` | release |

*2.3 Show inventory targets* lists the waves with their device counts.

The console cross-checks its own table against the playbook file before running
(see §5); a playbook whose gates changed refuses to run rather than run ungated.

**3) Central (preparation)** — verifies and prepares central integration; it
installs no central component. Central readiness report (inventory, placeholders
in `group_vars/all.yml`, admin key path), configured endpoints, a read-only
DNS/TCP probe of those endpoints, the per-wave gate state, and the preparation
checklist.

**4) Tools** — `git pull --ff-only` of the checkout, environment/reference info,
the operation catalogue, the local gates (`bf-check-local`, `bf-check-enrollment`,
`bf-check-ready`), `bf-diagnostics`, `bf-live-hw-check`, `bf-remote-status --check`,
`bf-release`, `bf-hardware-inventory.sh`, `bf-support-bundle`, and the console's
own log.

**5) Device information** — identity (hostname, `BF-<no>`, dealer number),
`bf-status`, provisioning/enrollment state, network (addresses, routes, DNS,
WireGuard **peer counts and handshake ages**), disk/memory/CPU, installed pinned
packages, service status, recent journal errors, plus the fleet inventory summary
and a "resolve a target" helper that shows the exact `--limit` for copy/paste.

## 4. Target selection

Every device operation asks for a target first — never a default:

```
Target selection (mode: any|wave|release)
  1) Single device by dealer number   -> bf-<8 digits>
  2) Group / wave                     -> lab, pilot_1, pilot_2, wave_1, wave_2, production
  3) All devices in the fleet         -> --limit all
  9) Type the target directly         -> dealer number, group, hostname or 'all'
  0) Back    q) Quit
```

Rules the console enforces:

- **Single device** — the dealer number must match `^[0-9]{8}$` and the device
  must exist in the inventory. The wave is derived from the inventory, so a
  wave-scoped playbook gets `-e operation_wave=<its wave>`. A device outside
  every wave cannot be used for a wave-scoped operation.
- **Group / wave** — the group must exist in the inventory. For wave-scoped and
  release-gated operations only the six approved waves are offered.
- **All devices** — allowed for simple and wave-scoped playbooks. It shows how
  many devices are affected and requires typing `all` before anything runs. For
  wave-scoped playbooks the fleet is processed **one wave at a time** in
  `lab → pilot_1 → pilot_2 → wave_1 → wave_2 → production`, each wave shown and
  confirmed on its own, stopping at the first failure so no later wave is touched.
- **Release-gated playbooks** (`bf-reboot.yml`, `bf-deploy-update.yml`) accept an
  approved wave group only: no single device, no fleet-wide run. That is the
  playbooks' own gate (docs/10) and the console does not work around it.

## 5. What gets added to a command

The console derives the gate variables from the playbook file itself (its
non-comment lines), so the table in the menu can never silently drop a gate:

| Scope | Detected by | Variables added |
|---|---|---|
| `simple` | neither wave variable | only `--limit` |
| `wave` | uses `operation_wave` | `-e operation_wave=<wave> -e operation_confirmed=true`, plus `-e production_override=true` for the production wave |
| `release` | uses `release_wave` | `-e release_wave=<wave>`, `-e reboot_confirmed=true` / `-e wave_gate_confirmed=true` when the playbook declares them, plus the production override for the production wave |

Confirmations, in order:

1. the target and the full command are printed;
2. for `release` scope, the **wave gate** must be typed as `GATE` (the console
   never sets `wave_gate_confirmed=true` on its own — only after the previous
   wave's health gate and central approval, docs/10);
3. for the production wave, the word `production` must be typed;
4. for fleet-wide scope, the word `all` must be typed;
5. `y` runs, `c` runs with `--check` (dry run of the playbook), anything else cancels.

Extra variables are validated with the same rules the playbooks enforce, so the
operator gets a clear message instead of an Ansible assertion failure: package
pins must be `package=version`; service names must be in the playbook allowlist;
script paths must be inside `/opt/blueforce/bin` or `/usr/local/sbin`; the reboot
grace period must be a whole number of seconds.

## 6. Dry runs

- `--dry-run` prints every command and executes nothing.
- Answering `c` at the run prompt executes the command with `--check` appended,
  which is a real Ansible dry run.
- Category 1's pre-flight already is the installer's own `--check`.

## 7. Audit log

Default `/var/log/blueforce-console.log`, created with mode **600** (it is
re-`chmod`ed to 600 if it already exists). If it is not writable, the console
warns and falls back to `$XDG_STATE_HOME/blueforce/blueforce-console.log`; it
never logs into a world-readable file.

Each run records one line per event: session start, target, the exact command,
and the exit status. It does **not** store raw playbook output: tool output may
contain whatever a device script prints, and copying it into a log is how a
secret ends up on disk. Output is shown on screen and stays there.

Before anything reaches the log it passes a single sanitizer that redacts
`password=`, `token=`, `secret=`, `api_key=`, `private_key=`, `passphrase=`,
`psk=` and `BEGIN … PRIVATE KEY` payloads. The console itself never asks for a
secret: no password, token or private key is typed into or stored by it.

## 8. Security notes

- **No secret material is read, printed or logged.** The console never runs bare
  `wg show` (private and preshared keys stay off the screen) — only the listen
  port, peer count and handshake ages.
- **`state.json` is read through a whitelist** of non-secret keys (`phase`,
  `enrollment_status`, `fleet_status`, `device_id`, `provisioning_id`). A future
  token field cannot leak into the UI or the log.
- **No ungated update.** There is no `apt upgrade`, no `latest` pull and no
  free-form command anywhere in the menu; updates go through the release-gated
  playbook or not at all (docs/10).
- **Destructive actions ask twice**: a warning plus an explicit `y`, and the
  highest-risk scopes need a typed word (`GATE`, `production`, `all`, or the wave
  name in a fleet-wide loop).
- **Fail-closed on drift**: if the playbook's declared gates do not match the
  console's expectations, the console refuses to run that playbook at all.
- **Root is used where the underlying tool needs it** (local installer, support
  bundle). Read-only information screens are careful about what they read.
- The console **never edits the inventory**. Adding a device stays a reviewed
  edit of `ansible/inventory/hosts.yml`:

```yaml
        pilot_1:
          hosts:
            bf-12010193:
              ansible_host: 10.42.1.20
```

## 9. Deliberately out of scope

- **No distro/ISO build.** ISO and firstboot remain a secondary path (`docs/26`,
  `docs/27`); the primary install path is `git clone` + install. Category 4 does
  not offer `provisioning/iso/build-blueforce-iso.sh`.
- **No password generation.** Credential files are the separate, optional
  `admin/bf-creds` tool and default to **off**; the console does not call it.
- **No central server installation.** Category 3 verifies and prepares;
  installing the hub, monitoring or the token service is infrastructure work.
- **No new playbooks, no free-form commands.** If an operation is not one of the
  21 existing playbooks, the console does not fake it.

## 10. Troubleshooting

| Symptom | Why | What to do |
|---|---|---|
| `ansible-playbook was not found on this machine` | categories 2/3 need Ansible on the driving machine | `sudo apt install ansible` (or `pipx install ansible-core`), or run the command from another admin host |
| `No Ansible inventory found under …` | no `ansible/inventory/hosts.yml` yet | `cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml`, then fill in real `bf-<no>` hosts |
| Only `hosts.example.yml` exists | it holds example IDs and is never used automatically | copy it and replace the example devices |
| `Invalid dealer number '<x>'` | must be exactly 8 digits | type the number as printed on the device record, leading zeros included |
| `bf-<no> is not in the inventory` | the device is not registered | add it to the right wave group (§8), then retry |
| `… is not an approved wave` | a wave-scoped or release-gated operation got a non-wave group | pick one of `lab, pilot_1, pilot_2, wave_1, wave_2, production` |
| `Refusing to run <playbook>: the console expects scope …` | the playbook's gates changed since the console table was written | update `admin/bf-menu` before using that playbook |
| `This operation needs root on THIS device` | local install runs as root | `sudo bf-menu` |
| Log warning about `/var/log/blueforce-console.log` | not writable, another admin owns it, or the mode is wrong | run with `sudo`, or pass `--log-file <path>` |

## 11. Files

| File | Role |
|---|---|
| `admin/bf-menu` | entry point: menu screens, operation catalogue, command building, confirmations, audit log |
| `admin/lib/tui.sh` | presentation and input helpers (screens, items, prompts, confirmations, messages) |
| `admin/lib/targets.sh` | device identity, inventory parsing, target selection, `--limit` construction |

Library contract: `bf-menu` sets `BF_REPO`/`BF_INVENTORY` and sources both
libraries; `targets.sh` fills `BF_TARGET_KIND`, `BF_TARGET_LIMIT`,
`BF_TARGET_WAVE`, `BF_TARGET_COUNT`, `BF_TARGET_LABEL` and never renders UI or
executes anything; `tui.sh` never exits the process except in `tui_die`.

Both libraries are safe to source on their own, which is how the target logic and
the inventory parser can be tested without a terminal.

## 12. Verifying a change

```bash
bash -n admin/bf-menu admin/lib/tui.sh admin/lib/targets.sh
shellcheck -x admin/bf-menu admin/lib/tui.sh admin/lib/targets.sh
admin/bf-menu --list            # catalogue, no inventory needed
admin/bf-menu --list-targets    # groups, hosts and counts
```

`--list` and `--list-targets` are the non-interactive entry points: they exercise
the catalogue and the inventory parser without touching a device.

The console was checked on an admin workstation with a stub `ansible-playbook`
that echoes its arguments, covering: every scope/target combination and the exact
`-e` variables produced, the refusal paths (single device for release scope,
fleet-wide release run, wrong wave for a wave-scoped run, bad dealer number,
unknown device, bad package pin, service outside the allowlist, script outside
the approved directories, production/gate/fleet-wide words withheld), `--dry-run`
executing nothing, `--check` being appended, the missing-Ansible and
missing-inventory explanations, the log's 600 mode and its redaction of a test
secret, and clean EOF behaviour on a closed stdin. Playbook coverage was
cross-checked programmatically: all 21 playbooks in `ansible/playbooks/` appear
exactly once and every declared scope matches the playbook's own gate variables.
Real devices have not been touched yet — the LAB run is what turns these
expectations into evidence.
