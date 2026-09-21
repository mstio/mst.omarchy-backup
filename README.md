# Omarchy Backup

A bar widget for the [`omarchy-backup`](https://github.com/mstio/omarchy-backup)
CLI. It keeps baseline drift, backup health, automatic timers, and the most
important recovery actions visible without replacing the CLI that performs the
actual backup work.

![Omarchy Backup widget showing a healthy baseline, actions, and automatic backup settings](preview.png)

## Features

- GREEN/YELLOW/RED baseline status directly in the Omarchy bar.
- Plain-language status explanation, baseline age, snapshot count, last doctor
  result, and configured destination.
- One-click snapshot, baseline, remote push, doctor, and timer actions with
  inline results.
- Controls for automatic backups, snapshot/doctor frequency, destination,
  retention, and maximum file size.
- Home-directory paths are displayed as `~/…`, keeping usernames out of the UI
  and screenshots while the CLI still receives a valid absolute path.

## Requirement: install the CLI first

This plugin is only the user interface. The separate
[`omarchy-backup` CLI](https://github.com/mstio/omarchy-backup) is required and
must be available on `PATH`; it owns all snapshot, validation, remote, retention,
and restore logic. Without it, the widget remains visible but reports
`omarchy-backup not found on PATH`.

On a stock Omarchy installation:

```bash
mkdir -p ~/Projects/omarchy-backup
git -C ~/Projects/omarchy-backup init
git -C ~/Projects/omarchy-backup remote add origin https://github.com/mstio/omarchy-backup.git
git -C ~/Projects/omarchy-backup fetch --depth 1 origin defa44477e3d8fbeccab9f9c4776cb3c1e04fed0
git -C ~/Projects/omarchy-backup checkout --detach defa44477e3d8fbeccab9f9c4776cb3c1e04fed0
~/Projects/omarchy-backup/install.sh
omarchy-backup doctor
```

The full commit SHA pins the CLI revision tested with this plugin release before
any downloaded code is executed. Review the CLI repository before deliberately
switching to a newer revision.

The CLI uses tools already present on Omarchy (`bash`, `jq`, `zstd`, `tar`,
`rclone`, and `systemctl`). See its README before configuring a destination or
restoring a machine.

## Install the plugin

```bash
omarchy plugin add https://github.com/mstio/mst.omarchy-backup.git --enable
```

Click the backup icon in the bar to open the panel. The colored dot means:

| Color | Meaning | Automatic behavior |
|---|---|---|
| GREEN | Live system matches the known-good baseline | No redundant snapshot when “skip if clean” is enabled |
| YELLOW | Packages, plugins, or files drifted | Creates and verifies a rolling snapshot; pushes it when a destination is configured |
| RED | Baseline or required tooling is broken | Refuses automatic backup until the problem is repaired |

YELLOW is not automatically accepted as the new known-good baseline. Review the
drift first, then use **Mark latest as baseline** only when the changed system is
known to work.

## Update or remove

```bash
omarchy plugin update mst.omarchy-backup
omarchy plugin remove mst.omarchy-backup
```

Removing the plugin removes only the bar UI. It does not uninstall the CLI,
delete snapshots, change the remote destination, or remove CLI timers.

## Security and privacy

Omarchy shell plugins execute as the current user and are not sandboxed; review
the repository before installing. This plugin calls the local `omarchy-backup`
CLI and its two small wrapper scripts. Status collection also performs read-only
`jq` and `systemctl --user` lookups. The plugin has no telemetry and does not
store credentials or implement network transfers itself; a configured CLI may
write verified snapshots through `rclone`.

Destination paths under the current home directory are shortened to `~/…` in
the interface. Secret-shaped files and credentials are excluded by the CLI, not
by this UI; consult the CLI README for the exact backup boundary.

## Development

```bash
omarchy plugin validate .
bash -n bin/run-action bin/status-json
tests/run-tests.sh
```

Action and status wrappers put hard deadlines around child processes and cap
their output before encoding JSON. The long-lived shell therefore never buffers
unbounded CLI or remote-controlled output in `StdioCollector`.

The plugin deliberately avoids a native `QtQuick.Dialogs` folder picker because
that picker triggered a reproducible portal helper crash in the target
Quickshell environment. The plain destination field supports both absolute
paths and `~/…`; raw `rclone` remotes remain configurable through the CLI.

## License

[MIT](LICENSE)
