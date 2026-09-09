// Pure task-store logic: parsing, filtering, date arithmetic and mutation.
// No QML imports on purpose — everything here is plain JS that can be reasoned
// about (and pasted into a JS shell) on its own, mirroring the Model.js
// convention used by the first-party panels.
//
// Carry-forward is COMPUTED, never migrated. A pending "day" task always shows
// under Today and a pending "month" task always shows under This Month, so
// `createdOn` never changes and the age of a straggler stays visible. That is
// what makes rollover correct across a machine that was asleep or powered off
// at midnight: there is no midnight job that can fail to run, run twice, or
// lose a task to a half-finished write.

.pragma library

var VERSION = 1
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

// Date.now() alone repeats within a millisecond when tasks are added fast (or
// pasted); the counter keeps ids unique for the life of the process and the
// dedupe in parse() covers the cross-process case.
var _seq = 0

function pad2(n) { return n < 10 ? "0" + n : "" + n }

function dayKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function monthKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1)
}

// Parsed component-wise rather than through new Date(string): the ISO date form
// is specified to parse as UTC, which lands on the previous local day for every
// timezone west of Greenwich.
function parseDayKey(key) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(key || ""))
  if (!m) return null
  var date = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
  return isNaN(date.getTime()) ? null : date
}

function midnight(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

// Rounded because a DST boundary makes the span 23 or 25 hours.
function daysBetween(from, to) {
  return Math.round((midnight(to) - midnight(from)) / 86400000)
}

function monthsBetween(from, to) {
  return (to.getFullYear() - from.getFullYear()) * 12 + (to.getMonth() - from.getMonth())
}

function freshId() {
  _seq += 1
  return "t-" + Date.now() + "-" + _seq
}

function emptyState() {
  return { version: VERSION, tasks: [] }
}

// Returns null for a task that carries no usable text, so hand-edited junk is
// dropped rather than rendered as a blank row.
function normalizeTask(raw) {
  if (!raw || typeof raw !== "object") return null
  var text = String(raw.text === undefined || raw.text === null ? "" : raw.text).trim()
  if (text === "") return null

  var done = raw.done === true
  var completedAt = done ? String(raw.completedAt || new Date().toISOString()) : null

  return {
    id: raw.id ? String(raw.id) : freshId(),
    text: text,
    scope: raw.scope === "month" ? "month" : "day",
    createdOn: parseDayKey(raw.createdOn) ? String(raw.createdOn) : dayKey(new Date()),
    done: done,
    completedAt: completedAt
  }
}

// Returns null — distinctly from an empty state — when the file exists but does
// not parse. The caller must refuse to write in that case, so a typo in a
// hand-edit never costs the user their tasks.
function parse(text) {
  var raw = String(text || "").trim()
  if (raw === "") return emptyState()

  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return null
  }

  var list = parsed instanceof Array ? parsed
    : (parsed && parsed.tasks instanceof Array ? parsed.tasks : [])

  var tasks = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var task = normalizeTask(list[i])
    if (!task || seen[task.id]) continue
    seen[task.id] = true
    tasks.push(task)
  }
  return { version: VERSION, tasks: tasks }
}

function serialize(state) {
  var tasks = state && state.tasks instanceof Array ? state.tasks : []
  return JSON.stringify({ version: VERSION, tasks: tasks }, null, 2) + "\n"
}

// --- views ------------------------------------------------------------------

// Oldest first, so whatever has been carried the longest sits at the top and
// gets looked at first.
function pending(tasks, scope) {
  var out = []
  for (var i = 0; i < tasks.length; i++)
    if (!tasks[i].done && tasks[i].scope === scope) out.push(tasks[i])

  out.sort(function (a, b) {
    if (a.createdOn !== b.createdOn) return a.createdOn < b.createdOn ? -1 : 1
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)
  })
  return out
}

function pendingCount(tasks, scope) {
  var count = 0
  for (var i = 0; i < tasks.length; i++)
    if (!tasks[i].done && tasks[i].scope === scope) count += 1
  return count
}

function ageLabel(task, now) {
  var created = parseDayKey(task.createdOn)
  if (!created) return ""

  if (task.scope === "month") {
    var months = monthsBetween(created, now)
    return months > 0 ? "carried " + months + "mo" : ""
  }
  var days = daysBetween(created, now)
  return days > 0 ? "carried " + days + "d" : ""
}

function overdueCount(tasks, now) {
  var count = 0
  for (var i = 0; i < tasks.length; i++)
    if (!tasks[i].done && ageLabel(tasks[i], now) !== "") count += 1
  return count
}

function dayLabel(date, now) {
  var delta = daysBetween(date, now)
  if (delta === 0) return "Today"
  if (delta === 1) return "Yesterday"

  var label = DAY_NAMES[date.getDay()] + " " + date.getDate() + " " + MONTH_NAMES[date.getMonth()]
  return date.getFullYear() === now.getFullYear() ? label : label + " " + date.getFullYear()
}

function timeLabel(date) {
  var hours = date.getHours()
  var hour12 = hours % 12
  return (hour12 === 0 ? 12 : hour12) + ":" + pad2(date.getMinutes()) + (hours < 12 ? " AM" : " PM")
}

function completedAtDate(task) {
  var date = new Date(task.completedAt)
  return isNaN(date.getTime()) ? parseDayKey(task.createdOn) : date
}

// Both tabs feed one delegate, so pending and completed views produce the same
// row shape. `kind` is "task" or "header"; only "task" rows are cursor targets.
function pendingRows(tasks, scope, now) {
  var items = pending(tasks, scope)
  var rows = []
  for (var i = 0; i < items.length; i++)
    rows.push({ kind: "task", key: items[i].id, task: items[i], meta: ageLabel(items[i], now), label: "" })
  return rows
}

function completedRows(tasks, now) {
  var items = []
  for (var i = 0; i < tasks.length; i++) if (tasks[i].done) items.push(tasks[i])

  items.sort(function (a, b) {
    var ta = Date.parse(a.completedAt)
    var tb = Date.parse(b.completedAt)
    return (isNaN(tb) ? 0 : tb) - (isNaN(ta) ? 0 : ta)
  })

  var rows = []
  var currentKey = ""
  for (var j = 0; j < items.length; j++) {
    var date = completedAtDate(items[j]) || now
    var key = dayKey(date)
    if (key !== currentKey) {
      currentKey = key
      rows.push({ kind: "header", key: "h-" + key, task: null, meta: "", label: dayLabel(date, now) })
    }
    rows.push({ kind: "task", key: items[j].id, task: items[j], meta: timeLabel(date), label: "" })
  }
  return rows
}

// --- mutations --------------------------------------------------------------
//
// Each returns a brand-new state (so QML `var` bindings actually re-evaluate)
// or null when nothing changed, which the caller reads as "no write needed".

function findTask(state, id) {
  var tasks = state && state.tasks ? state.tasks : []
  for (var i = 0; i < tasks.length; i++) if (tasks[i].id === id) return tasks[i]
  return null
}

function addTask(state, text, scope, now) {
  var task = normalizeTask({ text: text, scope: scope, createdOn: dayKey(now), done: false })
  if (!task) return null
  return { version: VERSION, tasks: (state && state.tasks ? state.tasks : []).concat([task]) }
}

function setDone(state, id, done, now) {
  var source = state && state.tasks ? state.tasks : []
  var tasks = []
  var changed = false

  for (var i = 0; i < source.length; i++) {
    var task = source[i]
    if (task.id !== id || task.done === done) {
      tasks.push(task)
      continue
    }
    changed = true
    tasks.push({
      id: task.id,
      text: task.text,
      scope: task.scope,
      createdOn: task.createdOn,
      done: done,
      completedAt: done ? now.toISOString() : null
    })
  }
  return changed ? { version: VERSION, tasks: tasks } : null
}

function toggleDone(state, id, now) {
  var task = findTask(state, id)
  return task ? setDone(state, id, !task.done, now) : null
}

function removeTask(state, id) {
  var source = state && state.tasks ? state.tasks : []
  var tasks = []
  for (var i = 0; i < source.length; i++)
    if (source[i].id !== id) tasks.push(source[i])
  return tasks.length === source.length ? null : { version: VERSION, tasks: tasks }
}

// The bucket a task is not in. One task lives in exactly two places, so a
// "move" is always a flip and never needs a target argument.
function otherScope(scope) {
  return scope === "month" ? "day" : "month"
}

// Re-files a task under the other scope. `createdOn` deliberately survives the
// move: the task is the same task, and a straggler that has been sitting on
// Today for two weeks should keep saying so after it is pushed out to This
// Month. That also keeps the move reversible with no history lost.
function setScope(state, id, scope) {
  var wanted = scope === "month" ? "month" : "day"
  var source = state && state.tasks ? state.tasks : []
  var tasks = []
  var changed = false

  for (var i = 0; i < source.length; i++) {
    var task = source[i]
    if (task.id !== id || task.scope === wanted) {
      tasks.push(task)
      continue
    }
    changed = true
    tasks.push({
      id: task.id,
      text: task.text,
      scope: wanted,
      createdOn: task.createdOn,
      done: task.done,
      completedAt: task.completedAt
    })
  }
  return changed ? { version: VERSION, tasks: tasks } : null
}

function moveTask(state, id) {
  var task = findTask(state, id)
  return task ? setScope(state, id, otherScope(task.scope)) : null
}

// Lets a typed line pick its own bucket regardless of which tab or toggle is
// active: "m: pay rent" is monthly, "d: buy milk" is daily, anything else falls
// back to whatever the UI had selected.
function splitScope(text, fallbackScope) {
  var raw = String(text || "")
  var m = /^\s*([mMdD])\s*:\s*(.*)$/.exec(raw)
  if (!m) return { text: raw.trim(), scope: fallbackScope === "month" ? "month" : "day" }
  return { text: m[2].trim(), scope: (m[1] === "m" || m[1] === "M") ? "month" : "day" }
}
