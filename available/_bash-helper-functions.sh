#!/usr/bin/env bash
#--------------------------------------------------------------------------
# _bash-helper-functions.sh - common API for asgs-mon Bash checks
#--------------------------------------------------------------------------
# Copyright(C) 2024-present Brett Estrade
# Copyright(C) 2024-present Jason Fleming
#
# This file is part of the ADCIRC Surge Guidance System (ASGS).
#--------------------------------------------------------------------------

# Do not set -e here: this file is sourced into checks, and monitoring checks
# frequently need to inspect commands that can legitimately return nonzero.
# Individual checks may opt into stricter shell behavior after mon_init.

# Stable check exit codes.
OK=0
WARNING=1
CRITICAL=2
UNKNOWN=3
NOTIFY=4

# Colors are safe for terminals, cron, CI, redirected output, and TERM=dumb.
BK= RD= GR= YW= BL= MG= CY= WH= R= B=
if [[ -t 2 && -n "${TERM:-}" && "${TERM}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    BK=$(tput setaf 0 2>/dev/null || true)
    RD=$(tput setaf 1 2>/dev/null || true)
    GR=$(tput setaf 2 2>/dev/null || true)
    YW=$(tput setaf 3 2>/dev/null || true)
    BL=$(tput setaf 4 2>/dev/null || true)
    MG=$(tput setaf 5 2>/dev/null || true)
    CY=$(tput setaf 6 2>/dev/null || true)
    WH=$(tput setaf 7 2>/dev/null || true)
    R=$(tput sgr0 2>/dev/null || true)
    B=$(tput bold 2>/dev/null || true)
fi

mon_init() {
    THIS=${THIS:-$(basename -- "$0")}

    # New API: the supervisor exports ASGS_MON_*.
    # Legacy API: preserve the original eight positional arguments.
    OLDOUT=${ASGS_MON_OLDOUT-${1-}}
    OLDEXIT=${ASGS_MON_OLDEXIT-${2-}}
    COUNT=${ASGS_MON_COUNT-${3-0}}
    DELAY=${ASGS_MON_DELAY-${4-10}}
    PROFILE=${ASGS_MON_PROFILE-${5-${_ASGSH_CURRENT_PROFILE-}}}
    CONFIGFILE=${ASGS_MON_CONFIG-${6-${ASGS_CONFIG-}}}
    STATEFILE=${ASGS_MON_STATEFILE-${7-${STATEFILE-}}}
    VERBOSE=${ASGS_MON_VERBOSE-${8-0}}

    RUNDIR=${ASGS_MON_RUNDIR-${RUNDIR-}}
    SYSLOG=${ASGS_MON_SYSLOG-${SYSLOG-}}
    ADVISORY=${ASGS_MON_ADVISORY-${ADVISORY-}}
    LASTSUBDIR=${ASGS_MON_LASTSUBDIR-${LASTSUBDIR-}}
    SCRIPTDIR=${ASGS_MON_SCRIPTDIR-${SCRIPTDIR-}}
    HPCENV=${ASGS_MON_HPCENV-${HPCENV-}}
    HPCENVSHORT=${ASGS_MON_HPCENVSHORT-${HPCENVSHORT-}}
    ASGS_PID=${ASGS_MON_PID-${ASGS_PID-}}
    INSTANCEFILE=${ASGS_MON_INSTANCEFILE-${INSTANCEFILE-}}
    HOOKFILE=${ASGS_MON_HOOKFILE-${HOOKFILE-}}

    COLORED_PROFILE="${CY}${PROFILE}${R}"
    export THIS OLDOUT OLDEXIT COUNT DELAY PROFILE CONFIGFILE STATEFILE VERBOSE
    export RUNDIR SYSLOG ADVISORY LASTSUBDIR SCRIPTDIR HPCENV HPCENVSHORT ASGS_PID
    export INSTANCEFILE HOOKFILE COLORED_PROFILE
}

mon_verbose() {
    [[ "${VERBOSE:-0}" == 1 ]] || return 0
    printf '%s\n' "$*" >&2
}

mon_debug() {
    [[ "${ASGS_MON_DEBUG:-0}" == 1 ]] || return 0
    printf 'DEBUG(%s): %s\n' "${THIS:-check}" "$*" >&2
}

mon_subject() {
    local level=$1
    shift
    printf '(%s %s - %s) %s %s' \
        "${HPCENVSHORT:-unknown}" "${PROFILE:-unknown}" "${THIS:-check}" "$level" "$*"
}

# Emit an alert using the asgs-mon mail contract:
#   first line = subject
#   second line = blank
#   remaining lines = body
# Body is read from stdin, making heredocs natural:
#
#   mon_warning "thing failed" <<EOF
#   Details...
#   EOF
mon_alert() {
    local code=$1
    local level=$2
    local subject=$3
    printf '%s\n\n' "$(mon_subject "$level" "$subject")"
    cat
    exit "$code"
}

mon_warning()  { local s=$1; mon_alert "$WARNING"  WARNING  "$s"; }
mon_critical() { local s=$1; mon_alert "$CRITICAL" CRITICAL "$s"; }
mon_unknown()  { local s=$1; mon_alert "$UNKNOWN"  UNKNOWN  "$s"; }
mon_notify()   { local s=$1; mon_alert "$NOTIFY"   NOTICE   "$s"; }

# Return OK while preserving a compact first-line state value for the next pass.
mon_ok() {
    printf '%s' "${1-}"
    exit "$OK"
}

# Skip a check except on pass 1 and every Nth pass. The previous first-line
# state is preserved automatically so skipped passes do not reset the check.
mon_every() {
    local n=$1
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        mon_unknown "invalid mon_every interval '$n'" <<EOF
The check itself supplied an invalid execution interval.
EOF
    fi
    if [[ "${COUNT:-0}" != 1 ]] && (( COUNT % n != 0 )); then
        mon_ok "${OLDOUT-}"
    fi
}

mon_require_var() {
    local name=$1
    local value=${!name-}
    if [[ -z "$value" ]]; then
        mon_unknown "required monitor value $name is not available" <<EOF
The loaded ASGS profile/state did not provide $name.
EOF
    fi
}

mon_require_file() {
    local path=$1
    local label=${2:-file}
    if [[ -z "$path" || ! -r "$path" ]]; then
        mon_unknown "$label is not readable" <<EOF
Expected: ${path:-<undefined>}
EOF
    fi
}

mon_require_dir() {
    local path=$1
    local label=${2:-directory}
    if [[ -z "$path" || ! -d "$path" ]]; then
        mon_unknown "$label is not available" <<EOF
Expected: ${path:-<undefined>}
EOF
    fi
}

mon_have() {
    command -v "$1" >/dev/null 2>&1
}

# Skip intentionally, preserving the previous state value. Useful for checks
# that are not applicable on a particular scheduler/platform.
mon_skip() {
    mon_verbose "(${HPCENVSHORT:-unknown} ${COLORED_PROFILE:-${PROFILE:-unknown}} - ${THIS:-check}) skipped: $*"
    mon_ok "${OLDOUT-}"
}

mon_require_cmd() {
    local cmd=$1
    if ! mon_have "$cmd"; then
        mon_unknown "required command '$cmd' is not available" <<EOF
The check requires '$cmd', but it is not present in PATH.
EOF
    fi
}

# GNU stat is available on the Linux systems supported by ASGS.
mon_file_age() {
    local path=$1
    local now mtime
    [[ -e "$path" ]] || return 1
    now=$(date +%s) || return 1
    mtime=$(stat -c %Y -- "$path" 2>/dev/null) || return 1
    printf '%s' "$(( now - mtime ))"
}

mon_human_age() {
    local seconds=${1:-0}
    if (( seconds < 60 )); then
        printf '%d seconds' "$seconds"
    elif (( seconds < 3600 )); then
        printf '%d minutes' "$(( seconds / 60 ))"
    elif (( seconds < 86400 )); then
        printf '%d hours' "$(( seconds / 3600 ))"
    else
        printf '%d days' "$(( seconds / 86400 ))"
    fi
}

# Backward-compatible helpers. They no longer source/evaluate STATEFILE.
get_instancefile() {
    if [[ -n "${ASGS_MON_INSTANCEFILE:-}" ]]; then
        printf '%s\n' "$ASGS_MON_INSTANCEFILE"
    elif [[ -n "${RUNDIR:-}" ]]; then
        printf '%s\n' "$RUNDIR/status/asgs.instance.status.json"
    fi
}

get_hookfile() {
    if [[ -n "${ASGS_MON_HOOKFILE:-}" ]]; then
        printf '%s\n' "$ASGS_MON_HOOKFILE"
    elif [[ -n "${RUNDIR:-}" ]]; then
        printf '%s\n' "$RUNDIR/status/hook.status.json"
    fi
}
