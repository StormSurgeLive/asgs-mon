# asgs-mon adapters

Adapters are an intentionally small extension point for exporting monitor
results to systems other than the operator terminal and email.

No adapter is required and none is enabled by default.

## Contract v1

For every completed check, `asgs-mon` builds a JSON event and invokes each
executable in `adapters/active/` with that JSON document as the first command
line argument.

An adapter:

* must treat the JSON as data, never shell code;
* should return quickly;
* must return exit status 0 on success;
* cannot change the check result;
* cannot stop the monitor;
* is terminated after `--adapter-timeout` seconds.

The event includes the schema version, host/platform/profile identity,
ASGS and monitor PIDs, current RUNDIR/advisory, check name, status, subject,
duration, and whether email was sent or suppressed.

This is intended to be the seam for a future HTTPS/web dashboard adapter.
A future web adapter can POST the same event without changing the checks.

## Example: JSONL log

`available/jsonl-log` appends each event to:

```text
$ASGS_MON_ADAPTER_LOG
```

or, if unset:

```text
$ASGS_TMPDIR/asgs-mon-events.jsonl
```

To experiment with it:

```bash
ln -s ../available/jsonl-log adapters/active/jsonl-log
export ASGS_MON_ADAPTER_LOG="$HOME/asgs-mon-events.jsonl"
asgs-mon
```

Remove the symlink to disable it.
