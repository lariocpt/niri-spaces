# niri-spaces

Declarative workspace layouts for [niri](https://github.com/YaLTeR/niri).

One plain-text file says which apps open on which workspace. `niri-spaces load`
reads it, launches each app, waits for its window, moves it onto the right
workspace and sizes the column — then steps aside. By default nothing stays running in
the background, and every move it makes is a `niri msg` call you could type
yourself.

<!-- BEGIN GENERATED SHOWCASE (tools/gen-showcase.py) -->
```text
┌────────────────────────────────────────────────────┐
│                 ▐   ▐ ▐▀▀▀  ▐▀▀▄                   │
│                 ▐   ▐ ▐▀▀   ▐▄▄▀                   │
│                 ▐ █ ▐ ▐     ▐   █                  │
│                  ▀ ▀  ▐▄▄▄  ▐▄▄▀                   │
├────────────────────────────────────────────────────┤
│ Workspace: web                                     │
│ Path:      ~/dev/projects/web                      │
│ Branch:    main                                    │
│ Commit:    declarative layouts (2 hours ago)       │
│ Status:    0 modified files                        │
└────────────────────────────────────────────────────┘
```
<!-- END GENERATED SHOWCASE -->

That box is `space-splash` — the real program's output for a `web` workspace,
spliced in by `tools/gen-showcase.py` so it cannot drift from what the code
prints. It shows the folder, its git branch and its latest commit.

## Install

One command:

```sh
curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh
```

It takes the repository's **latest** release. To install a specific one instead:

```sh
curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh -s -- --tag=v0.1.0
```

To see exactly what it would do, and do nothing:

```sh
curl -fsSL https://lariocpt.github.io/niri-spaces/install.sh | sh -s -- --dry-run
```

The archive is fetched and checked against its SHA-256 **before** anything is
installed — it refuses to run an artifact it cannot verify. Then it puts
`niri-spaces`, `space-splash`, `niri-terminal-pairs`, `niri-workspace-colors` and
`niri-workspace-strip` in `~/.local/bin` and
copies settings, the example spaces and an `autostart` file into `~/.config/niri-spaces/`. Config files are copied
only where they don't already exist, so a file you edited is kept.

**It does not edit your niri config.** It prints the keybind line to add and
leaves the decision to you.

`--prefix=DIR` sets the install root — the bins land in `DIR/bin` — `-h` shows all the
options, and `NIRI_SPACES_REPO` points it at a fork.

## Then wire it up in niri

Two lines, in `~/.config/niri/config.kdl` (or `~/.config/niri/cfg/keybinds.kdl`
if your config uses the `cfg/` split). These are the lines the installer prints
for you — it prints them rather than writing them, because your config is yours.

Have niri's autostart run:

```
niri-spaces start
```

and bind the picker to a key:

```kdl
Mod+Ctrl+Shift+S hotkey-overlay-title="Niri Spaces: Menu" { spawn "niri-spaces" "menu"; }
```

Reload niri and load your first layout:

```sh
niri-spaces load default
```

`menu` opens a picker — `fuzzel` when it's installed and you're on a Wayland
session, otherwise a plain terminal `select` prompt. The popup lists every space
as a numbered row: typing a row's number narrows the list to that row alone, so
a space opens by typing its number and pressing Enter.

## Commands

```
niri-spaces load <name> [args...]   load spaces/<name>.space (or templates/<name>.space with $1..$9 substituted)
niri-spaces start                   run every `load ...` line in ~/.config/niri-spaces/autostart
niri-spaces menu                    pick a space from a numbered popup list (fuzzel if available, else terminal)
niri-spaces list                    list available spaces and templates
niri-spaces terminal-pairs [--check] run the optional 50/50 terminal watcher
niri-spaces workspace-colors [--check] run the optional per-workspace color scheme watcher
niri-spaces workspace-strip [--check | status | reorder FROM TO] the optional coloured workspace strip
```

The optional `terminal-pairs` subcommand runs the terminal watcher. The optional
`workspace-colors` subcommand runs the color scheme watcher (or its one-shot
`status`, `recolor` and `clear` forms — see below). The optional `workspace-strip`
subcommand runs the coloured workspace strip (or its one-shot `status` and
`reorder FROM TO` forms — see below). `start` runs each `load` line in
`autostart` in order, launches the enabled watchers, and finishes by focusing workspace 1.

## The `.space` format

A file is read top to bottom. A `@workspace` line sets the current workspace, and
every app line after it lands there:

| Line | Meaning |
|---|---|
| `@workspace <name-or-index>` | Following app lines target this workspace — a name or a number. An index is used as-is. A name nothing bears yet is created and named; a name already borne by an empty workspace is reused; a name already holding windows opens a fresh `"<name> 2"` (then `"<name> 3"`, …) so a load never dumps into a busy workspace. |
| `app_id \| command \| env \| capture` | Launch `command`, then find the window whose app id matches `app_id` and move it to the current workspace. `env` is exported for the launch; `capture` names a variable that receives the window id. Both are optional. |
| `@action <shell>` | Run a shell command, e.g. to focus a captured window and size its column. |
| `# …` | Comment. Blank lines are ignored. |

Fields are split on `|`, so a launch command can't contain a literal pipe — no
inline `||` fallbacks. Use `$TERMINAL` / `$BROWSER` instead.

`spaces/default.space`, the fallback the installer ships, verbatim except the
comments:

```
@workspace default
$TERMINAL_APPID | $TERMINAL | | terminal_id
$BROWSER_APPID  | $BROWSER  | | browser_id
@action [ -n "${terminal_id:-}" ] && niri msg action focus-window --id "$terminal_id" && niri msg action set-column-width "50%"
@action [ -n "${browser_id:-}" ] && niri msg action focus-window --id "$browser_id" && niri msg action set-column-width "50%"
```

Run it with `niri-spaces load default`. The shipped `autostart` loads `main` and
`web` instead: `web` is the terminal-and-browser pair on workspace 2, and `main`
is workspace 1 with a `zenith` system monitor in the left column — so `main`
needs `zenith` installed to be worth loading.

### Templates

`templates/<name>.space` may use `$1` … `$9`, substituted from `load`'s
arguments, so one file can describe a family of workspaces:

```sh
niri-spaces load service 3 api
```

### One file, many machines

Spaces name `$TERMINAL` / `$BROWSER` rather than a specific app. At load time the
first installed candidate wins — `ghostty`, `foot`, `alacritty`, `kitty` for the
terminal, and `brave-origin`, `brave`, `firefox`, `google-chrome`, `chromium` for
the browser — and the matching app id is derived for you (`$TERMINAL_APPID`,
`$BROWSER_APPID`). Window matching is a prefix match, so `brave` also covers
`brave-browser-nightly`. Export the variables yourself and your choice wins.

## Optional 50/50 terminals

The release includes the terminal pairing helper previously distributed separately.
In `~/.config/niri-spaces/settings.json`, set `"terminal_pairs": true` to enable
it, or `false` to disable it (the default). `niri-spaces start` launches the
watcher after loading layouts. Changes take effect at the next Niri login;
`niri-spaces terminal-pairs` can start it in the current session. Quit the old
watcher before changing its settings in the current session. An environment
override, `NIRI_SPACES_TERMINAL_PAIRS=0` or `1`, is also available.

Only windows whose app ID is in `terminal_app_ids` are eligible. The defaults
are `niri-spaces-terminal` and the legacy `work-plain-terminal`. For Foot, open
plain shells with `foot --app-id=niri-spaces-terminal`. Keep terminal apps
such as Yazi on their normal app IDs so they stay independent.

A new eligible terminal joins a lone eligible terminal immediately to its left,
on the same workspace, and both get equal height. A third opens a new column;
a fourth pairs with it. Existing windows, other apps and floating windows stay
where they are. The watcher takes a per-session lock, uses window IDs without
changing focus, and confirms the move before resetting heights. Niri 26.04 IPC
does not expose fullscreen or tabbed-column state; eligible IDs should be used
for ordinary tiled shell windows.

`niri-spaces terminal-pairs --check` validates settings without writes or IPC.
The helper needs Python 3 and a running Niri session. It exits when Niri's event
stream closes. To remove this feature, set `terminal_pairs` to false and log out
and back in; to undo the installation entirely, remove the installed
executables and the configuration directory after saving any custom layouts.

## Optional workspace colors

In `~/.config/niri-spaces/settings.json`, set `"workspace_colors": true` to
enable it, or `false` to disable it (the default). `niri-spaces start` launches
the watcher after the layouts load; with the feature off it ends quietly, so it
is safe to keep it in autostart. In a session that is already running, start it
with `niri-spaces workspace-colors` — quit the old watcher first if you change
its settings mid-session. The feature needs one line in your main niri config
file, so that the managed include is actually read:

```kdl
include "workspace-colors.kdl" optional
```

niri resolves the path against the config file's directory, so with the usual
`~/.config/niri/` layout this is the file the helper writes and keeps there.
The `optional` property matters: while the file does not exist yet — for
example, right after you add the line — a missing optional include is only a
warning, whereas a plain include would make the whole config fail to load. The
file's path is watched either way, so the first file the helper writes is
picked up automatically.

Each new unnamed workspace receives a scheme from a sixteen-color palette: the
eight classics — `teal`, `purple`, `neon`, `yellow`, `green`, `maroon`,
`blue`, `nord` — the dark backgrounds of the Color Terminal set both work
machines already ship, paired with the accent of the theme family they belong
to, plus eight extras — `crimson`, `cappuccino`, `lime`, `spring`, `indigo`,
`violet`, `fuchsia`, `silver` — placed in the hue gaps between the classics.
By default a free classic is picked at random and the extras are used only
when every classic is already held; `workspace_color_assignment:
"sequential"` hands the palette out in order (classics first) instead, and
`workspace_color_schemes` replaces it with your own names and colors. While
two workspaces exist at the same time they never show the same scheme — a
seventeenth workspace, with all sixteen names taken, is left unnamed rather
than have a name stolen from another. Workspaces that already exist when the
watcher starts keep the machine theme, and workspaces you name by hand are
never touched.

A scheme belongs to its workspace until the workspace is destroyed: the
watcher removes the workspace's entry from the include when the workspace
closes, a workspace that survives a reboot keeps its scheme, and entries for
workspaces that no longer exist are pruned at the next watcher start. The
scheme is a per-workspace `layout` part — background, focus ring, border,
shadow, tab indicator — declared under the workspace's scheme name. niri's
built-in config watcher reloads the include within half a second, so the
helper never signals a reload and never polls the compositor; it only watches
the event stream. Every fragment is validated with `niri validate` before it
is installed, so a running niri is never left with an error notification of
the helper's making.

The one-shot forms talk to the live compositor without running a watcher:
`niri-spaces workspace-colors status` reports the scheme on every workspace;
`recolor [REF]` gives one workspace a fresh scheme — REF is the workspace's
index as niri displays it, or its name — with no REF every managed workspace is
recolor-ed; and `clear` hands the managed workspaces back unnamed and drops
their schemes. `--check` validates the settings without writes or IPC.

The helper needs Python 3 and a running Niri session. It takes a per-session
lock and keeps its bookkeeping in `~/.config/niri-spaces/workspace-colors.json`.
To remove the feature, set `workspace_colors` to false, run
`niri-spaces workspace-colors clear`, and log out and back in.

## Optional workspace strip

In `~/.config/niri-spaces/settings.json`, set `"workspace_strip": true` to
enable it, or `false` to disable it (the default). `niri-spaces start` launches
the strip after the layouts load; with the feature off it ends quietly, so it
is safe to keep it in autostart. In a session that is already running, start it
with `niri-spaces workspace-strip` — quit the old strip first if you change its
settings mid-session.

The strip is a small overlay in the top-left corner: one numbered chip per live
workspace, labelled with the number niri displays. A chip wears the background
and accent of the colour scheme its workspace bears — the same schemes
`niri-workspace-colors` assigns and the same state file it keeps — so colours
carry over whether or not you use the color watcher's include file. The strip
reserves no space of its own (layer exclusive zone 0). `workspace_strip_height`
sizes it in logical pixels (16–128, default 30); `workspace_strip_margin_top`
(0–512, default 0) drops it below a bar that occupies the corner.

A plain click focuses that workspace — by name when it has one, by index when
it doesn't. Dragging chip *i* onto position *j* performs exactly one action,
`niri msg action move-workspace-to-index <j> --reference <i>`: niri shifts the
other workspaces, and because a managed workspace's name *is* its colour
scheme, the colour travels with the drag by construction.

The one-shot forms talk to the live compositor without running a daemon:
`niri-spaces workspace-strip status` prints the chips in displayed order;
`niri-spaces workspace-strip reorder FROM TO` performs the same move a drag
would, using the 1-based indexes niri displays. `--check` validates the
settings and the GTK bindings without writes or IPC.

Unlike the other helpers this one needs more than the Python standard library:
`python3-gi` with GTK 3 and the `gtk-layer-shell` introspection bindings, plus a
running niri session (`WAYLAND_DISPLAY`, `NIRI_SOCKET`, `XDG_RUNTIME_DIR`). It
takes a per-session lock so two strips never stack, and exits when the Wayland
display goes away. To remove the feature, set `workspace_strip` to false and log
out and back in.

## `space-splash`

A Python 3 script that prints the box at the top of this file: directory, git
branch, last commit, working-tree status. Point your terminal's start hook at it
and each terminal tells you where it is.

## Requirements

- **niri**, running. niri-spaces drives the compositor only through `niri msg`,
  so it needs a live niri session on Wayland. It is a niri tool — it does not
  manage X11 or other compositors.
- **bash** and **jq**. `jq` is not optional: the launcher diffs
  `niri msg --json windows` before and after each spawn to learn the new window's
  id, and without `jq` that diff silently yields nothing — every app then waits
  out the 10-second "no window appeared" timeout and it looks like a slow
  compositor instead of a missing dependency.
- **Python 3** for `space-splash` and the optional helpers. Standard library
  only, no pip installs — with one exception: the workspace strip additionally
  needs `python3-gi` (GTK 3) and the `gtk-layer-shell` bindings from your distro,
  and it is the only feature that does.

**What it is not:** it is not a session manager. It launches the apps a space
names and puts them where the file says. It does not restore windows you closed.

## Development

```sh
bats tests/                                          # the bash test suite
python3 -m unittest discover -s tests -p "test_*.py" # the Python helper suites
python3 tools/gen-showcase.py                        # re-splice the real splash into README + page
python3 tools/check-site.py                          # the docs honesty gate CI runs
shellcheck -s sh docs/install.sh                     # installer, in its real shebang's dialect
```

Run the installer against a local build without touching your system:

```sh
docs/install.sh --tag=v0.1.0 --dry-run
```

The test suite is [bats-core](https://github.com/bats-core/bats-core).
`tests/13_shells.bats` runs the installer end to end under bash, dash and busybox
ash, because `#!/bin/sh` is only as strict as whatever it happens to run under.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
