# NIRI SPACES

Niri Spaces is a layout configuration manager for the Niri Wayland compositor. It allows defining workspace layouts programmatically, templating repetitive workspace environments (e.g. monorepos), and displaying rich ASCII art splashes when terminals open.

## Features

- **Declarative layouts**: Load Niri workspace environments from clean config files.
- **Templating support**: Load monorepos dynamically by passing parameters (e.g., loading `myrepo-mono` with arguments `1` through `4`).
- **Rich ASCII Splashes**: Includes `space-splash`, which displays a gorgeous ASCII art box with directory names, Git branch, last commit info, and status.
- **Easy shortcuts**: Automatically binds `Mod+Ctrl+Shift+S` to reload/refresh all workspaces.

## Directory Structure

Configurations are placed in `~/.config/niri-spaces/`:

- `autostart`: File specifying which layouts/workspaces to load sequentially on session start.
- `spaces/`: Regular layout definition files.
- `templates/`: Layout template files containing placeholders (`$1`, `$2`, etc.).

## Command Line Interface

```bash
# Load a workspace layout or template
niri-spaces load <name> [args...]

# Run the autostart layout list
niri-spaces start

# Display workspace splash (usually run on terminal start)
space-splash [path]
```
