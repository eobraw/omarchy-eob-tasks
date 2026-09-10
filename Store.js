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
//
// Recurrence works the same way. A repeating task is never "done": completing
// it stamps `lastDoneOn` and files a dated snapshot in the archive, and the
// task itself is simply hidden from its list until `lastDoneOn` + the interval
// comes round. So "back tomorrow" is a comparison against today's date, not a
// job that has to run at midnight while the laptop is shut.

.pragma library

var VERSION = 2
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

// Rolling intervals rather than calendar buckets: a weekly task completed on a
// Friday is due again the next Friday, not on whatever day the week is deemed
// to start. "" is the third state of the cycle — not repeating at all.
var REPEAT_INTERVALS = { daily: 1, weekly: 7 }
var REPEAT_ORDER = ["", "daily", "weekly"]

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

// Component-wise again, and through Date so month ends and DST are the
// calendar's problem: setDate(32) rolls into the next month on its own.
function addDays(key, days) {
  var date = parseDayKey(key)
  if (!date) return null
  date.setDate(date.getDate() + days)
  return dayKey(date)
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
function normalizeRepeat(raw) {
  var value = String(raw === undefined || raw === null ? "" : raw).toLowerCase()
  return REPEAT_INTERVALS[value] ? value : ""
}

function normalizeTask(raw) {
  if (!raw || typeof raw !== "object") return null
  var text = String(raw.text === undefined || raw.text === null ? "" : raw.text).trim()
  if (text === "") return null

  var done = raw.done === true
  var completedAt = done ? String(raw.completedAt || new Date().toISOString()) : null
  // Two invariants the rest of the file leans on, enforced here so a hand-edit
  // can't break them: a done task is never a repeating one (it is a snapshot of
  // a completion, or a plain finished task), and a stamp without a repeat is
  // meaningless.
  var repeat = done ? "" : normalizeRepeat(raw.repeat)
  var lastDoneOn = repeat && parseDayKey(raw.lastDoneOn) ? String(raw.lastDoneOn) : null

  return {
    id: raw.id ? String(raw.id) : freshId(),
    text: text,
    scope: raw.scope === "month" ? "month" : "day",
    createdOn: parseDayKey(raw.createdOn) ? String(raw.createdOn) : dayKey(new Date()),
    done: done,
    completedAt: completedAt,
    repeat: repeat,
    // The day the repeating task was last ticked off; what hides it until the
    // interval is up.
    lastDoneOn: lastDoneOn,
    // On a snapshot, the id of the repeating task it came from — the link that
    // lets reopening it from the archive put the task back on the list.
    origin: done && raw.origin ? String(raw.origin) : null
  }
}

// Every mutation builds new task objects rather than editing in place, so QML's
// `var` bindings actually see a change. One clone helper keeps the field list
// in a single place.
function withFields(task, changes) {
  var out = {
    id: task.id,
    text: task.text,
    scope: task.scope,
    createdOn: task.createdOn,
    done: task.done,
    completedAt: task.completedAt,
    repeat: task.repeat || "",
    lastDoneOn: task.lastDoneOn || null,
    origin: task.origin || null
  }
  for (var key in changes) out[key] = changes[key]
  return out
}

// --- recurrence -------------------------------------------------------------

// The day a repeating task comes back. Never completed yet means it is due from
// the day it was written down.
function repeatDueOn(task) {
  if (!task || !task.repeat) return null
  if (!task.lastDoneOn) return task.createdOn
  return addDays(task.lastDoneOn, REPEAT_INTERVALS[task.repeat] || 1)
}

// Day keys are zero-padded ISO, so a string compare is a date compare.
function isDue(task, now) {
  if (!task || !task.repeat) return true
  var due = repeatDueOn(task)
  return !due || dayKey(now) >= due
}

function repeatLabel(task) {
  return task && task.repeat ? task.repeat : ""
}

function nextRepeat(repeat) {
  var index = REPEAT_ORDER.indexOf(normalizeRepeat(repeat))
  return REPEAT_ORDER[(index + 1) % REPEAT_ORDER.length]
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
function pending(tasks, scope, now) {
  var when = now || new Date()
  var out = []
  for (var i = 0; i < tasks.length; i++)
    if (!tasks[i].done && tasks[i].scope === scope && isDue(tasks[i], when)) out.push(tasks[i])

  out.sort(function (a, b) {
    if (a.createdOn !== b.createdOn) return a.createdOn < b.createdOn ? -1 : 1
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)
  })
  return out
}

function pendingCount(tasks, scope, now) {
  var when = now || new Date()
  var count = 0
  for (var i = 0; i < tasks.length; i++)
    if (!tasks[i].done && tasks[i].scope === scope && isDue(tasks[i], when)) count += 1
  return count
}

// A repeating task is meant to keep coming back, so "carried 12d" would be
// noise on every one of them; its cadence is the useful thing to show instead.
function ageLabel(task, now) {
  if (task.repeat) return repeatLabel(task)

  var created = parseDayKey(task.createdOn)
  if (!created) return ""

  if (task.scope === "month") {
    var months = monthsBetween(created, now)
    return months > 0 ? "carried " + months + "mo" : ""
  }
  var days = daysBetween(created, now)
  return days > 0 ? "carried " + days + "d" : ""
}

// Repeating tasks are excluded on the same reasoning: one that is due today is
// on schedule, not a backlog the bar should turn urgent over.
function overdueCount(tasks, now) {
  var count = 0
  for (var i = 0; i < tasks.length; i++)
    if (!tasks[i].done && !tasks[i].repeat && ageLabel(tasks[i], now) !== "") count += 1
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
  var items = pending(tasks, scope, now)
  var rows = []
  for (var i = 0; i < items.length; i++)
    rows.push({
      kind: "task",
      key: items[i].id,
      task: items[i],
      meta: ageLabel(items[i], now),
      // "age" is a warning (something is being dodged); "repeat" is just a fact
      // about the task, so the panel colors the two differently.
      metaTone: items[i].repeat ? "repeat" : "age",
      label: ""
    })
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
      rows.push({ kind: "header", key: "h-" + key, task: null, meta: "", metaTone: "time", label: dayLabel(date, now) })
    }
    rows.push({ kind: "task", key: items[j].id, task: items[j], meta: timeLabel(date), metaTone: "time", label: "" })
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

function addTask(state, text, scope, now, repeat) {
  var task = normalizeTask({
    text: text, scope: scope, createdOn: dayKey(now), done: false, repeat: repeat
  })
  if (!task) return null
  return { version: VERSION, tasks: (state && state.tasks ? state.tasks : []).concat([task]) }
}

// What lands in the archive when a repeating task is ticked off. A plain done
// task, so the Done tab needs to know nothing about recurrence, plus `origin`
// so reopening it can find the task it came from.
function completionSnapshot(task, now) {
  return {
    id: freshId(),
    text: task.text,
    scope: task.scope,
    createdOn: dayKey(now),
    done: true,
    completedAt: now.toISOString(),
    repeat: "",
    lastDoneOn: null,
    origin: task.id
  }
}

// The archive entry a repeating task most recently produced, so that undoing
// from either side removes the same row.
function latestSnapshot(tasks, originId) {
  var best = null
  var bestTime = -Infinity
  for (var i = 0; i < tasks.length; i++) {
    var task = tasks[i]
    if (!task.done || task.origin !== originId) continue
    var time = Date.parse(task.completedAt)
    if (isNaN(time)) time = 0
    if (time >= bestTime) {
      bestTime = time
      best = task
    }
  }
  return best
}

// Completing a repeating task: stamp it and file the snapshot. It leaves its
// list on the spot and comes back on its own once the interval is up.
function completeRepeat(source, task, now) {
  var tasks = []
  for (var i = 0; i < source.length; i++)
    tasks.push(source[i].id === task.id ? withFields(source[i], { lastDoneOn: dayKey(now) }) : source[i])
  tasks.push(completionSnapshot(task, now))
  return { version: VERSION, tasks: tasks }
}

// Undoing one: the snapshot leaves the archive and the task loses its stamp, so
// it is back on its list immediately. `snapshotId` may be null when the undo
// came from the task rather than from the archive row.
function reopenRepeat(source, originId, snapshotId) {
  var tasks = []
  for (var i = 0; i < source.length; i++) {
    var task = source[i]
    if (snapshotId && task.id === snapshotId) continue
    tasks.push(task.id === originId ? withFields(task, { lastDoneOn: null }) : task)
  }
  return { version: VERSION, tasks: tasks }
}

function setDone(state, id, done, now) {
  var source = state && state.tasks ? state.tasks : []
  var target = findTask(state, id)
  if (!target) return null

  // A repeating task never carries `done`; ticking it stamps the day instead.
  if (target.repeat) {
    if (done) return target.lastDoneOn === dayKey(now) ? null : completeRepeat(source, target, now)
    if (!target.lastDoneOn) return null
    var snapshot = latestSnapshot(source, target.id)
    return reopenRepeat(source, target.id, snapshot ? snapshot.id : null)
  }

  // Reopening a snapshot is the undo for the completion that made it: the task
  // it came from goes back on its list and the archive row disappears. An
  // orphaned snapshot (its task deleted since) just reopens as an ordinary
  // task.
  if (!done && target.done && target.origin && findTask(state, target.origin))
    return reopenRepeat(source, target.origin, target.id)

  if (target.done === done) return null

  var tasks = []
  for (var i = 0; i < source.length; i++) {
    var task = source[i]
    tasks.push(task.id !== id ? task : withFields(task, {
      done: done,
      completedAt: done ? now.toISOString() : null,
      origin: done ? task.origin : null
    }))
  }
  return { version: VERSION, tasks: tasks }
}

// --- recurrence mutations ---------------------------------------------------

// Only pending tasks can repeat: an archive row is a record of one completion,
// and making it recur would mean rewriting history.
function setRepeat(state, id, repeat) {
  var wanted = normalizeRepeat(repeat)
  var source = state && state.tasks ? state.tasks : []
  var tasks = []
  var changed = false

  for (var i = 0; i < source.length; i++) {
    var task = source[i]
    if (task.id !== id || task.done || (task.repeat || "") === wanted) {
      tasks.push(task)
      continue
    }
    changed = true
    // Dropping the repeat drops the stamp with it; switching cadence keeps it,
    // so flipping daily to weekly counts from the last time it was done.
    tasks.push(withFields(task, { repeat: wanted, lastDoneOn: wanted ? task.lastDoneOn : null }))
  }
  return changed ? { version: VERSION, tasks: tasks } : null
}

function cycleRepeat(state, id) {
  var task = findTask(state, id)
  return task && !task.done ? setRepeat(state, id, nextRepeat(task.repeat)) : null
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
    tasks.push(withFields(task, { scope: wanted }))
  }
  return changed ? { version: VERSION, tasks: tasks } : null
}

function moveTask(state, id) {
  var task = findTask(state, id)
  return task ? setScope(state, id, otherScope(task.scope)) : null
}

// Lets a typed line pick its own bucket regardless of which tab or toggle is
// active: "m: pay rent" is monthly, "d: buy milk" is daily, anything else falls
// back to whatever the UI had selected. "daily:" and "weekly:" make it a
// recurring task, leaving the bucket to the fallback — the spelled-out words
// are matched first so "d:" keeps meaning today.
function splitScope(text, fallbackScope) {
  var scope = fallbackScope === "month" ? "month" : "day"
  var raw = String(text || "")
  var m = /^\s*(daily|weekly|[md])\s*:\s*([\s\S]*)$/i.exec(raw)
  if (!m) return { text: raw.trim(), scope: scope, repeat: "" }

  var tag = m[1].toLowerCase()
  if (tag === "daily" || tag === "weekly")
    return { text: m[2].trim(), scope: scope, repeat: tag }
  return { text: m[2].trim(), scope: tag === "m" ? "month" : "day", repeat: "" }
}
