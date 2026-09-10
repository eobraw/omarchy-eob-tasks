import QtQuick
import Quickshell
import Quickshell.Io
import "Store.js" as Store

// Owns tasks.json: loads it, watches it, and writes it back atomically.
//
// Both halves of this tracker (the bar panel and the quick-add overlay) run
// their own instance against the same path, so `watchChanges` is what keeps
// them in sync — a task captured in the overlay appears in the panel, and in
// the bar count, without either side knowing the other exists.
Item {
  id: root

  // Nested under an `omarchy/` parent and keyed on the plugin id, matching how
  // first-party plugins lay out their files (~/.local/state/omarchy/...). The
  // id is the one name guaranteed unique across plugins, so two authors' task
  // trackers can coexist. XDG_DATA_HOME rather than STATE: these are the user's
  // own notes, the kind of thing a backup should pick up.
  readonly property string dir: (Quickshell.env("XDG_DATA_HOME")
    || (Quickshell.env("HOME") + "/.local/share")) + "/omarchy/eobraw.tasks"
  readonly property string path: dir + "/tasks.json"

  // Replaced wholesale on every change; QML only re-evaluates a `var` binding
  // when the reference itself changes, so the mutators in Store.js never edit
  // in place.
  property var state: Store.emptyState()
  property bool loaded: false

  // True when the file exists but does not parse. Writes are refused while it
  // is set, so a hand-edit typo can't be turned into data loss by the next
  // click.
  property bool corrupt: false

  // Drives every date-derived binding below. The clock advances it, which is
  // how "carried 3d" and the bar count follow a day rolling over under a shell
  // that has been running since yesterday.
  property var now: new Date()

  readonly property var tasks: state && state.tasks ? state.tasks : []
  // `now` is a dependency, not decoration: a repeating task completed today
  // drops out of these counts and reappears in them once the clock rolls the
  // day over, without anything having to write to the file.
  readonly property int dailyCount: Store.pendingCount(tasks, "day", now)
  readonly property int monthlyCount: Store.pendingCount(tasks, "month", now)
  readonly property int overdueCount: Store.overdueCount(tasks, now)

  function dailyRows() { return Store.pendingRows(tasks, "day", now) }
  function monthlyRows() { return Store.pendingRows(tasks, "month", now) }
  function completedRows() { return Store.completedRows(tasks, now) }

  function apply(next) {
    if (!next) return false
    if (root.corrupt) {
      console.warn("tasks: refusing to overwrite unparseable", root.path)
      return false
    }
    root.state = next
    file.setText(Store.serialize(next))
    return true
  }

  function add(text, scope, repeat) { return apply(Store.addTask(root.state, text, scope, new Date(), repeat)) }
  function toggle(id) { return apply(Store.toggleDone(root.state, id, new Date())) }
  function remove(id) { return apply(Store.removeTask(root.state, id)) }
  function move(id) { return apply(Store.moveTask(root.state, id)) }
  function setRepeat(id, repeat) { return apply(Store.setRepeat(root.state, id, repeat)) }
  function cycleRepeat(id) { return apply(Store.cycleRepeat(root.state, id)) }

  function ingest(text) {
    var parsed = Store.parse(text)
    root.corrupt = parsed === null
    if (parsed) root.state = parsed
    root.loaded = true
  }

  // FileView can't create a missing parent, and atomicWrites needs the
  // directory to exist before the first save. Load only once mkdir has
  // returned so a first run doesn't log a spurious failure.
  Process {
    id: ensureDir
    running: true
    command: ["mkdir", "-p", root.dir]
    onExited: file.reload()
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ingest(text())
    onLoadFailed: root.ingest("")   // first run: the file simply isn't there yet
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.now = clock.date
  }
}
