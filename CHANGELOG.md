# Changelog

All notable changes to niri-spaces are recorded here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `## [X.Y.Z]` heading shape is load-bearing, not a style choice:
`.github/workflows/release.yml` extracts everything between one such heading and the
next to use as the GitHub Release notes, and refuses to publish a tag that has no
section here. The tag being released must match the heading it releases.

## [0.4.0] - 2026-11-09

### Added
- `@workspace` name resolution. A name nothing bears yet is created fresh and
  named; a name an empty workspace already bears is reused; a name that already
  holds windows opens a new `"<name> 2"` sibling instead of merging into the
  busy workspace. Every `@workspace` line resolves against the live compositor,
  so a later section re-mentioning a name an earlier section just created sees
  it occupied and opens the sibling rather than a duplicate slot.
- `niri-spaces menu` numbers its popup rows: typing a row's number narrows the
  fuzzel list to that entry alone, so a space opens by typing its number and
  pressing Enter. The terminal fallback is unchanged.
- `niri-workspace-strip`, an optional coloured workspace strip (off by
  default): one numbered chip per workspace, wearing the background and accent
  of the colour scheme its workspace bears. A click focuses; a drag of chip i
  onto position j performs exactly `move-workspace-to-index <j>
  --reference <i>`, and the colour travels with the workspace because the
  colour is the workspace's name. The strip reserves no space and can be
  dropped below a bar that owns the corner.
- `niri-spaces workspace-strip [--check | status | reorder FROM TO]`: validate
  settings and GTK bindings without touching a compositor, print the chips in
  displayed order, or perform a drag's exact move from the command line.
- Settings: `workspace_strip` toggle (default false), `workspace_strip_height`
  (16-128 logical px, default 30) and `workspace_strip_margin_top` (0-512 px,
  default 0, which sits the strip in the corner itself).
- `niri-spaces start` spawns the strip alongside the other watchers after the
  layouts load; with the feature off it ends quietly, so it is safe to keep it
  in autostart.
- Release packaging, installer support and regression tests for all of the above.

### Fixed
- `niri-workspace-colors` was committed without its executable bit, so a
  `start` run straight from a checkout silently skipped the color watcher.
  Packaged installs were unaffected because packaging rewrites member modes,
  which is exactly why the bug survived a release.

### Notes
- niri cannot create a named workspace on demand, so the create path parks the
  first window in a fresh slot (moving it past the last workspace appends one)
  and names the slot afterwards; later windows then move by name.
- Reordering preserves colours by construction: niri moves the workspace, name
  and all, and the strip holds no order state of its own.
- The strip is the first feature with a dependency beyond the Python standard
  library: `python3-gi` with GTK 3 and the `gtk-layer-shell` bindings, from
  your distribution.

## [0.3.0] - 2026-11-07

### Added
- Per-workspace color schemes that persist until the workspace is destroyed.
  Every NEW workspace receives a scheme from a classic palette (teal, purple,
  neon, yellow, green, maroon, blue, nord — the theme families both work
  machines already ship) while workspaces that already exist keep the machine
  theme. When the workspace is closed its scheme entry is removed, and nothing
  is written that niri's own parser would not accept.
- `niri-workspace-colors`, a Python watcher (off by default, like
  terminal pairing): it follows niri's event stream, gives each new unnamed
  workspace a free scheme name, and keeps the include file
  `~/.config/niri/workspace-colors.kdl` in sync with the live workspaces.
  niri's built-in config watcher applies the change within half a second, so
  the helper never signals a reload and never polls the compositor.
- `niri-spaces workspace-colors [--check | status | recolor [REF] | clear]`:
  validate the settings, report the live schemes, give one workspace (by the
  index niri displays, or by name — or every managed workspace with no
  reference) a fresh scheme, or hand the managed workspaces back and drop
  their schemes.
- Settings: `workspace_colors` toggle (default false),
  `workspace_color_assignment` (`random` or `sequential`) and custom
  `workspace_color_schemes`.
- `niri-spaces start` now launches the watcher after the layouts load,
  alongside the terminal-pairs watcher.
- Release packaging, installer support and regression tests for the watcher.

### Notes
- A scheme name may only enter the include file while a live workspace bears
  it, because niri creates an empty workspace for every config name without a
  bearer; the watcher therefore renames first and prunes from a fresh
  snapshot afterwards, and pre-validates every candidate file with
  `niri validate` before installing it.
- A workspace the user renames or un-names is handed back and left alone
  from then on; workspaces the user names by hand are never touched.

## [0.2.0] - 2026-11-06

### Added
- Optional 50/50 terminal pairing, integrated from the standalone helper.
- `settings.json` with an off-by-default toggle and configurable terminal app IDs.
- `niri-spaces terminal-pairs [--check]` and session-start watcher launch after layouts load.
- Release packaging, installer support and regression tests for the watcher.


## [Unreleased]

## [0.1.0] - 2026-11-04

First public release. This is the rewrite that made the repository say what the
code does: the CLI documented in the README is the CLI that ships, the spaces it
names are the spaces that are deployed, and installation is verified rather than
piped-and-hoped.

### Added

- **The `niri-spaces` CLI** — `load <name> [args...]` for spaces and templates,
  `start` for the autostart list, `menu` for an interactive picker (fuzzel when it is
  installed, a plain terminal select otherwise), and `list`. It checks for `jq` and
  `niri` on PATH before doing anything: without `jq` the before/after diff of
  `niri msg --json windows` that learns each spawned window's id yields nothing, so
  every app hits the 10-second "no new window appeared" timeout and the failure looks
  like a slow compositor.
- **The `.space` layout format** — `@workspace <name-or-index>`, one line per app,
  `<app_id> | <launch command> [| <env vars> [| <capture var>]]`, and
  `@action <shell command>` for the captured window ids. Both the `app_id` and the
  command fields expand shell variables; fields are split on `|`, so a launch command
  must not contain a pipe character.
- **Templates** — `templates/<name>.space` with `$1` through `$9` substituted from
  `load`'s arguments, so one file can describe a whole family of workspaces — one
  workspace per service in a project, say, loaded as
  `niri-spaces load service 3 api`.
- **Autostart** — `~/.config/niri-spaces/autostart` is a list of `load <name>` lines
  that `niri-spaces start` runs in order and then lands on workspace 1; the shipped
  file loads `main` and `web`, which are the layouts the installer actually deploys.
- **`space-splash`** — an ASCII-art box with the directory name, the git branch, the
  last commit and the status, meant for a terminal's start hook.
- **Portable `$TERMINAL`/`$BROWSER` resolution** — the shipped spaces name no
  application: at load time the first installed of `ghostty`/`foot`/`alacritty`/
  `kitty` and of `brave-origin`/`brave`/`firefox`/`google-chrome`/`chromium` is
  picked, the matching `app_id` is derived (`TERMINAL_APPID`/`BROWSER_APPID`), and
  window matching is a prefix match, so `brave` covers `brave-browser-nightly`.
  Anything already exported wins.
- **Default spaces** — `main` (zenith system monitor on the left, browser on the
  right), `web` (terminal and browser) and `default` (a single-workspace fallback).
- **A keybind that is suggested, not written** — the installer prints the exact
  `Mod+Ctrl+Shift+S` line to add to `~/.config/niri/config.kdl` (or
  `~/.config/niri/cfg/keybinds.kdl` for the split layout) and how to autostart
  `niri-spaces start`, and edits nothing.
- **A release-based installer** — `install.sh` now installs from the public GitHub
  release of `lariocpt/niri-spaces`, resolving the latest one through the
  `/releases/latest` redirect or pinning with `--tag=`. The archive is verified
  against its `.sha256` before anything else runs, bins go to `$PREFIX/bin` and the
  config files are copied only where they do not already exist. It no longer symlinks
  a repository checkout onto PATH and no longer edits `~/.config/niri/config.kdl`;
  `--file=` plus `--sha256=` is a testing hook that installs a local artifact with the
  same verification, for CI before a release exists.
- **LICENSE, CHANGELOG.md and .editorconfig** — the repository's public hygiene
  files; the license is the same MIT text and holder line sleepless and smartopen
  carry.

### Fixed

- **The repository shipped a decoy CLI.** The README documented `load`/`start`/
  `menu`/`list`; the script was 40 lines of hardcoded `niri msg action` calls
  implementing none of it, and the autostart referenced files that were never
  deployed. The real CLI — including the `main` and `web` spaces and an autostart
  that loads files that actually ship — now lives in the repository.
- **`$TERMINAL_APPID` in the `app_id` column never expanded.** The command field is
  eval'd, but `app_id` was used literally, so the prefix match silently never fired,
  every app hit the 10-second "no new window appeared" timeout, and it looked like
  niri being slow.
- **The preflight asserted a string that no longer existed.** The `jq` guard had
  become a loop over both dependencies, but the self-test still grepped for the old
  one-deps error literal, so it failed every run and masked which CLI was actually
  deployed.
- **Terminal autodetection picked emulators that cannot run zenith.** `wezterm`
  (`start --`) and `xterm` (`-title`) do not accept the `--title=X -e COMMAND` form
  `main.space` uses, so they are no longer auto-detected; `app_id_for` still maps
  wezterm for anyone who exports `TERMINAL=wezterm` deliberately, and the zenith line
  is then on them.
- **Workspace command dispatch, the autostart load loop, and the app-spawn commands**
  had their bugs fixed in one pass over the layout framework.
- **`--prefix` promised a directory it does not use.** Both help texts said "where the
  bins go", while the installer appends `bin` to the value — so the flag is an install
  root. A reader who took the help literally and passed `--prefix=$HOME/.local/bin` got
  the bins in `~/.local/bin/bin`, with a PATH warning about a directory nobody chose.
  The help and the README now say install root, bins in `DIR/bin`, which is what the
  `$PREFIX/bin` line in this section always described.

<!-- Link definitions live at the bottom (Keep a Changelog convention). They are
     kept OUT of any release note: release.yml stops extracting at the first line
     that looks like one of these, so the note ends with the prose. -->
[Unreleased]: https://github.com/lariocpt/niri-spaces/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lariocpt/niri-spaces/releases/tag/v0.1.0

