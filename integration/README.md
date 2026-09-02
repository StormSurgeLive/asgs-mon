# ASGS-side integration

`asgs-mon` remains a separate repository and ASGS already installs/updates it
with `fetch asgs-mon`.

The included patch adds one conservative ASGS-side improvement: create
`$SCRIPTDIR/bin/asgs-mon` as a symlink to the fetched companion repository,
matching the style used for other first-class helper commands.

The monitor itself assumes the ASGS profile is already loaded and uses
`ASGS_CONFIG` as the instance identity.
