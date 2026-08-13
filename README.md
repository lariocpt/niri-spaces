# NIRI SPACES

Niri Spaces is a layout configuration manager for the Niri Wayland compositor. It allows defining workspace layouts programmatically, templating repetitive workspace environments (e.g. monorepos), and displaying rich ASCII art splashes when terminals open.

## Features

- **Declarative layouts**: Load Niri workspace environments from clean config files.
- **Portable by default**: The shipped spaces launch `$TERMINAL` + `$BROWSER` rather than hard-coded apps, so the same config works on any machine.
- **Templating support**: Load monorepos dynamically by passing parameters (e.g., loading `myrepo-mono` with arguments `1` through `4`).
- **Rich ASCII Splashes**: Includes `space-splash`, which displays a gorgeous ASCII art box with directory names, Git branch, last commit info, and status.
- **Easy shortcuts**: Automatically binds `Mod+Ctrl+Shift+S` to reload/refresh all workspaces.

## Directory Structure

Configurations are placed in `~/.config/niri-spaces/`:

- `autostart`: File specifying which layouts/workspaces to load sequentially on session start.
- `spaces/`: Regular layout definition files.
- `templates/`: Layout template files containing placeholders (`$1`, `$2`, etc.).

## Default spaces

Out of the box there are two workspaces, each split 50/50:

- `spaces/main.space` — workspace 1: **zenith** (system monitor) in the terminal, browser on the right
- `spaces/web.space` — workspace 2: plain terminal, browser on the right

Neither names a specific application. At load time `niri-spaces` resolves:

| Variable | If unset, first installed of |
| --- | --- |
| `TERMINAL` | `ghostty`, `foot`, `alacritty`, `kitty` |
| `BROWSER` | `brave-origin`, `brave`, `firefox`, `google-chrome`, `chromium` |

Anything you export wins, so `BROWSER=firefox niri-spaces load main` does what you'd expect. The matching `app_id` the window reports (`TERMINAL_APPID` / `BROWSER_APPID`) is derived automatically — window matching is a prefix match, so `brave-origin` and `brave-browser-nightly` both resolve to `brave`.

The terminal candidates are limited to emulators that accept `--title=NAME -e COMMAND`, because `main.space` uses exactly that form to run zenith. `wezterm` (`start --`) and `xterm` (`-title`) are therefore not autodetected — `app_id_for` still maps wezterm if you export `TERMINAL=wezterm` deliberately, but the zenith line is then your problem.

`spaces/default.space` is a plain single-workspace terminal + browser fallback with no zenith.

### Layout file format

```
@workspace <name-or-index>
<app_id> | <launch command> [| <env vars> [| <capture var>]]
@action <shell command>          # may use captured window-id vars
```

Both the `app_id` and command fields expand shell variables. Fields are split on `|`, so **a launch command must not contain a pipe character** — set `$TERMINAL`/`$BROWSER` instead of writing an inline `||` fallback.

## Command Line Interface

```bash
# Load a workspace layout or template
niri-spaces load <name> [args...]

# Run the autostart layout list
niri-spaces start

# Display workspace splash (usually run on terminal start)
space-splash [path]
```
