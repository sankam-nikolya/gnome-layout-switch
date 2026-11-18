# gnome-layout-switch

[![Go Version](https://img.shields.io/badge/Go-1.27+-00ADD8?logo=go&logoColor=white)](https://go.dev/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Build Status](https://img.shields.io/github/actions/workflow/status/sankam-nikolya/gnome-layout-switch/ci.yml?branch=main&logo=github)](https://github.com/sankam-nikolya/gnome-layout-switch/actions)
[![Go Report Card](https://goreportcard.com/badge/github.com/sankam-nikolya/gnome-layout-switch)](https://goreportcard.com/report/github.com/sankam-nikolya/gnome-layout-switch)
[![Go Reference](https://pkg.go.dev/badge/github.com/sankam-nikolya/gnome-layout-switch.svg)](https://pkg.go.dev/github.com/sankam-nikolya/gnome-layout-switch)

**gnome-layout-switch** — A lightweight daemon for switching keyboard layout in GNOME using the **Ctrl + Shift** combination.

Supports **X11** and **GNOME Wayland**, including the target Ubuntu 22.04 / 24.04 / 26.04 (64-bit) configuration. On Wayland, it reads Linux input events from `/dev/input/eventX` (requires `input` group membership). On X11 (including Ubuntu 22.04 / GNOME 42), it uses `xinput test-xi2 --root` and parses the standard multi-line XI2 event format.

**Primary backend (version 1.3+):** Own GNOME Shell Extension (`gnome-layout-switch@gnome-layout-switch`) exporting D-Bus methods `Next()`, `Previous()`, `GetCurrent()`. The Go daemon calls `Next()` via the session bus. The extension is installed and enabled by `install.sh`.

**Important:** `input` group membership gives the process access to low-level keyboard events and other input devices. Use only for trusted local software.

Single static Go binary, installation via one script (`install.sh`), systemd user or system service (the latter also runs on the GDM login screen).

```
gnome-layout-switch 1.4.1 — GNOME keyboard layout switcher (Ctrl+Shift)
```

## Overview

### Purpose

This daemon listens for a key combination (default: Ctrl + Shift) and switches the GNOME input source via a bundled GNOME Shell extension. It works on both X11 and Wayland (Ubuntu 22.04 / GNOME 42 (X11) and newer GNOME releases).

### Architecture

- **Daemon**: Single Go binary, no external dependencies at runtime (standard library only)
- **Two runtime modes**: X11 (uses `xinput test-xi2`) and Wayland (reads `/dev/input/eventX`)
- **Layout backend**: Bundled GNOME Shell extension exposing D-Bus API (`Next`, `Previous`, `GetCurrent`)
- **Configuration**: JSON file at `~/.config/gnome-layout-switch/config.json`
- **Auto-start**: systemd user service for graphical login

### Session Types

| Session | Input Method | Requirements |
|---------|--------------|--------------|
| X11 | `xinput test-xi2 --root` | `xinput` command, `DISPLAY` set |
| Wayland | Direct `/dev/input/eventX` read | User in `input` group, kernel 5.10+ |

### Key Combination

Default: **Left/Right Ctrl + Left/Right Shift** (chord detection — both keys must be held, release triggers switch).

- X11 keycodes: `37,105` (Ctrl) / `50,62` (Shift)
- Linux EV_KEY codes (Wayland): `29,97` (Ctrl) / `42,54` (Shift)

The daemon converts X11 defaults to Linux codes automatically when running in direct-input mode.

## Quick Start

### Prerequisites

- Linux with GNOME (X11 or Wayland session)
- Docker (for building without Go toolchain)
- Or Go 1.27+ (for local build)

### Minimal Steps

1. Build the binary:
   ```bash
   bash build.sh
   ```
2. Run the installer:
   ```bash
   ./install.sh
   ```
3. On Wayland: Log out and back in (required for `input` group and extension load).

## Installation

For Ubuntu 22.04 / GNOME 42 / X11, install the XInput utility first: `sudo apt install xinput`. The installer selects the legacy GNOME Shell extension for GNOME 42 and uses X11 keycodes; no `/dev/input` access or `input` group membership is required.

### One-Command Installer (Recommended)

```bash
./install.sh
```

The installer detects the session type (X11 or Wayland) and:

1. Installs the binary to `~/.local/bin` (builds via `build.sh` if missing).
2. Installs and enables the matching GNOME Shell extension before starting the systemd user service.
3. On Wayland: Adds the user to the `input` group (`sudo usermod -aG input $USER`).
4. On GNOME: Disables the system shortcut for language switching (`switch-input-source` / `switch-input-source-backward`) to avoid conflict with the daemon's Ctrl+Shift trigger. Previous values are backed up to `~/.config/gnome-layout-switch/shortcuts.backup`. Restore with `bash ~/.config/gnome-layout-switch/shortcuts.backup`.
5. Verifies the daemon runs and reports `PASS`/`WARN`/`FAIL` per check.

#### Dry Run

Shows planned actions without making changes:

```bash
./install.sh --dry-run
```

### Global Install (Login Screen and User Session)

```bash
sudo -k true 2>/dev/null || true
./install.sh --system
```

Installs the binary to `/usr/local/bin` and:

1. A systemd **system** service running as the greeter user (`gdm` on Ubuntu), so layout switching works on the **login screen**.
2. A systemd **user** service for the current session, so switching also works **after login** (same as plain `./install.sh`).

#### X11 Greeter

```bash
./install.sh --system --greeter=x11
```

Add `--display=:0 --xauthority=/var/lib/gdm3/.Xauthority` if needed.

### Migration from `gnome-xinput-layout-switch`

If you had the previous name installed:

```bash
# Stop/remove old user service (if present)
systemctl --user disable --now gnome-xinput-layout-switch.service 2>/dev/null || true
rm -f ~/.config/systemd/user/gnome-xinput-layout-switch.service

# Old system unit (if any)
sudo systemctl disable --now gnome-xinput-layout-switch.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/gnome-xinput-layout-switch.service /usr/local/bin/gnome-xinput-layout-switch

# Optional: move config
mkdir -p ~/.config/gnome-layout-switch
[ -f ~/.config/gnome-xinput-layout-switch/config.json ] && \
  mv ~/.config/gnome-xinput-layout-switch/config.json ~/.config/gnome-layout-switch/
rm -rf ~/.config/gnome-xinput-layout-switch

systemctl --user daemon-reload
sudo systemctl daemon-reload
```

Then install the new binary with `./install.sh` as usual.

### Uninstall — Full Rollback, No Traces

```bash
./install.sh --uninstall
```

Stops/removes the service (user and/or system), removes the binary and config directory, restores the previous GNOME language-switch shortcut from the backup, and removes any group membership the installer added. Preview with:

```bash
./install.sh --dry-run --uninstall
```

### Build with Docker (Recommended)

```bash
bash build.sh            # Produce ./gnome-layout-switch
bash build.sh --install  # Build + install to ~/.local/bin
bash build.sh --clean    # Remove binary and Docker image
```

### Manual Build (Requires Go)

```bash
CGO_ENABLED=0 go build -ldflags="-s -w" -o gnome-layout-switch \
  gnome-layout-switch.go
```

### Install as systemd User Service (Manual)

```bash
./gnome-layout-switch -install-service

systemctl --user daemon-reload
systemctl --user enable --now gnome-layout-switch.service

# Status / logs
systemctl --user status gnome-layout-switch.service
journalctl --user -u gnome-layout-switch.service -f
```

## Configuration

### File Location

Default path: `~/.config/gnome-layout-switch/config.json` (uses `XDG_CONFIG_HOME` if set).

### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `key1` | string | `"37,105"` | First key codes, comma-separated (X11: Ctrl; Wayland auto: `29,97`) |
| `key2` | string | `"50,62"` | Second key codes, comma-separated (X11: Shift; Wayland auto: `42,54`) |
| `input` | string | `""` | Path to `/dev/input/eventX` (required on Wayland, or use `-auto-input`) |
| `debug` | boolean | `false` | Enable verbose logging |
| `device` | string | `""` | Name filter for auto-detection (e.g., `"AT Translated"`, `"Logitech"`) |

Flags always override the config file.

### Example

```json
{
  "key1": "37,105",
  "key2": "50,62",
  "input": "",
  "debug": false,
  "device": ""
}
```

### Key Codes Reference

**X11** (from `xinput` / `xev`):

| Key | Code |
|-----|------|
| Left Ctrl | 37 |
| Right Ctrl | 105 |
| Left Shift | 50 |
| Right Shift | 62 |

**Wayland** (`/dev/input/eventX`, Linux EV_KEY — used automatically with `-input` / `-auto-input`):

| Key | Code |
|-----|------|
| Left Ctrl | 29 |
| Right Ctrl | 97 |
| Left Shift | 42 |
| Right Shift | 54 |

On 64-bit Ubuntu, each kernel `input_event` record is 24 bytes (`timeval` uses two 64-bit fields). The daemon decodes this ABI explicitly; older builds that treated `usec` as 32-bit could lose event alignment and fail to detect key combinations.

## Usage

### X11 Session

```bash
./gnome-layout-switch
```

### Wayland — Auto-Detect Keyboard

```bash
./gnome-layout-switch -auto-input
```

### Wayland — Explicit Device

```bash
./gnome-layout-switch -input /dev/input/event3
```

### Custom Keys + Save Config

```bash
./gnome-layout-switch -key1 37,105 -key2 64 -auto-input -save-config
```

### Command-Line Options

| Flag | Description |
|------|-------------|
| `-h`, `-help` | Show help and exit |
| `-version` | Show version and exit |
| `-check` | Check extension availability and exit |
| `-key1 string` | First key codes, comma-separated |
| `-key2 string` | Second key codes, comma-separated |
| `-input string` | Path to `/dev/input/eventX` (required on Wayland) |
| `-auto-input` | Auto-detect keyboard event device |
| `-device string` | Name filter for `-auto-input` (e.g., `"AT Translated"`) |
| `-debug` | Enable verbose logging |
| `-config string` | Path to config.json |
| `-save-config` | Save current flags to config file and exit |
| `-install-service` | Install systemd user service and exit |

## Verification

### Check Service Status

```bash
systemctl --user status gnome-layout-switch.service
journalctl --user -u gnome-layout-switch.service -f
```

### Check Extension Status

```bash
./gnome-layout-switch -check
```

Expected output on success:
```
PASS: extension OK (GetCurrent → 0)
```

### Inspect Keyboard Devices

```bash
cat /proc/bus/input/devices | grep -A 10 -i keyboard
libinput list-devices
```

### Manual Test Run (Wayland)

```bash
./gnome-layout-switch --auto-input --debug
```

Look for:
- `Auto-detected keyboard(s): /dev/input/eventX`
- `Backend: extension OK (GetCurrent → N)`
- Daemon stays running (press Ctrl+Shift to test)

## Troubleshooting

### Symptom: Daemon Fails to Start on Wayland

**Conditions**: Running on Wayland, user not in `input` group.

**Cause**: The daemon cannot open `/dev/input/eventX` without `input` group membership.

**Resolution**:
1. Add user to group: `sudo usermod -aG input $USER`
2. Log out completely and log in again.
3. Verify: `id -nG | grep input`

### Symptom: Extension D-Bus Not Reachable

**Conditions**: Extension installed but `./gnome-layout-switch -check` fails.

**Cause**: Extension not enabled, or Wayland session not restarted after enable.

**Resolution**:
1. Enable extension: `gnome-extensions enable gnome-layout-switch@gnome-layout-switch`
2. On Wayland: Log out and back in.
3. Verify: `./gnome-layout-switch -check`

### Symptom: Ctrl+Shift Does Not Switch Layout

**Conditions**: Daemon running, extension enabled, but key combination has no effect.

**Possible Causes**:
- Wrong keycodes for your keyboard/layout
- Another process captures the key combination
- GNOME system shortcut still active

**Diagnosis**:
1. Run with `-debug` and press Ctrl+Shift. Check logs for key events.
2. Verify keycodes: `xev` (X11) or `libinput debug-events` (Wayland).
3. Check GNOME shortcuts: `gsettings get org.gnome.desktop.wm.keybindings switch-input-source`

**Resolution**:
- Set correct keycodes via `-key1` / `-key2` or config file.
- Run `./install.sh` to disable conflicting GNOME shortcuts.
- Ensure no other hotkey daemon runs (e.g., `sxhkd`, `xbindkeys`).

### Symptom: `xinput` Not Found on X11

**Conditions**: Running on X11, `xinput` command missing.

**Resolution**: Install `xinput` package (e.g., `sudo apt install xinput` on Ubuntu/Debian).

### Symptom: Service Not Enabled After Install

**Conditions**: `systemctl --user is-enabled gnome-layout-switch.service` returns `disabled`.

**Resolution**:
```bash
systemctl --user daemon-reload
systemctl --user enable --now gnome-layout-switch.service
```

### Symptom: Binary Not in PATH

**Conditions**: `~/.local/bin` not in `PATH`.

**Resolution**: Add to shell profile:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Development

### Prerequisites

- Docker (recommended) — for building without installing Go
- Go 1.27+ (optional) — for local development and testing
- golangci-lint — for code quality checks (install via `make install-lint`)

### Quick Start

```bash
# Clone the repository
git clone https://github.com/sankam-nikolya/gnome-layout-switch.git
cd gnome-layout-switch

# Build with Docker (no Go installation needed)
make build

# Or build locally if you have Go
go build -o gnome-layout-switch gnome-layout-switch.go

# Run tests and linting
make ci
```

### Development Workflow

1. Format code: `make fmt`
2. Run linters: `make lint`
3. Auto-fix issues: `make lint-fix`
4. Run full CI pipeline: `make ci` (lint + build)

### Code Style

- Follow standard Go formatting (`gofumpt` via `make fmt`)
- All linters in `.golangci.yml` must pass
- Add doc comments for new exported functions and types
- Keep functions focused and under 120 lines (`funlen` linter)

### Testing

Currently no automated tests. When adding tests:
- Place test files alongside the code they test (`*_test.go`)
- Use table-driven tests for multiple cases
- Run `go test ./...` to execute

### Reporting Issues

- Use GitHub Issues for bugs and feature requests
- Include your GNOME version, session type (X11/Wayland), and steps to reproduce
- Attach relevant logs (`journalctl --user -u gnome-layout-switch.service -f`)

## Alternatives

- [EvalGjs](https://github.com/ramottamado/eval-gjs)
- [Shyriiwook](https://extensions.gnome.org/extension/6691/shyriiwook)

## License

MIT