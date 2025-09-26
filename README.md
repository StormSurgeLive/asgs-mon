# asgs-mon 

Vigilant watchdog of ASGS.

## Usage

If you have not already done so, you will need to clone/install `asgs-mon` in your
existing ASGS installation using `fetch asgs-mon` at the `asgsh` prompt. Once
that is done, the command syntax to start it is as follows:

`asgs-mon --pid <ASGS_PID> [--delay N] [-v]`

This monitor is meant to be run inside of an ASGS Shell Environment (i.e., `asgsh`) and
expects there is a running `asgs_main.sh` to monitor. It expects that there
is also an `ASGS_CONFIG` defined and present.

1. start up ASGS instance (`run` command) in one terminal
2. most cases, run without options, in another terminal (be sure same profile
   is loaded)

The monitor is verbose by default. To silence and show only warnings, use the
`--silent` `-s` flag.

## Command Line Options

| Option | Meaning |
| ------ | ------- |
| `--debug` |        |
| `--delay SECONDS`  | Specify time increment between checks, default is 30 seconds |
| `--foreground`     | Runs each check in the foreground |
| `--help`           | Print this menu |
| `--pid PID`      | Specifies running ASGS process ID (not required) |
| `--silence`        | Turns off verbose mode (on by default) |
| `--trace`          | Prints check about to be performed |

## Introduction

`bin/asgs-mon` is a supervisory or watchdog program that is meant to be run
by Operators who wish to keep a vigilant eye on their ASGS instance.

## Using Existing Plugins

The main executable `bin/asgs-mon` does not do any checks. Instead it runs
any executable file that resides in the `active` subdirectory. So each "check"
must be a script or executable program that's been placed in that directory.

`asgs-mon` executes each script in the `active`
subdirectory, passing each one a fixed and identical set of parameters.
It also expects a certain range of meaningful exit codes. If you are familiar
with the **Nagios** monitoring tool, `asgs-mon` is modeled to work the same way.

Making a plugin "active" is done by creating an soft linke (`ln -s`) to the script you want to run. It doesn't
have to be in `./available`, but it probably will be. This is a similar model to how some web servers do it, so
the activation pattern is replicated here.

Many of the existing plugins in the table below are the artifacts of development and testing
and were created to explore possibilities within monitoring. The ones enabled by default
were found to actually be useful in production. 

| File Name                  | Description                                               | Enabled by Default |
|----------------------------|-----------------------------------------------------------|--------------------|
| 000-asgs_main-pid-check    | ensures asgs_main.sh is running with existing PID         | ✅                 |
| 001-instance-status-check  | confirm that valid `asgs.instance.status.json` exists; reports `time.status.lastupdated` but does not act on it | |
| 002-hook-status-check      | same as above but for the `hook.status.json` file         |                    |
| 003-syslog-progress        | reports time since `SYSLOG` was last updated; sends a WARNING message if it has been longer than 6 hours | |
| 004-instance-status-progress | same as above but for the `asgs.instance.status.json` file |                 |
| 005-hook-status-progress   | same as above but for the `hook.status.json` file         |                    |
| 006-rundir-du              | reports storage used in the current `RUNDIR` as well as change from last execution (runs every 5th execution of `asgs-mon`) | ✅ |
| 007-failed-dir             | detects `failed.*` directories in `RUNDIR` and notifies the Operator if one exists  | ✅ |
| 008-heart-beat             | sends an error if `asgs-mon` has not run in the past 3 hours |                 |
| 009-syslog-scan            | shows lines of `SYSLOG` added since last check            | ✅                 |
| 010-STATEFILE              | sanity check to ensure the `STATEFILE` has valid info (runs every 5th execution of `asgs-mon`) | ✅  |
| 012-queue-check            | displays `USER`'s queued or running jobs (runs every 5th execution of `asgs-mon`) | ✅ |
| 700-ADCIRCLOG              | reports the last 3 lines of all `adcirc.log` files and `asgs_swan.prt` files found in the `ADVISORY` directory specified in the `STATEFILE` | ✅ |
| 999-critical-test          | sends error email if `$ASGS_TMPDIR/.critical` file exists | |
| 999-notify-test            | same as above but for file named `.notify`                | |
| 999-warning-test           | same as above but for file named `.warning`               | |

## Creating New Plugins

Please look at what is in the `available` subdirectory. There are examples that use
Perl and Bash. Early experience is suggesting that plugins should favor being
created in Bash, and that Perl should only be considered if you only need the
power of it for things like processing JSON, communicating to webservers, etc.

In the case of plugins, simpler is better. They should be designed to do
one very specific check. And a good rule of thumb is that they should not
be more than 75 or 100 lines in length.

### Environmental Variables

In addition to all the variables available when an ASGS Profile is loaded,
`asgs-mon` adds the following:

| Variable | Meaning |
|--------- |---------|
|`ASGS_PID` |holds the operating system process ID of the `asgs_main.sh` that is listed in the `ps` output as running with the current `$ASGS_CONFIG`

### Plugin Command Line Options

It is best to take a look at the simpler checks that are written in `bash` to
get a clear understanding the options passed into each plugin scripts when they are
run.

| parameter | meaning | 
| --------- | ------- |
| `OLDOUT=$1` |  `asgs-mon` saves the first line of `STDOUT` for each check, on the next run it gets passed back |
| `OLDEXIT=$2` | the previous exit code is also saved and passed back |
| `COUNT=$3`   | iternation count of `asgs-mon`| 
| `DELAY=$4`    | number of seconds `asgs-mon` waits before checks| 
| `PROFILE=$5`   | this is the ASGS profile associated with this instance of `asgs-mon`|
| `CONFIGFILE=$6` | config file associated with the `$PROFILE` |
| `STATEFILE=$7` | path to the statefile associated with the `$PROFILE`|
| `VERBOSE=$8`  | value of the `-v` flag passed to `asgs-mon`, so the plugin can use it if needed |

Some of the variables are available in the environment. Bash scripts can
refer directly that's in `env` when `asgs-mon` is started. Similarly, Perl
scripts are able to inspect the `%ENV` hash.

However other things like the `HOOKFILE` and `INSTANCEFILE` need to be derived,
and being the main source of info for the initial checks, figuring out these
paths is better done by `asgs-mon` than the plugin.

`COUNT` and `DELAY` are there so that the plugin can decide to actually check at
an interval based on the check iteration count and/or the amount of time between
checks.

### Plugin Exit Codes and STDOUT

| Exit Code | Meaning |
| --------- | ------- | 
| `OK=0`     | everything is A-okay, no email sent |
| `WARNING=1` | something is not quite right, email alert sent |
| `CRITICAL=2`| something is very bad, email alert sent |
| `UNKNOWN=3` | unable to determine severity, email alert is sent |
| `NOTIFY=4`  | used for notification |

Ideally, all checks will be returning `OK` all the time.

As mentioned in the Command Line Options section above, `asgs-mon` passes in the first line of the `STDOUT`
received during the previous run of the plugin. This is to allow for a plugin to
have some sort of way to access the state of the previous plugin execution without
have to worry about private output files. `STDOUT` can be any number of lines,
but `asgs-mon` only really cares about the first line when the exit code or
status is `OK`. All warning messages or important information sent when it's
not `OK` should be directed to `STDOUT`. As we shall see in the next section,
`STDERR` is reserved internally for the plugin itself.

Any `STDOUT` that is printed by the plugin is handled as follows, given the status:

| STDOUT | Result |
| -------| -------|
| `OK`   | first line is stored and passed back to the plugin the next time it's run |
| anything else | the first line is saved like; then the entire body of what's printed via `STDOUT` is used to create the notification email, see below.

The notification email sent if the exit code or status code is not `OK` uses the
`STDOUT` as follows:

1. the first line is turned into the SUBJECT of the email
2. the second line is discarded (standard email, same as a git commit also)
3. everything else is sent as the BODY of the email

### Plugins and STDERR

`STDERR` is reserved for use by each plugin to print status messages to the
terminal. `asgs-mon` can be run in the background, but really it's meant to
run in the foreground within some view of the Operator. Email alerts are
there because an Op can't be there 24/7.

As illustrated in the Plugin Command Line Options section above, each plugin is passed in the value of the
"verbosity" that may be turned on when running `asgs-mon` using the `-v`
flag. The plugin may wish to respect that and it is recommended that it do
so. There are no shortage of cases where the plugin will output to `STDERR`
unconditionally, but this should be done sparingly to maintain a high
signal/noise ratio for any Op who is monitoring things on a terminal.

### Helper Libraries for Common Needs

Bash: `available/_bash-helper-functions.sh` 

`source $SCRIPTDIR/available/_bash-helper-functions.sh` 

Perl: `PERL/ASGSUtils.pm`

`use ASGSUtils;`
