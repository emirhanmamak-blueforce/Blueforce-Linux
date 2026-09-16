#!/usr/bin/env bash
# Licensed-only AnyDesk exception placeholder. It deliberately installs nothing.
set -euo pipefail

if [[ "${ANYDESK_LICENSE_CONFIRMED:-}" != "true" ]]; then
  printf '%s\n' 'Refusing AnyDesk exception: set ANYDESK_LICENSE_CONFIRMED=true only after the per-device license approval is recorded.' >&2
  exit 2
fi

printf '%s\n' 'AnyDesk license confirmation acknowledged. This skeleton intentionally does not download, install, configure, or contain AnyDesk licensing material.'
printf '%s\n' 'Obtain the approved package and license through the organization’s controlled process; record the device exception outside the Blueforce installer.'
