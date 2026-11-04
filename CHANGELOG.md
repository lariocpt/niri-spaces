# Changelog

All notable changes to niri-spaces are recorded here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `## [X.Y.Z]` heading shape is load-bearing, not a style choice:
`.github/workflows/release.yml` extracts everything between one such heading and the
next to use as the GitHub Release notes, and refuses to publish a tag that has no
section here. The tag being released must match the heading it releases.

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

