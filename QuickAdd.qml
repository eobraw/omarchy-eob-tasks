import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Store.js" as Store

// Centered capture overlay bound to a global hotkey, so a task can be written
// down without leaving whatever is on screen. Follows the reminders overlay's
// contract: the host injects `shell` and `manifest` and calls open()/close(),
// while user-initiated dismissal routes back through shell.hide() so the
// host's open-panel set stays consistent.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string scope: "day"

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: Style.font.family

  readonly property string countsLine: store.dailyCount + " pending today · " + store.monthlyCount + " this month"

  TaskStore { id: store }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.scope === "month" || payload.scope === "day") root.scope = payload.scope

    field.text = ""
    root.opened = true
    Qt.callLater(function () { field.forceActiveFocus() })
  }

  // Host-initiated close. Leaves the shell's bookkeeping alone — dismiss() is
  // the user-initiated path.
  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "eobraw.tasks")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // `keepOpen` backs Ctrl+Enter: capture a run of tasks without re-triggering
  // the hotkey between each one.
  function commit(scopeOverride, keepOpen) {
    var parsed = Store.splitScope(field.text, scopeOverride || root.scope)
    if (parsed.text === "") {
      root.dismiss()
      return
    }
    if (!store.add(parsed.text, parsed.scope, parsed.repeat)) return

    field.text = ""
    if (keepOpen) {
      root.scope = parsed.scope
      field.forceActiveFocus()
    } else {
      root.dismiss()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-task-add"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(420), panel.width - Style.gapsOut * 2)
      height: Math.min(content.implicitHeight + Style.spacing.panelPadding * 2,
                       panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      // Swallow clicks on the card so they don't reach the dismissal area.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: store.corrupt ? "tasks.json could not be parsed — edits are disabled" : root.countsLine
          color: store.corrupt ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        TextField {
          id: field
          width: parent.width
          foreground: root.foreground
          placeholderText: root.scope === "month" ? "New task this month…" : "New task today…"

          // BeforeItem so Escape and the Enter variants are decided here; every
          // other key falls through to normal text editing.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.commit(event.modifiers & Qt.ShiftModifier ? "month" : root.scope,
                          (event.modifiers & Qt.ControlModifier) !== 0)
              event.accepted = true
              return
            }
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              root.scope = root.scope === "day" ? "month" : "day"
              event.accepted = true
            }
          }
        }

        ButtonGroup {
          focusable: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          value: root.scope
          options: [
            { value: "day", label: "Today" },
            { value: "month", label: "This Month" }
          ]
          onChanged: function (value) {
            root.scope = value
            field.forceActiveFocus()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Enter to add · Shift+Enter for monthly · Ctrl+Enter to add and keep going · Tab switches · Esc cancels\n"
            + "daily: or weekly: in front of the text makes it come back on its own"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
