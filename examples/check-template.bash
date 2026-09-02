#!/usr/bin/env bash
# Minimal asgs-mon Bash check template.

source "${ASGS_MON_LIB:-${ASGS_MON_PLUGINDIR}/_bash-helper-functions.sh}"
mon_init "$@"

# Optional: run only on pass 1 and every 5th monitor pass.
# mon_every 5

mon_require_var RUNDIR

# Do one small check.
if [[ -e "$RUNDIR/something.bad" ]]; then
    mon_warning "something.bad exists" <<EOF
RUNDIR: $RUNDIR

Suggested Remedy:
Inspect the file and determine why it was created.
EOF
fi

# The first line is remembered and returned as OLDOUT / ASGS_MON_OLDOUT.
mon_ok "no-problem"
