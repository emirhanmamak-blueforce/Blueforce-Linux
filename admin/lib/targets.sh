#!/usr/bin/env bash
# admin/lib/targets.sh -- device identity, inventory parsing and target selection.
#
# Sourced by admin/bf-menu. Contains no UI rendering and no execution: it answers
# "which hosts does this operation apply to, and which Ansible --limit does that
# become".
#
# Contracts it enforces (sources of truth in parentheses):
#   * dealer number matches ^[0-9]{8}$ exactly (docs/02)
#   * machine hostname is bf-<dealer>, human id is BF-<dealer> (docs/02)
#   * waves are lab(2) -> pilot_1(5) -> pilot_2(20) -> wave_1(50) -> wave_2(100)
#     -> production, in that order (docs/10)
#   * the inventory is the Ansible inventory; no device is ever addressed that is
#     not in it (docs/09)
#
# Inputs (set by bf-menu before calling):
#   BF_REPO       repository root
#   BF_INVENTORY  resolved inventory path, or empty to trigger auto-discovery
#
# shellcheck shell=bash

# Canonical wave order. Kept in one place so the menu, the gate checks and the
# fleet-wide loop can never disagree.
BF_WAVES=(lab pilot_1 pilot_2 wave_1 wave_2 production)

# ---------------------------------------------------------------------------
# Identity helpers
# ---------------------------------------------------------------------------
# BF_DEALER_RE -- the single validation rule for dealer numbers.
BF_DEALER_RE='^[0-9]{8}$'

bf_dealer_validate() {
    [[ "$1" =~ $BF_DEALER_RE ]]
}

bf_dealer_to_host() {
    printf 'bf-%s\n' "$1"
}

bf_dealer_to_device_id() {
    printf 'BF-%s\n' "$1"
}

# bf_host_to_dealer HOST -> dealer number, empty when the name is not bf-<8 digits>.
bf_host_to_dealer() {
    local host="$1"
    if [[ "$host" =~ ^bf-([0-9]{8})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# bf_is_wave NAME -- true for the six approved wave groups (docs/10).
bf_is_wave() {
    local name="$1" wave
    for wave in "${BF_WAVES[@]}"; do
        [[ "$name" == "$wave" ]] && return 0
    done
    return 1
}

bf_waves_csv() {
    local IFS=,
    printf '%s\n' "${BF_WAVES[*]}"
}

# ---------------------------------------------------------------------------
# Inventory discovery and parsing
# ---------------------------------------------------------------------------
# bf_inventory_candidates -- every path we are willing to read, best first.
# hosts.example.yml is listed last on purpose: it is a template with example
# device IDs, so it is only usable after an explicit acknowledgement.
bf_inventory_candidates() {
    local dir="${BF_REPO:-.}/ansible/inventory"
    if [[ -n "${BF_INVENTORY:-}" ]]; then
        printf '%s\n' "$BF_INVENTORY"
        return 0
    fi
    printf '%s\n' \
        "$dir/hosts.yml" \
        "$dir/hosts.yaml" \
        "$dir/hosts" \
        "$dir/hosts.ini"
}

# bf_inventory_resolve -- pick the inventory file. Prints the path on success.
# Prints a remediation message to stderr and returns 1 when nothing is usable.
bf_inventory_resolve() {
    local candidate example="${BF_REPO:-.}/ansible/inventory/hosts.example.yml"
    if [[ -n "${BF_INVENTORY:-}" ]]; then
        if [[ -r "$BF_INVENTORY" ]]; then
            printf '%s\n' "$BF_INVENTORY"
            return 0
        fi
        tui_error "Inventory not readable: $BF_INVENTORY"
        tui_note  "Pass a real path with --inventory PATH or unset it to auto-discover." >&2
        return 1
    fi
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if [[ -r "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(bf_inventory_candidates)

    tui_error "No Ansible inventory found under ${BF_REPO:-.}/ansible/inventory/."
    # These remediation lines go to stderr on purpose: the resolver's stdout is
    # captured as the resolved path by the caller.
    if [[ -r "$example" ]]; then
        tui_note "Only the example inventory exists: $example" >&2
        tui_note "It carries example device IDs (bf-1201xxxx) and must not be used against real devices." >&2
        tui_note "Create the real inventory first:" >&2
        tui_note "  cp $example ${BF_REPO:-.}/ansible/inventory/hosts.yml" >&2
        tui_note "  \$EDITOR ${BF_REPO:-.}/ansible/inventory/hosts.yml" >&2
    else
        tui_note "Create ansible/inventory/hosts.yml with your bf-<8-digit dealer> hosts (docs/02, docs/09)." >&2
    fi
    return 1
}

# bf_inventory_pairs FILE -- "group<TAB>host" for every host in the inventory.
# A deliberately small YAML reader: the inventory is a nested map of
# all.children.<group>.children.<wave>.hosts.<hostname>. It tracks indentation
# instead of pulling in a YAML parser (none is guaranteed on a field console).
bf_inventory_pairs() {
    local inv="$1"
    [[ -r "$inv" ]] || return 1
    awk '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function unquote(s) { gsub(/^["\x27]|["\x27]$/, "", s); return s }
        {
            line = $0
            if (line ~ /^[[:space:]]*#/) next
            if (line ~ /^[[:space:]]*$/) next
            if (line ~ /^[[:space:]]*-/) next
            if (line !~ /:/) next

            match(line, /^ */); ind = RLENGTH
            key = line; sub(/^[[:space:]]*/, "", key); sub(/:.*$/, "", key)
            key = unquote(trim(key))
            val = line; sub(/^[^:]*:/, "", val); val = trim(val)
            if (key == "") next

            while (depth > 0 && sind[depth] >= ind) depth--

            # A "hosts:" block owns the nearest enclosing group key.
            if (key == "hosts" && val == "") {
                h_active = 1; h_ind = ind; h_step = 0
                h_grp = (depth > 0) ? skey[depth] : ""
                skey[++depth] = key; sind[depth] = ind
                next
            }
            # Anything at or above the "hosts:" indentation ends that block.
            if (h_active && ind <= h_ind) h_active = 0

            if (h_active && ind > h_ind) {
                if (h_step == 0) h_step = ind
                if (ind == h_step) {
                    print h_grp "\t" key
                    skey[++depth] = key; sind[depth] = ind
                    next
                }
            }
            if (val == "") { skey[++depth] = key; sind[depth] = ind }
        }
    ' "$inv"
}

# Reads the inventory and caches the pairs; repeated calls are cheap and the
# cache is invalidated by BF_INVENTORY_CACHE_FILE going away.
bf_inventory_cache() {
    local inv="${BF_INVENTORY:-}"
    [[ -n "$inv" ]] || return 1
    if [[ -z "${BF_INVENTORY_CACHE_FILE:-}" ]]; then
        BF_INVENTORY_CACHE_FILE="$(mktemp "${TMPDIR:-/tmp}/bf-inventory.XXXXXX")"
        export BF_INVENTORY_CACHE_FILE
    fi
    if [[ ! -s "$BF_INVENTORY_CACHE_FILE" ]]; then
        bf_inventory_pairs "$inv" >"$BF_INVENTORY_CACHE_FILE" || return 1
    fi
    return 0
}

bf_inventory_groups() {
    bf_inventory_cache || return 1
    awk -F '\t' 'NF == 2 && !seen[$1]++ { print $1 }' "$BF_INVENTORY_CACHE_FILE" | grep -v '^$' || true
}

bf_inventory_hosts() {
    bf_inventory_cache || return 1
    awk -F '\t' 'NF == 2 && !seen[$2]++ { print $2 }' "$BF_INVENTORY_CACHE_FILE" | grep -v '^$' || true
}

bf_inventory_hosts_of_group() {
    local group="$1"
    bf_inventory_cache || return 1
    awk -F '\t' -v g="$group" '$1 == g { print $2 }' "$BF_INVENTORY_CACHE_FILE"
}

# bf_count_lines -- wc -l without the set -e trap of grep -c returning 1 on zero.
bf_count_lines() {
    local n
    n="$(printf '%s\n' "$1" | grep -c . || true)"
    printf '%s\n' "${n:-0}"
}

bf_inventory_group_exists() {
    local group="$1"
    bf_inventory_cache || return 1
    awk -F '\t' -v g="$group" '$1 == g { found = 1; exit } END { exit !found }' "$BF_INVENTORY_CACHE_FILE"
}

bf_inventory_host_exists() {
    local host="$1"
    bf_inventory_cache || return 1
    awk -F '\t' -v h="$host" '$2 == h { found = 1; exit } END { exit !found }' "$BF_INVENTORY_CACHE_FILE"
}

bf_inventory_count_all() {
    bf_count_lines "$(bf_inventory_hosts || true)"
}

# bf_inventory_host_wave HOST -- the approved wave that contains HOST.
# Prints nothing and returns 1 when the device sits outside every wave group.
bf_inventory_host_wave() {
    local host="$1" wave
    bf_inventory_cache || return 1
    for wave in "${BF_WAVES[@]}"; do
        bf_inventory_group_exists "$wave" || continue
        if bf_inventory_hosts_of_group "$wave" | grep -qx -- "$host"; then
            printf '%s\n' "$wave"
            return 0
        fi
    done
    return 1
}

# bf_wave_groups_present -- canonical waves that actually exist in the inventory,
# always in rollout order.
bf_wave_groups_present() {
    local wave
    for wave in "${BF_WAVES[@]}"; do
        if bf_inventory_group_exists "$wave"; then
            printf '%s\n' "$wave"
        fi
    done
}

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------
bf_target_reset() {
    BF_TARGET_KIND=""
    BF_TARGET_LIMIT=""
    BF_TARGET_WAVE=""
    BF_TARGET_LABEL=""
    BF_TARGET_COUNT=0
}

bf_target_is_set() {
    [[ -n "${BF_TARGET_KIND:-}" && -n "${BF_TARGET_LIMIT:-}" ]]
}

# bf_target_set_host DEALER [MODE]
# MODE: any|wave|release. Returns 1 (after explaining) when the mode forbids a
# single-device selection or the device is unknown to the inventory.
bf_target_set_host() {
    local dealer="$1" mode="${2:-any}" host wave
    if ! bf_dealer_validate "$dealer"; then
        tui_error "Invalid dealer number '$dealer': it must match ${BF_DEALER_RE} (8 digits, no spaces)."
        return 1
    fi
    if [[ "$mode" == "release" ]]; then
        tui_error "Release-gated operations are wave-scoped (docs/10): select a wave group, not a single device."
        return 1
    fi
    host="$(bf_dealer_to_host "$dealer")"
    if ! bf_inventory_host_exists "$host"; then
        tui_error "$host is not in the inventory (${BF_INVENTORY:-unresolved})."
        tui_note  "Add the device to its wave group first, then retry (see admin/README.md, docs/02)."
        return 1
    fi
    wave="$(bf_inventory_host_wave "$host" || true)"
    if [[ -z "$wave" && "$mode" != "any" ]]; then
        tui_error "$host is not inside an approved wave group ($(bf_waves_csv))."
        tui_note  "Wave-scoped playbooks refuse a device that no wave covers (fail-closed)."
        return 1
    fi
    BF_TARGET_KIND="host"
    BF_TARGET_LIMIT="$host"
    BF_TARGET_WAVE="$wave"
    BF_TARGET_COUNT=1
    if [[ -n "$wave" ]]; then
        BF_TARGET_LABEL="device $(bf_dealer_to_device_id "$dealer") ($host) in wave '$wave'"
    else
        BF_TARGET_LABEL="device $(bf_dealer_to_device_id "$dealer") ($host)"
    fi
    return 0
}

# bf_target_set_group GROUP [MODE]
bf_target_set_group() {
    local group="$1" mode="${2:-any}" count
    if [[ "$group" == "all" ]]; then
        bf_target_set_all "$mode"
        return $?
    fi
    if ! bf_inventory_group_exists "$group"; then
        tui_error "Group '$group' is not in the inventory (${BF_INVENTORY:-unresolved})."
        tui_note  "Known groups: $(bf_inventory_groups | tr '\n' ' ')"
        return 1
    fi
    if [[ "$mode" == "wave" || "$mode" == "release" ]] && ! bf_is_wave "$group"; then
        tui_error "Group '$group' is not an approved wave; wave-scoped operations need one of: $(bf_waves_csv)."
        return 1
    fi
    count="$(bf_count_lines "$(bf_inventory_hosts_of_group "$group" || true)")"
    if [[ "$count" -eq 0 ]]; then
        tui_error "Group '$group' contains no hosts; refusing an empty target."
        return 1
    fi
    BF_TARGET_KIND="group"
    BF_TARGET_LIMIT="$group"
    BF_TARGET_WAVE="$group"
    # shellcheck disable=SC2034  # read by bf-menu (library contract)
    BF_TARGET_COUNT="$count"
    if bf_is_wave "$group"; then
        BF_TARGET_LABEL="wave '$group' ($count device(s))"
    else
        BF_TARGET_LABEL="group '$group' ($count device(s))"
    fi
    return 0
}

# bf_target_set_all MODE -- the whole fleet.
# For release-gated operations this is refused: the update/reboot playbooks are
# gated wave by wave and a fleet-wide limit would defeat the gate (docs/10).
bf_target_set_all() {
    local mode="${1:-any}" count
    if [[ "$mode" == "release" ]]; then
        tui_error "Fleet-wide scope is refused for release-gated operations: roll out one wave at a time (docs/10)."
        return 1
    fi
    count="$(bf_inventory_count_all)"
    if [[ "$count" -eq 0 ]]; then
        tui_error "The inventory lists no hosts; refusing an empty target."
        return 1
    fi
    BF_TARGET_KIND="all"
    BF_TARGET_LIMIT="all"
    BF_TARGET_WAVE=""
    # shellcheck disable=SC2034  # read by bf-menu (library contract)
    BF_TARGET_COUNT="$count"
    BF_TARGET_LABEL="all devices in the fleet ($count device(s))"
    return 0
}

# bf_target_parse WORD MODE -- accept what the operator typed in one prompt:
# an 8-digit dealer number, a group/wave name, or "all".
bf_target_parse() {
    local word="$1" mode="${2:-any}"
    bf_target_reset
    if [[ -z "$word" ]]; then
        tui_error "No target given."
        return 1
    fi
    if [[ "$word" == "all" ]]; then
        bf_target_set_all "$mode"
        return $?
    fi
    if bf_dealer_validate "$word"; then
        bf_target_set_host "$word" "$mode"
        return $?
    fi
    if bf_inventory_group_exists "$word"; then
        bf_target_set_group "$word" "$mode"
        return $?
    fi
    # A bf-<dealer> hostname is accepted as a convenience.
    if [[ "$word" =~ ^bf-[0-9]{8}$ ]]; then
        if bf_dealer_validate "${word#bf-}"; then
            bf_target_set_host "${word#bf-}" "$mode"
            return $?
        fi
    fi
    tui_error "'$word' is not a dealer number (${BF_DEALER_RE}), a group, or 'all'."
    tui_note  "Known groups: $(bf_inventory_groups | tr '\n' ' ')"
    return 1
}

# bf_target_describe -- one line for the confirmation screen.
bf_target_describe() {
    printf '%s --limit %s%s\n' "${BF_TARGET_LABEL:-unset}" "${BF_TARGET_LIMIT:-unset}" \
        "$([[ -n "${BF_TARGET_WAVE:-}" ]] && printf ' (wave %s)' "$BF_TARGET_WAVE")"
}

# bf_target_select MODE
# Interactive target picker. MODE:
#   any      single device, any group, or the whole fleet
#   wave     single device, approved wave group, or the whole fleet wave by wave
#   release  approved wave group only
# On success the BF_TARGET_* globals describe the selection.
bf_target_select() {
    local mode="${1:-any}" choice word count index group_list=()
    bf_target_reset
    while true; do
        tui_section "Target selection (mode: $mode)"
        tui_item 1 "Single device by dealer number" "8 digits, e.g. 12010101"
        tui_item 2 "Group / wave" "lab, pilot_1, pilot_2, wave_1, wave_2, production"
        if [[ "$mode" == "release" ]]; then
            tui_note "   all) not offered: release-gated operations run one wave at a time"
        else
            tui_item 3 "All devices in the fleet" "wave-scoped playbooks ask per wave"
        fi
        tui_item 9 "Type the target directly" "dealer number, group or 'all'"
        tui_footer "Back to the operation"
        printf '\n'
        if ! tui_read "Target > "; then return 1; fi
        choice="$TUI_REPLY"
        case "$choice" in
            ""|0|q|Q) return 1 ;;
            1)
                tui_read "Dealer number (8 digits) > " || return 1
                word="$TUI_REPLY"
                bf_target_set_host "$word" "$mode" && return 0
                ;;
            2)
                tui_section "Groups in the inventory"
                group_list=()
                while IFS= read -r group; do
                    [[ -n "$group" ]] || continue
                    group_list+=("$group")
                done < <(if [[ "$mode" == "any" ]]; then bf_inventory_groups || true; else bf_wave_groups_present || true; fi)
                if [[ ${#group_list[@]} -eq 0 ]]; then
                    tui_error "No usable group in the inventory (${BF_INVENTORY:-unresolved})."
                    return 1
                fi
                index=0
                for group in "${group_list[@]}"; do
                    index=$((index + 1))
                    count="$(bf_count_lines "$(bf_inventory_hosts_of_group "$group" || true)")"
                    if bf_is_wave "$group"; then
                        tui_item "$index" "$group" "$count device(s), approved wave"
                    else
                        tui_item "$index" "$group" "$count device(s)"
                    fi
                done
                printf '\n'
                tui_note "Approved waves: $(bf_waves_csv) -- source: $(basename "${BF_INVENTORY:-unresolved}")"
                if ! tui_read "Group number > "; then return 1; fi
                choice="$TUI_REPLY"
                if ! tui_menu_index "$choice" "$index"; then
                    tui_error "Enter a number between 1 and $index."
                    continue
                fi
                bf_target_set_group "${group_list[$((choice - 1))]}" "$mode" && return 0
                ;;
            3)
                if [[ "$mode" == "release" ]]; then
                    tui_error "Fleet-wide scope is refused here."
                    continue
                fi
                bf_target_set_all "$mode" && return 0
                ;;
            9)
                tui_read "Target (dealer number, group or all) > " || return 1
                bf_target_parse "$TUI_REPLY" "$mode" && return 0
                ;;
            *) tui_error "Unknown choice '$choice'." ;;
        esac
        printf '\n'
        tui_pause
    done
}
