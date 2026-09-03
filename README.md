# asgs-mon

Vigilant watchdog of ASGS.

`asgs-mon` is an operator-oriented companion to the ADCIRC Surge Guidance
System (ASGS). It is deliberately small: the supervisor does orchestration,
state handling, process validation, notification limiting, and result export;
individual checks remain short executable programs.

The normal operating model is still the one that works well in production:
run ASGS in one tmux pane and `asgs-mon` in the pane beside it.

```text
+----------------------------------+----------------------------------+
| ASGS / asgs_main.sh              | asgs-mon                         |
|                                  |                                  |
| normal ASGS progress             | process / state / queue / logs   |
|                                  | warnings and notifications       |
+----------------------------------+----------------------------------+
```

## ASGS integration contract

Load the ASGS profile first. `asgs-mon` treats the profile as authoritative:

* `_ASGSH_CURRENT_PROFILE` identifies the profile;
* `ASGS_CONFIG` identifies the ASGS instance;
* `STATEFILE` supplies changing runtime state;
* `SCRIPTDIR` identifies the ASGS installation.

`asgs-mon` no longer tries to invent an independent configuration identity.
It validates that the selected `asgs_main.sh` process belongs to the current
`ASGS_CONFIG`, and it refreshes the state file every monitor pass.

The current dynamic values are exported to checks as `ASGS_MON_*` variables,
including `ASGS_MON_RUNDIR`, `ASGS_MON_SYSLOG`, `ASGS_MON_ADVISORY`,
`ASGS_MON_INSTANCEFILE`, and `ASGS_MON_HOOKFILE`.

The original eight positional plugin arguments are retained for compatibility.

The normal ASGS Perl dependency set already includes `Util::H2O::More` and
`Dispatch::Fu`; this revision uses those existing ASGS dependencies rather than
adding a separate monitor-specific stack.

## Installation from ASGS

ASGS already supports:

```bash
fetch asgs-mon
```

which installs the repository under:

```text
$SCRIPTDIR/git/asgs-mon
```

and the ASGS shell includes `git/asgs-mon/bin` in `PATH`.

An optional ASGS-side integration patch is included under `integration/` to
also create the conventional `$SCRIPTDIR/bin/asgs-mon` symlink.

## Normal operator workflow

In tmux, split the window vertically.

In the ASGS pane:

```bash
load profile TXLA22a_GFS_queenbeec_be
run
```

In the monitor pane, load the same profile and start the monitor:

```bash
load profile TXLA22a_GFS_queenbeec_be
asgs-mon
```

The monitor follows the loaded profile rather than permanently following one
PID. `ASGS_CONFIG` is the durable instance identity. The supervisor discovers
the stable `asgs_main.sh -c <ASGS_CONFIG>` process, waits if it is temporarily
absent, and automatically adopts the new PID when the same profile is restarted.

## Command line

```text
asgs-mon [options]
asgs-mon --once
asgs-mon --check CHECK
asgs-mon --list
asgs-mon --enable CHECK
asgs-mon --disable CHECK
asgs-mon --validate
asgs-mon --status
```

Important options:

| Option | Meaning |
|---|---|
| `--delay SECONDS` | seconds between passes, default 10 |
| `--timeout SECONDS` | maximum runtime for one check, default 30 |
| `--hush SECONDS` | minimum repeat-notification interval, default 1800 |
| `--pid PID` | validate/use this PID initially; normal monitoring then continues to follow the profile |
| `--silent`, `-s` | suppress routine check status |
| `-v` | verbose operator output, default |
| `--trace` | print each check before execution |
| `--debug` | monitor execution diagnostics |
| `--no-notify` | run without email |
| `--global-config FILE` | override `~/asgs-global.conf` |
| `--once` | run one pass and exit |
| `--passes N` | run N passes and exit; useful for testing |
| `--check CHECK` | run one available check once, without email |
| `--validate` | check ASGS context, process, checks, and notification setup |
| `--status` | show the latest local status snapshot |

`--foreground` remains accepted for compatibility. Checks are already executed
synchronously.

## Turning checks on and off

Checks continue to use the familiar `available/` + `active/` model, but an
operator no longer needs to create symlinks manually.

List checks:

```bash
asgs-mon --list
```

Enable a check:

```bash
asgs-mon --enable 003
```

or:

```bash
asgs-mon --enable 003-syslog-progress
```

Disable it:

```bash
asgs-mon --disable 003
```

A running monitor rescans `active/` on every pass, so a check enabled or
disabled from another tmux pane takes effect on the next pass without
restarting `asgs-mon`.

The CLI only removes symlinks. It refuses to delete an active regular file,
which protects locally-created/custom checks.

## Default active checks

| Check | Purpose |
|---|---|
| `000-asgs_main-pid-check` | verifies the selected PID still belongs to this ASGS config |
| `006-rundir-du` | reports RUNDIR usage and change |
| `007-failed-dir` | reports `failed*` run directories |
| `009-syslog-scan` | shows lines added to SYSLOG; handles truncation/rotation |
| `010-STATEFILE` | validates current state and prints RUNDIR/advisory |
| `012-queue-check` | reports the operator's scheduler queue when supported |
| `700-ADCIRCLOG` | tails ADCIRC/SWAN progress logs in the current advisory |

Additional checks remain available but disabled by default.

## ATCF / tropical-cyclone sanity check

Version 0.2.2 includes a conservative, read-only ATCF timeline diagnostic. It
is available but **disabled by default** until it has been exercised across
more operational profiles.

Run it directly:

```bash
asgs-mon --check atcf
```

Enable it in the normal monitor:

```bash
asgs-mon --enable atcf
```

When `TROPICALCYCLONE` is not `on`, the check returns OK/not-applicable. For a
TC run it correlates three clocks:

```text
ATCF source/advisory clock
        -> ASGS scenario clock
        -> ADCIRC hotstart/model clock
```

The check uses the configured `GET_ATCF_SCRIPT`, `STORM`, `YEAR`, `TRIGGER`,
`RSSSITE`, `FTPSITE`, `FDIR`, and `HDIR`. Known ASGS adapters
`get_atcf.pl` and `get_atcf_http.pl` are invoked only in a private temporary
directory. If RSS processing requires `nhc_advisory_bot.pl`, that conversion is
also performed only in the sandbox. Nothing is downloaded into the active
`RUNDIR`, state is never advanced, and no replay-control action is invoked.
Unknown custom adapters are reported as UNKNOWN rather than executed blindly.
The remote probe runs approximately once per 60 seconds during normal monitoring
(`ASGS_MON_ATCF_INTERVAL` may override this); `asgs-mon --check atcf` always
performs a fresh probe. Local status remains available between probe passes.

The diagnostic inspects current ASGS state plus available `run.properties` and
`*.run-control.properties`. When a reused hotstart can be identified through
`LASTSUBDIR`, it reads `HSTIME` with the ADCIRC `hstime` utility when available
(or uses the current ASGS state value) and computes the corresponding ADCIRC
model time from `COLDSTARTDATE`.

High-confidence CRITICAL conditions include:

* configured/source storm identity mismatch or an unusable ATCF source;
* ATCF forecast end at or before the advisory/model start;
* scenario `RunEndTime` at or before `RunStartTime`;
* remaining ADCIRC integration time below one minute or at/below `2*dt`;
* a reused hotstart whose ADCIRC model clock is already ahead of the current
  ATCF advisory/model clock.

A hotstart produced under a different `ColdStartTime` is a WARNING. Intermediate
advisories are retained as distinct product identifiers (`002`, `002A`, etc.).
If the configured ASGS adapter reports only the numeric portion, the check
reports that precision limitation but does not invent equality or failure.

There is intentionally **no wall-clock freshness failure test**. A replay may
rebase all timestamps by one constant offset. The important invariants are
relative: forecast end must follow advisory/model time, scenario end must follow
scenario start, and the ADCIRC hotstart clock must be coherent with the current
advisory timeline.
The check also keeps a tiny monitor-owned observation history outside the active
`RUNDIR`. For a distinct next advisory, model time must move forward. The
history key includes `COLDSTARTDATE`, so a deliberate replay cycle rebase with
a new cold-start epoch starts a new comparison sequence.

The full structured ATCF assessment is attached to the normal status/adapter
JSON under the check's `details` object.

## Notification limiting

The old behavior could repeatedly send CRITICAL email every monitor pass.
The monitor now limits repeated notifications by check.

A notification is sent immediately when:

* a check transitions from OK to a non-OK state;
* severity escalates;
* the repeat-hush period has expired.

Repeated failures of the same severity are suppressed until the hush period
expires. A return to OK clears the failure transition state, so a later new
failure alerts immediately.

The default hush interval is 1800 seconds. Override it with:

```bash
asgs-mon --hush 900
```

or in `~/asgs-global.conf`:

```ini
[monitor]
notify_email=operator@example.org
hush_seconds=1800
```

`CRITICAL` is no longer allowed to generate email every ten seconds merely
because the process remains down.

## Process detection

The monitor does not use `ps | grep | awk` command strings.

On Linux it inspects `/proc/PID/cmdline` and structurally matches the actual
ASGS invocation:

```text
asgs_main.sh -c <canonical ASGS_CONFIG>
```

The config argument is compared as a canonical path rather than by basename or
substring. Because `/proc` is not an atomic snapshot and Bash can briefly expose
forked/subshell processes with the same argv, discovery revalidates candidates,
allows a short settling interval when multiple candidates are seen, and removes
descendants of another surviving candidate before declaring ambiguity.

`ASGS_CONFIG` is the persistent identity; the PID is transient. If no process is
running, `asgs-mon` remains alive in a waiting state. When ASGS is restarted from
a separate `asgsh` using the same profile/config, the monitor automatically
reacquires the new PID. A genuine set of multiple stable root candidates is
reported as ambiguous and retried rather than guessed.

`--pid` is an initial validated selection, useful for diagnostics; after startup
the normal monitor still follows the profile so it can survive a later restart.

A per-profile file lock prevents accidentally running two monitor supervisors
for the same ASGS configuration.

If ASGS is stopped and restarted with a new PID, `asgs-mon` remains attached to
the profile and follows the replacement process automatically.

## Check execution hardening

Checks are executed with list-form `exec`; plugin output is never interpolated
back into a shell command.

Each check has a timeout. A timed-out check is terminated and reported as
`UNKNOWN`, while the monitor continues to the remaining checks.

Unsupported exit codes and non-OK checks that produce no alert message are
converted to useful `UNKNOWN` results rather than generating empty email.

The supervisor preserves the traditional exit codes:

| Code | Status |
|---:|---|
| 0 | OK |
| 1 | WARNING |
| 2 | CRITICAL |
| 3 | UNKNOWN |
| 4 | NOTIFY |

## Bash check API

`available/_bash-helper-functions.sh` is now the supported include for Bash
checks.

A new check can be very small:

```bash
#!/usr/bin/env bash

source "${ASGS_MON_LIB:-${ASGS_MON_PLUGINDIR}/_bash-helper-functions.sh}"
mon_init "$@"

mon_require_var RUNDIR

if [[ -e "$RUNDIR/something.bad" ]]; then
    mon_warning "something.bad exists" <<EOF
RUNDIR: $RUNDIR

Suggested Remedy:
Inspect the file.
EOF
fi

mon_ok "no-problem"
```

Useful helpers include:

```text
mon_init
mon_verbose
mon_debug

mon_ok
mon_warning
mon_critical
mon_unknown
mon_notify

mon_every
mon_skip
mon_require_var
mon_require_cmd
mon_require_file
mon_require_dir
mon_have
mon_file_age
mon_human_age

get_instancefile
get_hookfile
```

`get_instancefile` and `get_hookfile` remain for compatibility, but they no
longer `source` the ASGS state file. The supervisor parses state and exports
the resolved paths instead.

### `mon_every`

Instead of repeating:

```bash
if [[ $COUNT != 1 && $((COUNT % 5)) != 0 ]]; then
    echo -n "$OLDOUT"
    exit 0
fi
```

a check can simply use:

```bash
mon_every 5
```

Skipped passes automatically preserve the previous first-line state.

## Plugin state

The original positional interface remains:

| Argument | Meaning |
|---|---|
| `$1` | previous first line (`OLDOUT`) |
| `$2` | previous exit code (`OLDEXIT`) |
| `$3` | monitor pass count |
| `$4` | monitor delay |
| `$5` | ASGS profile |
| `$6` | ASGS config |
| `$7` | state file |
| `$8` | verbosity |

New checks should prefer the environment where convenient:

```text
ASGS_MON_OLDOUT
ASGS_MON_OLDEXIT
ASGS_MON_COUNT
ASGS_MON_DELAY
ASGS_MON_VERBOSE
ASGS_MON_DEBUG

ASGS_MON_PROFILE
ASGS_MON_CONFIG
ASGS_MON_STATEFILE
ASGS_MON_PID

ASGS_MON_SCRIPTDIR
ASGS_MON_RUNDIR
ASGS_MON_SYSLOG
ASGS_MON_ADVISORY
ASGS_MON_LASTSUBDIR
ASGS_MON_HPCENV
ASGS_MON_HPCENVSHORT

ASGS_MON_INSTANCEFILE
ASGS_MON_HOOKFILE
```

## `Util::H2O::More` and `Dispatch::Fu`

The supervisor intentionally uses these conservatively.

`Util::H2O::More` continues to handle command-line options through
`Getopt2h2o`, ASGS global INI configuration through `ini2h2o`, and the small
runtime/action objects through `h2o`.

`Dispatch::Fu` is used for the top-level command dispatch (`monitor`, `list`,
`enable`, `disable`, `check`, `validate`, `status`). It replaces a growing
conditional command router without changing the check model.

Neither module is pushed into Bash checks or used merely to make simple code
more abstract.

## Local status and future dashboards

Every monitor pass writes two small, atomic JSON files in `ASGS_TMPDIR` (or
the system temporary directory):

* a heartbeat identifying the monitor/profile/PIDs;
* a status snapshot containing the latest result of each check.

`asgs-mon --status` reads the snapshot and prints a compact view. In a spare
tmux pane, a simple non-interactive at-a-glance view is also possible without
turning the monitor into a TUI:

```bash
watch -n 2 asgs-mon --status
```

This is also useful for external supervision: another service can determine
whether the heartbeat itself has gone stale, something a dead `asgs-mon`
process cannot report about itself.

### Structured check details

Checks may optionally write one JSON object to the temporary path supplied in
`ASGS_MON_RESULT_FILE`. The supervisor validates and consumes the file, removes
it immediately, and adds the object as `details` in the check's status snapshot
and adapter event. Existing checks do not need to use this facility. The
`atcf-sanity` check uses it so future dashboards can consume the same timeline
assessment shown to an operator.

### Adapter seam

`adapters/active/` is an optional export seam. No adapter is enabled by
default.

After each check, an active adapter receives a versioned JSON event as its
first argument. Adapter failures do not change the check result or stop the
monitor, and adapters have their own short timeout.

An example `adapters/available/jsonl-log` is included. The same event contract
can later be used by an HTTPS adapter that reports to a central web dashboard
without changing individual checks.

See `adapters/README.md`.

## Developing a check

Use:

```bash
asgs-mon --check 007
```

to run one available check once without sending email.

Then:

```bash
asgs-mon --enable 007
```

to place it into the live monitor set.

Templates are under `examples/`.

Keep checks focused on one condition. The supervisor owns orchestration,
notification policy, state refresh, process identity, timeouts, and adapters.

## Validation

Before an operational run:

```bash
asgs-mon --validate
```

It checks the loaded ASGS context, active check links/executability, matching
ASGS process, state-file availability, and notification configuration.

## Testing

Run:

```bash
prove -v t
```

and, when ShellCheck is installed:

```bash
shellcheck available/* examples/*.bash adapters/available/*
```

GitHub Actions CI is included.

## Issues

Please record issues in the ASGS issue tracker and use the `asgs-mon` label.
