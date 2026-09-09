# Tasks — an Omarchy shell plugin

A daily and monthly task tracker that lives in the Omarchy bar. Unfinished
tasks carry forward on their own, so nothing quietly disappears at midnight.

![Adding a task, moving it to This Month with `m`, moving it back, and completing it](docs/demo.gif)

- **Bar widget** — a checkbox icon with today's pending count, colored urgent
  when something has been carried over.
- **Panel** — `Today` / `This Month` / `Done` / `About` tabs. Type to add,
  click or press `Space` to complete, `m` to move a task between the two lists.
- **Quick add overlay** — a global hotkey opens a centered capture box from
  anywhere; type, press Enter, it's saved.
- **Completed archive** — everything you've finished, grouped by the day it
  was completed, with the time.
- Themed by Omarchy: colors, fonts and borders follow your active theme with
  no restart.

## Carry-forward

Roll-over is **computed, not migrated**. A pending daily task always appears
under Today and a pending monthly task always under This Month, and its
original `createdOn` never changes.

That means there is no midnight job that can fail to run, run twice, or lose a
task to a half-finished write — and it behaves correctly when the machine was
asleep or powered off across midnight or a month boundary. Because the original
date is kept, the panel can show how long something has been dodged
(`carried 3d`, `carried 2mo`) and sorts the oldest stragglers to the top.

## Install

```bash
omarchy plugin add https://github.com/eobraw/omarchy-eob-tasks
omarchy plugin enable eobraw.tasks --after omarchy.clock
```

`omarchy plugin add` clones the repo and leaves the plugin **disabled** — shell
plugins run unsandboxed, so read the code before enabling it. The install
directory comes from the `id` in `manifest.json`, not from the repo name, so
this lands in `~/.config/omarchy/plugins/eobraw.tasks/`.

`enable` takes the bar placement directly; `--after`, `--before`, `--section`
and `--index` all work, or drop the flag to accept the default (center).

### Keybindings

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "Add task", "omarchy-shell shell toggle eobraw.tasks")
o.bind("SUPER + ALT + T", "Tasks", "omarchy-shell -q eobraw.tasks toggle")
```

The plugin declares both `bar-widget` and `overlay` kinds, so
`shell toggle <id>` routes to the overlay and the panel is reached through its
own IPC target. Pick combinations that are free on your system — Omarchy uses
`SUPER + T` for float toggle and `SUPER + CTRL + T` for a terminal.

## Keys

| Key | Action |
|---|---|
| `Super + Shift + T` | Quick add from anywhere |
| `Super + Alt + T` | Open the panel |
| `Tab` / `Shift + Tab` | Switch tabs |
| `j` / `k`, `↓` / `↑` | Move between tasks |
| `Space` / `Enter` | Complete or reopen a task |
| `m` | Move the selected task between Today and This Month |
| `x` | Delete the selected task |
| `a` | Jump to the add field |
| `Esc` | Close |

On a pending tab a hovered or selected row also grows a `›` / `‹` button that
moves it to the other list. A moved task keeps its original `createdOn`, so
pushing a straggler out to This Month does not reset its age — and the move is
reversible with nothing lost.

In either input, `m:` files a task under This Month and `d:` under Today. In
the overlay, `Shift + Enter` adds as monthly and `Ctrl + Enter` adds without
closing, for capturing several in a row.

The **About** tab in the panel carries this same reference, so you never have
to come back here for it.

## Data

Plain JSON at `~/.local/share/omarchy/eobraw.tasks/tasks.json`, written atomically and
watched for changes — edit it by hand and the bar updates immediately.

```json
{
  "version": 1,
  "tasks": [
    {
      "id": "t-1757260800123",
      "text": "Pay rent",
      "scope": "month",
      "createdOn": "2026-09-01",
      "done": false,
      "completedAt": null
    }
  ]
}
```

`scope` is `day` or `month`; `completedAt` is a full ISO timestamp. If the file
ever fails to parse, the plugin refuses to write over it and says so in the
panel footer rather than replacing your tasks with an empty list.

## Layout

| File | Purpose |
|---|---|
| `Panel.qml` | Bar button, popup, tabs, rows, About reference |
| `QuickAdd.qml` | The global capture overlay |
| `TaskStore.qml` | Loads, watches and atomically writes `tasks.json` |
| `Store.js` | Pure logic: parsing, dates, carry-forward, mutations. No QML. |

## Requirements

Omarchy 4.x (built and tested against 4.0.2).

## Notes

Editing a plugin file does not reliably reload an already-mounted bar widget —
run `omarchy restart shell` after changes. QML errors show up in
`journalctl --user -f | grep -i qml`, but `console.log` from a user plugin does
not, so it is no use for tracing your own code.

On a multi-monitor setup only one bar instance can own the `eobraw.tasks` IPC
target, so `Super + Alt + T` may open the panel on the other screen. Clicking
the bar icon always uses the right one.

## License

MIT
