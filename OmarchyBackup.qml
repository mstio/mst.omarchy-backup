pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for the `omarchy-backup` CLI: a theme-tinted status icon (green
// dot = matches baseline, amber = drifted, red = broken/degraded) that opens
// a dialog with the same functions and options the CLI exposes --
// snapshot/push/doctor now, and the config.conf settings that drive the
// automatic timers. The plugin never talks to pacman/rclone/git itself; it
// only shells out to `omarchy-backup` (+ two thin wrapper scripts in bin/)
// so all real logic stays in one place.
Panel {
  id: root
  moduleName: "mst.omarchy-backup"
  ipcTarget: "mst.omarchy-backup"

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/mst.omarchy-backup"

  // --- live state, filled in by statusProc -------------------------------
  property bool installed: true
  property string color: "UNKNOWN"
  property string statusText: "Loading…"
  property string baselineName: ""
  property string baselineCreated: ""
  property int snapshotCount: 0
  property string doctorStatus: ""
  property string doctorRunAt: ""
  property var doctorReasons: []
  property bool remoteConfigured: false
  property string remoteName: ""
  property bool timerInstalled: false
  property bool timerEnabled: false

  // Config mirror (from `omarchy-backup config list`), kept as plain
  // properties so the dialog's controls can bind directly.
  property bool cfgEnabled: true
  property string cfgSnapshotFrequency: "daily"
  property string cfgDoctorFrequency: "monthly"
  property string cfgRemoteName: ""
  property string cfgRemotePath: "omarchy-backup"
  property int cfgRetentionRemote: 3
  property int cfgMaxFileSizeMb: 20
  property bool cfgSkipAutoIfClean: true

  property bool refreshing: false
  property bool actionRunning: false
  property string lastActionLabel: ""
  property string lastActionResult: ""
  property bool lastActionOk: true
  property bool pendingReinstallTimers: false

  implicitWidth: icon.implicitWidth
  implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

  function statusColor() {
    if (root.color === "GREEN") return "#4caf50"
    if (root.color === "YELLOW") return "#e0a030"
    if (root.color === "RED") return Color.urgent
    return Color.muted
  }

  function statusExplanation() {
    if (root.color === "GREEN") return "Matches your baseline -- no drift detected. Nothing to do."
    if (root.color === "YELLOW") return "Packages, plugins or files have changed since your baseline. Review with `omarchy-backup status` in a terminal, then either fix the drift or accept it (“Mark latest as baseline” after a new snapshot)."
    if (root.color === "RED") return "The baseline snapshot is missing/corrupt, or a required tool is gone. Run doctor for the exact reason."
    return "No baseline set yet, so there's nothing to compare against. Take a snapshot, then mark it as baseline."
  }

  function applyStatus(text) {
    root.refreshing = false
    try {
      var data = JSON.parse(String(text || "{}"))
      root.installed = data.installed !== false
      if (!root.installed) return
      root.color = String(data.color || "UNKNOWN")
      root.statusText = String(data.statusText || "")
      root.baselineName = String(data.baselineName || "")
      root.baselineCreated = String(data.baselineCreated || "")
      root.snapshotCount = Number(data.snapshotCount || 0)
      root.doctorStatus = String(data.doctorStatus || "")
      root.doctorRunAt = String(data.doctorRunAt || "")
      root.doctorReasons = data.doctorReasons || []
      root.remoteConfigured = data.remoteConfigured === true
      root.remoteName = String(data.remoteName || "")
      root.timerInstalled = data.timerInstalled === true
      root.timerEnabled = data.timerEnabled === true

      var cfg = {}
      var list = data.config || []
      for (var i = 0; i < list.length; i++) cfg[list[i].key] = list[i].value
      root.cfgEnabled = cfg["OB_CFG_ENABLED"] === "true"
      root.cfgSnapshotFrequency = String(cfg["OB_CFG_SNAPSHOT_FREQUENCY"] || "daily")
      root.cfgDoctorFrequency = String(cfg["OB_CFG_DOCTOR_FREQUENCY"] || "monthly")
      root.cfgRemoteName = String(cfg["OB_CFG_REMOTE_NAME"] || "")
      root.cfgRemotePath = String(cfg["OB_CFG_REMOTE_PATH"] || "omarchy-backup")
      root.cfgRetentionRemote = parseInt(cfg["OB_CFG_RETENTION_REMOTE"] || "3", 10) || 3
      root.cfgMaxFileSizeMb = parseInt(cfg["OB_CFG_MAX_FILE_SIZE_MB"] || "20", 10) || 20
      root.cfgSkipAutoIfClean = cfg["OB_CFG_SKIP_AUTO_IF_CLEAN"] === "true"
    } catch (e) {
      root.installed = true
      root.color = "UNKNOWN"
      root.statusText = "Could not read status."
    }
  }

  function refreshStatus() {
    if (statusProc.running) return
    root.refreshing = true
    statusProc.running = true
  }

  function runAction(action, label) {
    if (actionProc.running) return
    root.actionRunning = true
    root.lastActionLabel = label
    root.lastActionResult = ""
    actionProc.command = [root.pluginDir + "/bin/run-action", action]
    actionProc.running = true
  }

  // A plain "if running, drop it" guard silently loses writes when two
  // settings change together (e.g. the folder picker sets both
  // OB_CFG_REMOTE_PATH and clears OB_CFG_REMOTE_NAME in one click) --
  // queue instead, so every requested write actually happens, in order.
  property var pendingConfigWrites: []

  function setConfig(key, value, reinstallTimers) {
    var writes = root.pendingConfigWrites.slice()
    writes.push({key: key, value: value, reinstallTimers: reinstallTimers === true})
    root.pendingConfigWrites = writes
    root.processConfigQueue()
  }

  function processConfigQueue() {
    if (configSetProc.running) return
    if (root.pendingConfigWrites.length === 0) return
    var writes = root.pendingConfigWrites.slice()
    var next = writes.shift()
    root.pendingConfigWrites = writes
    root.pendingReinstallTimers = root.pendingReinstallTimers || next.reinstallTimers
    configSetProc.command = ["omarchy-backup", "config", "set", next.key, next.value]
    configSetProc.running = true
  }

  Process {
    id: statusProc
    command: [root.pluginDir + "/bin/status-json"]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyStatus(statusStdout.text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.actionRunning = false
      try {
        var data = JSON.parse(String(actionStdout.text || "{}"))
        root.lastActionOk = data.ok === true
        root.lastActionResult = String(data.output || "").trim().split("\n").slice(-1)[0]
      } catch (e) {
        root.lastActionOk = (exitCode === 0)
        root.lastActionResult = root.lastActionOk ? "Done." : "Failed (see logs)."
      }
      root.refreshStatus()
    }
  }

  Process {
    id: configSetProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (root.pendingConfigWrites.length > 0) {
        root.processConfigQueue()
        return
      }
      if (root.pendingReinstallTimers) {
        root.pendingReinstallTimers = false
        root.runAction("install-timers", "Apply timer settings")
      } else {
        root.refreshStatus()
      }
    }
  }

  Timer {
    interval: 10 * 60 * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // --- bar icon ------------------------------------------------------------
  WidgetButton {
    id: icon
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal
    tooltipText: root.statusText + "\n" + root.statusExplanation() + (root.baselineName !== ""
      ? "\n\nBaseline: " + root.baselineName + " (" + root.snapshotCount + "/3 snapshots)"
      : "")

    Image {
      id: iconImage
      anchors.centerIn: parent
      width: Math.max(14, icon.height - 12)
      height: width
      source: Qt.resolvedUrl("assets/icon.svg")
      sourceSize.width: width * 2
      sourceSize.height: height * 2
      fillMode: Image.PreserveAspectFit
      smooth: true
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: iconImage
      source: iconImage
      colorization: 1.0
      colorizationColor: icon.foreground
    }

    Rectangle {
      width: 6
      height: 6
      radius: 3
      anchors.right: iconImage.right
      anchors.bottom: iconImage.bottom
      color: root.statusColor()
      border.width: 1
      border.color: root.bar ? root.bar.background : Color.background
      visible: root.installed
    }

    onPressed: function(button) {
      root.refreshStatus()
      root.toggle()
    }
  }

  // --- dialog ----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: icon
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Style.space(560), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: localPathField.activeFocus
      onCloseRequested: root.close()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: content
        width: flick.width
        spacing: Style.spacing.md

        // ---- header ----
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          Text {
            text: "Omarchy Backup"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Item { Layout.fillWidth: true }

          Button {
            text: ""
            iconText: "⟳"
            iconSpinning: root.refreshing
            tooltipText: "Refresh"
            onClicked: root.refreshStatus()
          }

          Button {
            text: "✕"
            tooltipText: "Close"
            onClicked: root.close()
          }
        }

        PanelSeparator { foreground: Color.foreground }

        // ---- status ----
        PanelSectionHeader { text: "STATUS"; foreground: Color.foreground }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xs

          Text {
            text: root.installed ? root.color : "omarchy-backup not found on PATH"
            color: root.installed ? root.statusColor() : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            visible: root.installed
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.statusExplanation()
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.installed
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.baselineName !== ""
              ? "Baseline: " + root.baselineName + "  ·  " + root.snapshotCount + "/3 snapshots"
              : "No baseline set yet -- take a snapshot, then mark it as baseline."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.installed && root.doctorStatus !== ""
            text: "Doctor: " + root.doctorStatus + (root.doctorRunAt !== "" ? " (" + root.doctorRunAt.slice(0, 10) + ")" : "")
            color: root.doctorStatus === "HEALTHY" ? Color.muted : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.installed && root.doctorStatus !== "" && root.doctorStatus !== "HEALTHY" && root.doctorReasons.length > 0
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: root.doctorReasons.map(function(r) { return "• " + r }).join("\n")
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.installed
            text: !root.remoteConfigured ? "Remote: not configured"
              : (root.remoteName !== "" ? "Remote: " + root.remoteName : "Remote: " + root.cfgRemotePath)
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: Color.foreground }

        // ---- actions ----
        PanelSectionHeader { text: "ACTIONS"; foreground: Color.foreground }

        Flow {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          Button {
            text: "Snapshot now"
            bordered: true
            tooltipText: "Create a new local snapshot of the current system state (packages, plugins, dotfiles, machine memory, ...)."
            iconSpinning: root.actionRunning && root.lastActionLabel === "Snapshot"
            onClicked: root.runAction("snapshot", "Snapshot")
          }
          Button {
            text: "Mark latest as baseline"
            bordered: true
            tooltipText: "Mark the most recently created local snapshot as the baseline -- the known-good state 'status'/doctor compare against."
            visible: root.snapshotCount > 0
            iconSpinning: root.actionRunning && root.lastActionLabel === "Baseline"
            onClicked: root.runAction("mark-baseline-latest", "Baseline")
          }
          Button {
            text: "Push latest"
            bordered: true
            tooltipText: root.remoteConfigured
              ? "Upload the most recently created local snapshot to " + (root.remoteName !== "" ? root.remoteName : "the configured backup destination") + "."
              : "Set a backup destination in Options first."
            iconSpinning: root.actionRunning && root.lastActionLabel === "Push"
            opacity: root.remoteConfigured ? 1.0 : 0.4
            onClicked: if (root.remoteConfigured) root.runAction("push-latest", "Push")
          }
          Button {
            text: "Run doctor"
            bordered: true
            tooltipText: "Check whether this tool can still snapshot/diff/restore this system -- both backup health (snapshot integrity) and tool/environment compatibility."
            iconSpinning: root.actionRunning && root.lastActionLabel === "Doctor"
            onClicked: root.runAction("doctor", "Doctor")
          }
        }

        Text {
          visible: root.lastActionResult !== ""
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          text: root.lastActionLabel + ": " + root.lastActionResult
          color: root.lastActionOk ? Color.muted : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: Color.foreground }

        // ---- options ----
        PanelSectionHeader { text: "OPTIONS"; foreground: Color.foreground }

        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "Automatic backups & doctor"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Item { Layout.fillWidth: true }
          ToggleSwitch {
            checked: root.cfgEnabled
            onToggled: root.setConfig("OB_CFG_ENABLED", root.cfgEnabled ? "false" : "true", true)
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xxs
          Text {
            text: "Snapshot every"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          ButtonGroup {
            options: ["daily", "weekly", "monthly"]
            value: root.cfgSnapshotFrequency
            onChanged: function(v) { root.setConfig("OB_CFG_SNAPSHOT_FREQUENCY", v, true) }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xxs
          Text {
            text: "Doctor check every"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          ButtonGroup {
            options: ["daily", "weekly", "monthly"]
            value: root.cfgDoctorFrequency
            onChanged: function(v) { root.setConfig("OB_CFG_DOCTOR_FREQUENCY", v, true) }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "Skip snapshot if nothing changed"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Item { Layout.fillWidth: true }
          ToggleSwitch {
            checked: root.cfgSkipAutoIfClean
            onToggled: root.setConfig("OB_CFG_SKIP_AUTO_IF_CLEAN", root.cfgSkipAutoIfClean ? "false" : "true", false)
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.xxs

          Text {
            text: "Backup destination"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          TextField {
            id: localPathField
            Layout.fillWidth: true
            text: root.cfgRemotePath
            placeholderText: "/path/to/backup/folder"
            onEditingFinished: {
              if (text !== root.cfgRemotePath) root.setConfig("OB_CFG_REMOTE_PATH", text, false)
            }
          }
          Text {
            text: "Press Enter or click away to save. Any local or mounted folder (e.g. an rclone-mounted Drive folder, a NAS mount, or a plain disk path). omarchy-backup only ever writes below it, under <folder>/<hostname>/."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }
          Text {
            visible: root.cfgRemoteName !== ""
            text: "A raw rclone remote ('" + root.cfgRemoteName + "') is set via the CLI (`omarchy-backup config set OB_CFG_REMOTE_NAME ...`) and takes priority over the folder above -- clear it there to use a local folder instead."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            Layout.fillWidth: true
          }
        }

        RowLayout {
          Layout.fillWidth: true
          NumberField {
            label: "Keep on remote"
            value: root.cfgRetentionRemote
            from: 1
            to: 10
            onModified: function(v) { root.setConfig("OB_CFG_RETENTION_REMOTE", String(v), false) }
          }
          Item { Layout.fillWidth: true }
          NumberField {
            label: "Max file size (MB)"
            value: root.cfgMaxFileSizeMb
            from: 1
            to: 500
            stepSize: 5
            onModified: function(v) { root.setConfig("OB_CFG_MAX_FILE_SIZE_MB", String(v), false) }
          }
        }
        Text {
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          text: "Files larger than this are left out of the snapshot rather than guessed at up front -- the default (20MB) works for dotfiles/scripts; \"Snapshot now\" tells you if anything got skipped, raise this only if that happens for a file you actually want included."
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: Color.foreground }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap
          Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "Timers: " + (root.timerInstalled ? (root.timerEnabled ? "installed & enabled" : "installed, disabled") : "not installed yet")
              + "  ·  ~/.config/omarchy-backup/config.conf"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Button {
            text: root.timerInstalled ? "Reapply" : "Install timers"
            bordered: true
            fontSize: Style.font.caption
            iconSpinning: root.actionRunning && root.lastActionLabel === "Timers"
            onClicked: root.runAction("install-timers", "Timers")
          }
        }
      }
      }
    }
  }

  Component.onCompleted: root.refreshStatus()
}
