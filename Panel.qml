import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Charge Limit bar widget: a leaf icon with the active limit, and a panel to
// pick 60/80/100% or a custom value (50-100%). All reading and writing goes
// through bin/charge-limit; asusd keeps the limit across boot and resume.
Panel {
  id: root
  moduleName: "assem.charge-limit"
  ipcTarget: "assem.charge-limit"

  readonly property string helper: String(Qt.resolvedUrl("bin/charge-limit")).replace(/^file:\/\//, "")
  readonly property var presets: [
    { value: 60, label: "preset.longevity" },
    { value: 80, label: "preset.balanced" },
    { value: 100, label: "preset.full" }
  ]

  property var info: ({})
  property string error: ""
  property bool cursorActive: false
  property int presetIndex: 0
  property int customValue: 80
  property bool sliderDragging: false

  readonly property bool supported: info.supported === "yes"
  readonly property bool installed: info.installed === "yes" && info.writable === "yes"
  readonly property int limit: parseInt(info.limit, 10) || 100
  readonly property int capacity: parseInt(info.capacity, 10) || 0
  readonly property bool busy: setProc.running || setupProc.running

  // Power profile per source. Omarchy does the switching on plug/unplug; this
  // panel only shows and saves its per-source choices (bin/charge-limit profile).
  property var profileInfo: ({})
  readonly property var profileSources: ["ac", "battery"]
  readonly property var availableProfiles: String(profileInfo.available || "").split(" ").filter(function(p) {
    return p === "power-saver" || p === "balanced" || p === "performance"
  })
  readonly property bool profileBusy: profileSetProc.running
  readonly property bool showLimit: setting("showLimit", true) !== false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function num(v) { return Commons.I18n.formatNumber(v) }

  function statusText() {
    if (info.present === undefined) return ""
    if (!supported) return strings.t("status.unsupported")
    if (!installed) return strings.t("status.setup")
    if (info.status === "Discharging") return strings.t("status.onBattery")
    if (limit >= 100) return strings.t("status.full")
    if (info.status === "Charging") return strings.t("status.chargingTo").arg(num(limit))
    if (aboveLimit) return strings.t("status.paused").arg(num(capacity))
    return strings.t("status.holding").arg(num(limit))
  }

  // Charging stopped but the battery still holds more than the limit (it was
  // charged before the limit was set). It only drains by running on battery.
  readonly property bool aboveLimit: installed && limit < 100 && info.status !== "Discharging"
    && info.status !== "Charging" && capacity > limit + 2

  function refresh() { if (!statusProc.running) statusProc.running = true }

  function parse(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab > 0) next[lines[i].slice(0, tab)] = lines[i].slice(tab + 1).trim().slice(0, 40)
    }
    if (Object.keys(next).length === 0) return
    info = next
    if (!sliderDragging) customValue = Math.max(50, Math.min(100, parseInt(next.limit, 10) || 80))
  }

  function refreshProfiles() { if (!profilesProc.running) profilesProc.running = true }

  function parseProfiles(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab > 0) next[lines[i].slice(0, tab)] = lines[i].slice(tab + 1).trim().slice(0, 60)
    }
    profileInfo = next
  }

  function setProfile(source, profile) {
    if (profileBusy || profileInfo[source] === profile) return
    error = ""
    profileSetProc.command = [helper, "profile", source, profile]
    profileSetProc.running = true
  }

  function setLimit(value) {
    value = Math.round(value / 5) * 5
    if (!installed || busy || value < 50 || value > 100) return
    error = ""
    setProc.command = [helper, "set", String(value)]
    setProc.running = true
  }

  function runSetup() {
    if (busy) return
    error = ""
    setupProc.running = true
  }

  function activatePreset() {
    if (presetIndex >= 0 && presetIndex < presets.length) setLimit(presets[presetIndex].value)
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    refreshProfiles()
    cursorActive = false
    for (var i = 0; i < presets.length; i++) if (presets[i].value === limit) presetIndex = i
  }

  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parse(text) }
  }

  Process {
    id: setProc
    onExited: function(code) {
      if (code !== 0) root.error = strings.t("set.failed")
      root.refresh()
    }
  }

  Process {
    id: setupProc
    command: [root.helper, "setup"]
    onExited: function(code) {
      if (code !== 0) root.error = strings.t("setup.failed")
      root.refresh()
    }
  }

  Process {
    id: profilesProc
    command: [root.helper, "profiles"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseProfiles(text) }
  }

  Process {
    id: profileSetProc
    onExited: function(code) {
      if (code !== 0) root.error = strings.t("profile.failed")
      root.refreshProfiles()
    }
  }

  // Plugging in or unplugging changes which row is in effect.
  Connections {
    target: UPower
    function onOnBatteryChanged() { if (root.opened) root.refreshProfiles() }
  }

  // Slow background poll keeps the bar number honest; faster while open.
  // Profiles are read only while open: listing them starts a Python tool.
  Timer {
    interval: root.opened ? 5000 : 60000; running: true; repeat: true
    onTriggered: { root.refresh(); if (root.opened) root.refreshProfiles() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌪"
    labelText: root.showLimit && root.supported && root.limit < 100 && !vertical ? root.num(root.limit) : ""
    slotSize: Style.bar.iconSlot * (labelText !== "" ? 1.8 : 1)
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        var d = dx !== 0 ? dx : dy
        root.presetIndex = Math.max(0, Math.min(root.presets.length - 1, root.presetIndex + d))
      }
      onActivateRequested: if (root.cursorActive) root.activatePreset()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroValue.implicitHeight)

          PlainText {
            id: heroIcon
            text: "󰌪"
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroValue.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              text: strings.t("title")
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
            PlainText {
              text: root.statusText().toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PlainText {
            id: heroValue
            visible: root.supported
            text: root.num(root.limit) + "%"
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Charge bar with the limit marked ----------
        Item {
          visible: root.supported
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }
          Rectangle {
            anchors.left: track.left
            height: track.height
            radius: track.radius
            color: root.bar.foreground
            width: Math.max(track.height, track.width * Math.min(1, root.capacity / 100))
            Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
          }
          Rectangle {
            visible: root.limit < 100
            width: Style.space(2)
            height: track.height + Style.space(8)
            anchors.verticalCenter: track.verticalCenter
            x: track.width * root.limit / 100 - width / 2
            color: Commons.Color.accent
          }
        }

        PlainText {
          visible: root.aboveLimit
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.75
          font.pixelSize: Style.font.bodySmall
          text: strings.t("hint.aboveLimit").arg(root.num(root.limit))
        }

        // ---------- One-time setup ----------
        Column {
          visible: root.supported && !root.installed && root.info.present !== undefined
          width: parent.width
          spacing: Style.space(10)

          PlainText {
            width: parent.width
            wrapMode: Text.WordWrap
            opacity: 0.75
            font.pixelSize: Style.font.bodySmall
            text: strings.t("setup.hint")
          }
          Button {
            width: parent.width
            text: strings.t("setup.button")
            iconText: "󰌾"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            enabled: !root.busy
            onClicked: root.runSetup()
          }
        }

        // ---------- Presets + custom ----------
        Column {
          visible: root.supported && root.installed
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: strings.t("presets")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: presetRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (root.presets.length - 1)) / root.presets.length

            Repeater {
              model: root.presets
              Button {
                required property var modelData
                required property int index
                width: presetRow.cellWidth
                text: root.num(modelData.value) + "%  " + strings.t(modelData.label)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.limit === modelData.value
                hasCursor: root.cursorActive && root.presetIndex === index
                enabled: !root.busy
                onClicked: root.setLimit(modelData.value)
                onHovered: function(h) { if (h) { root.cursorActive = true; root.presetIndex = index } }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            PlainText {
              id: customLabel
              anchors.verticalCenter: parent.verticalCenter
              font.pixelSize: Style.font.bodySmall
              opacity: 0.6
              text: strings.t("custom")
            }

            PanelSlider {
              id: customSlider
              bar: root.bar
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - customLabel.implicitWidth - applyButton.width - parent.spacing * 2
              minimum: 50
              maximum: 100
              step: 5
              integer: true
              value: root.customValue
              onDraggingChanged: root.sliderDragging = dragging
              onMoved: function(v) { root.customValue = Math.round(v / 5) * 5 }
              onReleased: function(v) { root.customValue = Math.round(v / 5) * 5 }
            }

            Button {
              id: applyButton
              width: Style.space(96)
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("apply").arg(root.num(root.customValue))
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !root.busy && root.customValue !== root.limit
              opacity: enabled ? 1 : 0.4
              onClicked: root.setLimit(root.customValue)
            }
          }
        }

        // ---------- Power profile per source ----------
        Column {
          visible: root.availableProfiles.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: strings.t("profiles")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          // Both row labels share the width of the longer one, in bold.
          TextMetrics {
            id: profileLabelMetrics
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            text: strings.t("profiles.ac").length >= strings.t("profiles.battery").length
              ? strings.t("profiles.ac") : strings.t("profiles.battery")
          }

          Repeater {
            model: root.profileSources

            Row {
              id: profileRow
              required property string modelData
              readonly property string source: modelData
              readonly property real labelWidth: Math.ceil(profileLabelMetrics.advanceWidth) + Style.space(6)
              readonly property real cellWidth: (width - labelWidth - spacing * root.availableProfiles.length) / Math.max(1, root.availableProfiles.length)
              width: parent.width
              spacing: Style.space(6)

              PlainText {
                width: profileRow.labelWidth
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Style.font.bodySmall
                opacity: root.profileInfo.source === profileRow.source ? 1 : 0.6
                font.bold: root.profileInfo.source === profileRow.source
                elide: Text.ElideRight
                text: strings.t("profiles." + profileRow.source)
              }

              Repeater {
                model: root.availableProfiles
                Button {
                  required property string modelData
                  width: profileRow.cellWidth
                  text: strings.t("profile." + modelData)
                  fontSize: Style.font.bodySmall
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.profileInfo[profileRow.source] === modelData
                  enabled: !root.profileBusy
                  onClicked: root.setProfile(profileRow.source, modelData)
                }
              }
            }
          }

          PlainText {
            width: parent.width
            wrapMode: Text.WordWrap
            opacity: 0.6
            font.pixelSize: Style.font.caption
            text: (root.profileInfo.source === "battery" ? strings.t("profiles.nowBattery") + " "
                   : root.profileInfo.source === "ac" ? strings.t("profiles.nowAc") + " " : "")
                  + strings.t("profiles.hint")
          }
        }

        PlainText {
          visible: root.error !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          color: Commons.Color.accent
          font.pixelSize: Style.font.bodySmall
          text: root.error
        }

        // ---------- Stats ----------
        PanelSeparator { visible: root.info.present === "yes"; foreground: root.bar.foreground }

        Row {
          visible: root.info.present === "yes"
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: strings.t("charge"); value: root.info.capacity ? root.num(root.capacity) + "%" : "—" }
            InfoPair { label: strings.t("health"); value: root.info.health ? root.num(parseInt(root.info.health, 10)) + "%" : "—" }
          }
          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: strings.t("cycles"); value: root.info.cycles ? root.num(parseInt(root.info.cycles, 10)) : "—" }
            InfoPair { label: strings.t("persist"); value: root.installed ? strings.t("yes") : strings.t("no") }
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.space(8)
    PlainText { text: label; opacity: 0.6; font.pixelSize: Style.font.bodySmall }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    PlainText { text: value; font.pixelSize: Style.font.bodySmall }
  }
}
