# Semaphore Community limits (working rules for the Blueforce fleet)

Source: `docs/09-FLEET-MANAGEMENT.md` section 9, "Semaphore Community sinirlari".
This file restates the limits in English as an executable checklist for
playbook authors and Semaphore operators. No Pro/Enterprise feature may be
used anywhere in `ansible/` or in any Semaphore task template.

## Limits

1. No OIDC/SSO: Semaphore users are local accounts; access only behind WireGuard.
2. No 2FA: password policy + mandatory VPN compensates; admin accounts are inventoried.
3. No external Vault integration: secrets live in the Semaphore built-in encrypted
   Key Store; production secrets are never embedded in playbooks.
4. Concurrency limits (runners/forks): load-test against 700 nodes first, then tune
   runner count + Ansible `serial`/`forks`/batch settings. Destructive playbooks
   (`bf-reboot.yml`, `bf-deploy-update.yml`) already enforce `serial` +
   `max_fail_percentage: 0` + `any_errors_fatal: true`.
5. No workflow may depend on a Pro-only feature. Anything that does not run on
   Community is rejected in review (`tests/check-specs.sh` greps for it).

## Operator checklist

- [ ] Semaphore reachable only via WireGuard.
- [ ] Every destructive template runs `--check` dry run + `--limit <wave>` first.
- [ ] Waves follow docs/10: lab(2) -> pilot-1(5) -> pilot-2(20) -> wave-1(50) -> wave-2(100) -> production.
- [ ] Secrets referenced from Key Store, never committed to Git.
- [ ] `tests/check-specs.sh` and `tests/check-configs.sh` pass before merge.
