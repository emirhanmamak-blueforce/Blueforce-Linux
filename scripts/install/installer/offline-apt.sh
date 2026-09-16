#!/usr/bin/env bash
# Shared local APT transaction helpers. Offline mode never reads remote sources.
set -euo pipefail

bf_apt() {
    if [[ "${BF_OFFLINE:-0}" == 1 ]]; then
        [[ -n "${BF_OFFLINE_APT_CONFIG:-}" && -r "${BF_OFFLINE_APT_CONFIG}" ]] || {
            printf 'Offline APT configuration is unavailable.\n' >&2
            return 1
        }
        APT_CONFIG="$BF_OFFLINE_APT_CONFIG" apt-get "$@"
    else
        apt-get "$@"
    fi
}

bf_require_offline_pin() {
    local package="$1"
    [[ "${BF_OFFLINE:-0}" != 1 ]] && return 0
    local pin
    pin="$(awk -F '\t' -v package="$package" '$1 == package {print $1 "=" $2; exit}' "${BF_OFFLINE_REPO}/packages.lock.tsv")"
    [[ -n "$pin" ]] || {
        printf 'Offline repository lacks required pinned package: %s\n' "$package" >&2
        return 1
    }
    printf '%s\n' "$pin"
}

bf_apt_install() {
    local packages=() package pin
    for package in "$@"; do
        if [[ "${BF_OFFLINE:-0}" == 1 ]]; then
            pin="$(bf_require_offline_pin "$package")" || return 1
            packages+=("$pin")
        else
            packages+=("$package")
        fi
    done
    bf_apt install -y "${packages[@]}"
}
