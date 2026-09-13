# Omarchy Backup (bar widget)

An Omarchy shell bar-widget plugin: a theme-tinted status icon (colored dot
for GREEN/YELLOW/RED/UNKNOWN drift status) that opens a dialog with
snapshot/push/doctor actions and every setting of the
[`omarchy-backup`](https://github.com/mstio/omarchy-backup) CLI.

## Requires

The separate **`omarchy-backup` CLI** must be installed and on `PATH` --
this plugin only shells out to it (plus `jq`/`systemctl` for a couple of
read-only lookups). Without it, the icon still shows but the dialog reports
"omarchy-backup not found on PATH". See
[github.com/mstio/omarchy-backup](https://github.com/mstio/omarchy-backup)
for that tool and its own README.

## Install

```bash
omarchy plugin add https://github.com/mstio/mst.omarchy-backup --enable
```

## What it shows

- **Status**: drift color vs. your baseline, with a plain-language
  explanation and suggested next step for each state.
- **Actions**: Snapshot now / Mark latest as baseline / Push latest / Run
  doctor -- each backgrounded, with the result shown inline (e.g. how many
  files a snapshot skipped, or the exact reason `doctor` is DEGRADED).
- **Options**: every `omarchy-backup config.conf` key -- automatic
  backups on/off, snapshot/doctor frequency, the backup destination (a
  local/mounted folder path), remote retention, and the per-file size cap.

Never edits `config.conf` directly -- every change goes through
`omarchy-backup config set`, so the CLI and the widget can never disagree
about what's valid.

## Notes for future maintenance

- No native file/folder picker (`QtQuick.Dialogs`) here on purpose -- it
  reliably crashed a `gdbus` helper process in this Quickshell environment.
  Don't re-add one without first confirming it's actually stable.
- No hardcoded paths -- uses `$HOME`/`Quickshell.env("HOME")` throughout,
  so it works for any user.
