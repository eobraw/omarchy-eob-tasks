import QtQuick
import qs.Commons
import qs.Ui
import "Store.js" as Store

// Bar button + three-tab task popup, in the one-entry-point shape used by the
// first-party rich widgets (agents, tailscale, power): the root extends
// Ui.Panel, which owns the open/close lifecycle and hands the bar the
// open()/close()/opened contract that `omarchy-shell shell toggle` needs.
Panel {
  id: root
  moduleName: "eobraw.tasks"
  ipcTarget: "eobraw.tasks"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // "day" | "month" | "done" | "about"
  property string activeTab: "day"
  property int selectedIndex: -1
  property bool cursorActive: false

  // Tabs that list tasks and accept new ones; the other two are read-only.
  readonly property bool taskTab: activeTab === "day" || activeTab === "month"

  readonly property var rows: activeTab === "day" ? store.dailyRows()
    : (activeTab === "month" ? store.monthlyRows()
    : (activeTab === "about" ? helpRows : store.completedRows()))

  // Keyboard reference. Same row shape as the task views ("header" rows are
  // captions, "help" rows are a key column plus a description) so one delegate
  // renders every tab.
  readonly property var helpRows: [
    { kind: "header", key: "h-global", label: "Anywhere" },
    { kind: "help", key: "g1", keys: "Super + Shift + T", label: "Quick add a task" },
    { kind: "help", key: "g2", keys: "Super + Alt + T", label: "Open this panel" },

    { kind: "header", key: "h-list", label: "Browsing tasks" },
    { kind: "help", key: "l1", keys: "Tab / Shift + Tab", label: "Switch tabs" },
    { kind: "help", key: "l2", keys: "j / k  or  \u2193 / \u2191", label: "Move between tasks" },
    { kind: "help", key: "l3", keys: "Space / Enter", label: "Complete or reopen a task" },
    { kind: "help", key: "l4", keys: "m", label: "Move a task between Today and This Month" },
    { kind: "help", key: "l4r", keys: "r", label: "Cycle the selected task: once \u2192 daily \u2192 weekly" },
    { kind: "help", key: "l5", keys: "x", label: "Delete the selected task" },
    { kind: "help", key: "l6", keys: "a", label: "Jump to the add field" },
    { kind: "help", key: "l7", keys: "Esc", label: "Close the panel" },

    { kind: "header", key: "h-add", label: "Adding a task" },
    { kind: "help", key: "a1", keys: "Enter", label: "Add to the current tab" },
    { kind: "help", key: "a2", keys: "m: buy milk", label: "File it under This Month" },
    { kind: "help", key: "a3", keys: "d: buy milk", label: "File it under Today" },
    { kind: "help", key: "a5", keys: "daily: vitamins", label: "A task that comes back the next day" },
    { kind: "help", key: "a6", keys: "weekly: bins", label: "A task that comes back a week later" },
    { kind: "help", key: "a4", keys: "\u2193", label: "Move down into the list" },

    { kind: "header", key: "h-quick", label: "Quick add overlay" },
    { kind: "help", key: "q1", keys: "Enter", label: "Add and close" },
    { kind: "help", key: "q2", keys: "Shift + Enter", label: "Add as a monthly task" },
    { kind: "help", key: "q3", keys: "Ctrl + Enter", label: "Add and keep the overlay open" },
    { kind: "help", key: "q4", keys: "Tab", label: "Toggle Today / This Month" },
    { kind: "help", key: "q5", keys: "Esc", label: "Cancel" },

    { kind: "header", key: "h-mouse", label: "Mouse" },
    { kind: "help", key: "m1", keys: "Click a row", label: "Complete or reopen it" },
    { kind: "help", key: "m2", keys: "\u2192 / \u2190 on a row", label: "Move it to the other list" },
    { kind: "help", key: "m2r", keys: "󰑖 on a row", label: "Cycle how often it repeats" },
    { kind: "help", key: "m3", keys: "\u00d7 on a row", label: "Delete it" },
    { kind: "help", key: "m4", keys: "Click the bar icon", label: "Open this panel" },

    { kind: "header", key: "h-carry", label: "Carry-forward" },
    { kind: "help", key: "c1", keys: "Automatic", label: "Unfinished tasks stay on Today or This Month until done" },
    { kind: "help", key: "c2", keys: "carried 3d", label: "How long an unfinished task has been rolling over" },
    { kind: "help", key: "c3", keys: "After a move", label: "A moved task keeps its age, so a straggler stays visible" },

    { kind: "header", key: "h-repeat", label: "Repeating tasks" },
    { kind: "help", key: "r1", keys: "daily", label: "Completing it files it under Done and it returns tomorrow" },
    { kind: "help", key: "r2", keys: "weekly", label: "Same, a week after the day you last did it" },
    { kind: "help", key: "r3", keys: "Reopen in Done", label: "Undoes the completion and puts the task straight back" }
  ]

  readonly property string badgeText: store.dailyCount > 0
    ? "󰄲 " + store.dailyCount
    : "󰄲"

  readonly property string countsLine: store.dailyCount + " today · " + store.monthlyCount + " this month"

  readonly property string emptyText: activeTab === "done"
    ? "Nothing completed yet."
    : (activeTab === "month" ? "No monthly tasks pending." : "Nothing pending today.")

  readonly property string footerText: store.corrupt
    ? "tasks.json could not be parsed \u2014 edits are disabled"
    : (activeTab === "about" ? "Tasks 1.3.0 \u00b7 ~/.local/share/omarchy/eobraw.tasks/tasks.json" : countsLine)

  TaskStore { id: store }

  // --- cursor -----------------------------------------------------------------
  //
  // Headers are not cursor targets, so movement steps over them; the panel owns
  // the single highlight and mouse hover writes into the same state (the
  // CursorSurface contract).

  function isSelectable(index) {
    return index >= 0 && index < rows.length && rows[index].kind === "task"
  }

  function firstSelectable(from, step) {
    for (var i = from; i >= 0 && i < rows.length; i += step)
      if (rows[i].kind === "task") return i
    return -1
  }

  function moveCursor(delta) {
    // About has no cursor targets, so j/k scrolls the reference instead.
    if (root.activeTab === "about") {
      list.contentY = Math.max(0, Math.min(Math.max(0, list.contentHeight - list.height),
                                           list.contentY + delta * Style.space(48)))
      return
    }
    cursorActive = true
    if (!isSelectable(selectedIndex)) {
      selectedIndex = firstSelectable(delta > 0 ? 0 : rows.length - 1, delta > 0 ? 1 : -1)
      return
    }
    var next = firstSelectable(selectedIndex + delta, delta)
    if (next !== -1) selectedIndex = next
  }

  function currentTask() {
    return isSelectable(selectedIndex) ? rows[selectedIndex].task : null
  }

  function activateCursor() {
    var task = currentTask()
    if (task) store.toggle(task.id)
  }

  function deleteCursor() {
    var task = currentTask()
    if (task) store.remove(task.id)
  }

  // Re-files the selected task under the other pending scope. Only the two
  // pending tabs offer it: a completed task has already left both lists, and
  // re-bucketing it would only shuffle the archive.
  function moveTask(id) {
    if (!root.taskTab || !id) return
    var index = root.selectedIndex
    if (!store.move(id)) return
    // The row just left this list. Keep the cursor where it was so a run of
    // m's walks down the list instead of stranding the highlight past the end.
    var next = firstSelectable(index, 1)
    root.selectedIndex = next !== -1 ? next : firstSelectable(rows.length - 1, -1)
    root.cursorActive = root.selectedIndex !== -1
  }

  function moveSelected() {
    var task = currentTask()
    if (task) root.moveTask(task.id)
  }

  // Only the pending tabs offer it, for the same reason as a move: an archive
  // row records one completion and has nothing left to repeat.
  function repeatSelected() {
    var task = currentTask()
    if (task && root.taskTab) store.cycleRepeat(task.id)
  }

  // `focusField` is false when the switch came from h/l inside the list, so a
  // run of h/l keeps walking tabs instead of dropping focus into the input
  // after the first step.
  function setTab(tab, focusField) {
    if (root.activeTab === tab) return
    // Move focus off the add field BEFORE the switch. The Done tab hides the
    // field, and hiding an item that currently holds focus drops focus out of
    // the panel surface entirely, which tears the popup down mid-switch.
    if (tab === "done" || tab === "about" || focusField === false) keyCatcher.forceActiveFocus()
    root.activeTab = tab
    root.selectedIndex = -1
    root.cursorActive = false
    if (focusField !== false) Qt.callLater(root.focusForTab)
  }

  function cycleTab(direction, focusField) {
    var order = ["day", "month", "done", "about"]
    var index = order.indexOf(activeTab) + (direction >= 0 ? 1 : -1)
    setTab(order[(index + order.length) % order.length], focusField)
  }

  // The add field is the point of the panel on the pending tabs, so it takes
  // focus there; the Done tab has nothing to type into and goes straight to
  // keyboard navigation.
  function focusForTab() {
    if (!root.opened) return
    if (root.taskTab) addField.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function commitAdd() {
    var parsed = Store.splitScope(addField.text, root.activeTab === "month" ? "month" : "day")
    if (parsed.text === "") return
    if (store.add(parsed.text, parsed.scope, parsed.repeat)) {
      addField.text = ""
      // Typing "m:" from the Today tab should show you where the task landed.
      if (parsed.scope !== root.activeTab) setTab(parsed.scope)
    }
  }

  onOpenedChanged: {
    if (opened) {
      selectedIndex = -1
      cursorActive = false
    } else {
      // Reset on close so the panel always reopens on the pending list. Without
      // this it reopens on whatever you left it on — landing on the Done
      // archive or the About reference every time, which is never what you
      // want from a glance at the bar.
      addField.text = ""
      activeTab = "day"
    }
  }

  // --- bar button --------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.badgeText
    // Something carried over from a previous day or month gets the bar's
    // urgent color, so a growing backlog is visible without opening anything.
    active: store.overdueCount > 0
    tooltipText: root.countsLine
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.setTab("done")
      root.toggle()
    }
  }

  // --- popup -------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.taskTab ? addField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the user is typing, every key belongs to the field; the field
      // handles Escape and Down itself to get back out.
      blocked: addField.activeFocus

      onCloseRequested: root.close()
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.cycleTab(dx, false)
      }
      onActivateRequested: root.activateCursor()
      onTabRequested: function (direction) { root.cycleTab(direction, false) }
      onDeleteRequested: root.deleteCursor()
      onTextKey: function (text) {
        if (text === "a" && root.taskTab) addField.forceActiveFocus()
        else if (text === "m" || text === "M") root.moveSelected()
        else if (text === "r" || text === "R") root.repeatSelected()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.spacing.md

        ButtonGroup {
          id: tabs
          focusable: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          value: root.activeTab
          options: [
            { value: "day", label: "Today" },
            { value: "month", label: "This Month" },
            { value: "done", label: "Done" },
            { value: "about", label: "About" }
          ]
          onChanged: function (value) { root.setTab(value) }
        }

        TextField {
          id: addField
          visible: root.taskTab
          width: parent.width
          foreground: root.foreground
          // A focused TextField consumes Tab entirely — neither the Keys
          // handler below nor the panel's key catcher ever sees it — so Tab is
          // the one key that can't switch tabs from here; Alt+Left/Right do
          // that instead. Leaving the tab chain at least stops Tab from walking
          // focus out of the panel.
          activeFocusOnTab: false
          placeholderText: root.activeTab === "month"
            ? "Add a task for this month…"
            : "Add a task for today…"

          onAccepted: root.commitAdd()

          // The key catcher is blocked while this field has focus, so the ways
          // back out of it are handled here. Tab especially: left to Qt it runs
          // default focus navigation and walks focus clean out of the panel.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              root.cycleTab((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Right && (event.modifiers & Qt.AltModifier)) {
              root.cycleTab(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Left && (event.modifiers & Qt.AltModifier)) {
              root.cycleTab(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              keyCatcher.forceActiveFocus()
              root.moveCursor(1)
              event.accepted = true
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Item {
          width: parent.width
          height: Math.max(Style.space(30), Math.min(list.contentHeight, Style.space(340)))

          ListView {
            id: list
            anchors.fill: parent
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex
            // Keep a keyboard-selected row on screen once the list outgrows
            // the cap above.
            highlightRangeMode: ListView.ApplyRange
            preferredHighlightBegin: 0
            preferredHighlightEnd: height

            delegate: Column {
              id: rowDelegate
              required property var modelData
              required property int index
              width: list.width

              // Reference row: fixed key column on the left, description on the
              // right. Only ever present on the About tab.
              Item {
                visible: rowDelegate.modelData.kind === "help"
                width: parent.width
                height: visible ? Math.max(Style.space(22), helpText.implicitHeight + Style.spacing.xs * 2) : 0

                Text {
                  id: helpKeys
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.top: parent.top
                  anchors.topMargin: Style.spacing.xs
                  width: Style.space(132)
                  text: rowDelegate.modelData.keys || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: helpText
                  textFormat: Text.PlainText
                  anchors.left: helpKeys.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.top: parent.top
                  anchors.topMargin: Style.spacing.xs
                  text: rowDelegate.modelData.label || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }

              PanelSectionHeader {
                visible: rowDelegate.modelData.kind === "header"
                text: rowDelegate.modelData.label
                foreground: root.foreground
                fontFamily: root.fontFamily
                bottomPadding: Style.spacing.xxs
              }

              CursorSurface {
                id: taskRow
                visible: rowDelegate.modelData.kind === "task"
                width: parent.width
                height: Style.space(30)
                foreground: root.foreground
                hasCursor: root.cursorActive && root.selectedIndex === rowDelegate.index

                readonly property var task: rowDelegate.modelData.task
                readonly property bool done: !!(task && task.done)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: {
                    root.cursorActive = true
                    root.selectedIndex = rowDelegate.index
                  }
                  onExited: root.cursorActive = false
                  onClicked: if (taskRow.task) store.toggle(taskRow.task.id)
                }

                Text {
                  id: checkbox
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  text: taskRow.done ? "󰄲" : "󰄱"
                  color: taskRow.done ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                // Cycles once → daily → weekly. Lit while the task repeats,
                // matching the cadence spelled out in the meta column.
                PanelActionButton {
                  id: repeatButton
                  anchors.right: moveButton.left
                  anchors.rightMargin: Style.spacing.xxs
                  anchors.verticalCenter: parent.verticalCenter
                  visible: taskRow.hasCursor && root.taskTab
                  iconText: "󰑖"
                  tooltipText: taskRow.task && taskRow.task.repeat === "daily" ? "Repeats daily — make it weekly"
                    : (taskRow.task && taskRow.task.repeat === "weekly" ? "Repeats weekly — make it a one-off"
                    : "Repeat this daily")
                  foreground: taskRow.task && taskRow.task.repeat ? root.foreground : root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (taskRow.task) store.cycleRepeat(taskRow.task.id)
                }

                // Points the way the task is going: right toward This Month,
                // left back toward Today, matching the order of the tabs above.
                PanelActionButton {
                  id: moveButton
                  anchors.right: removeButton.left
                  anchors.rightMargin: Style.spacing.xxs
                  anchors.verticalCenter: parent.verticalCenter
                  visible: taskRow.hasCursor && root.taskTab
                  iconText: root.activeTab === "month" ? "󰅁" : "󰅂"
                  tooltipText: root.activeTab === "month" ? "Move to Today" : "Move to This Month"
                  foreground: root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (taskRow.task) root.moveTask(taskRow.task.id)
                }

                PanelActionButton {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.xs
                  anchors.verticalCenter: parent.verticalCenter
                  visible: taskRow.hasCursor
                  iconText: "󰅖"
                  tooltipText: "Delete"
                  foreground: root.dim
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: if (taskRow.task) store.remove(taskRow.task.id)
                }

                Text {
                  id: meta
                  textFormat: Text.PlainText
                  anchors.right: repeatButton.left
                  anchors.rightMargin: Style.spacing.xs
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowDelegate.modelData.meta
                  // Only an age is a warning. A cadence and a completion time
                  // are plain facts, and get the muted color.
                  color: (taskRow.done || rowDelegate.modelData.metaTone !== "age")
                    ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: checkbox.right
                  anchors.leftMargin: Style.spacing.sm
                  anchors.right: meta.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: taskRow.task ? taskRow.task.text : ""
                  color: taskRow.done ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.strikeout: taskRow.done
                  elide: Text.ElideRight
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: root.rows.length === 0
            text: root.emptyText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.footerText
          color: store.corrupt ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
