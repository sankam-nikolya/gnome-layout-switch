## 1.3.0 — Own GNOME Shell Extension (Ubuntu 26 / Wayland)

- Primary layout backend is now a **bundled GNOME Shell extension** that exports
  D-Bus methods `Next()`, `Previous()`, and `GetCurrent()`.
- Go daemon calls `Next()` via session D-Bus; no longer depends on
  `org.gnome.Shell.Eval`, EvalGjs, or GSettings `current` as the main path.
- Added `-check` flag and automatic diagnostics for extension availability.
- `install.sh` installs and enables the extension under
  `~/.local/share/gnome-shell/extensions/gnome-layout-switch@gnome-layout-switch`.
- Guarantees operation on Ubuntu 26 with GNOME Wayland (GNOME Shell 45–51).
- Removed g3kb-switch fallback; sole backend is the bundled Shell extension.

## 1.2.0 — Ubuntu 26.04 / GNOME Wayland compatibility

- Fixed 64-bit Linux `input_event` decoding: `timeval.tv_usec` is now 64-bit,
  making each event record 24 bytes as required by the x86_64/aarch64 ABI.
- Added a public GNOME GSettings input-source switching backend. It is attempted
  after g3kb-switch and before legacy Shell JavaScript extensions.
- Made GSettings current-source parsing accept the `uint32 N` representation.
- Removed an unnecessary sleep/retry loop on EOF from a closed input device.
- Removed `PassEnvironment` from the generated systemd user unit.
- Docker build now runs Go unit tests before producing the static binary.
- Updated Ubuntu 26.04 GNOME Wayland setup documentation and input-group warning.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Renamed project from `gnome-xinput-layout-switch` to `gnome-layout-switch` (binary, service, config path, module)
- Build toolchain: Go **1.27** (`go.mod`, Docker image `golang:1.27-alpine`)
- `./install.sh --system` now also installs the **user** service for the current session (not only the greeter)

### Added
- Bundled GNOME Shell extension with D-Bus Next/Previous/GetCurrent

### Removed
- Primary use of switchLayoutGSettings, EvalGjs, and classic Shell.Eval

### Fixed
- Wayland: use Linux EV_KEY codes (29/97 Ctrl, 42/54 Shift) instead of X11 keycodes so Ctrl+Shift actually triggers
- install.sh: move `StartLimitIntervalSec` to `[Unit]` (fixes systemd warning on Ubuntu)

## [1.1.0] - 2026-09-22

### Added
- Wayland support via `/dev/input/eventX` device reading (requires user in `input` group)
- Auto-detection of keyboard event device on Wayland (`-auto-input` flag)
- Device name filter for auto-detection (`-device` flag)
- Multiple backend support for layout switching:
  - g3kb-switch (recommended for GNOME 41+)
  - EvalGjs extension
  - Classic GNOME Shell Eval (GNOME ≤40 / unsafe-mode)
- Configuration file support at `~/.config/gnome-layout-switch/config.json`
- Systemd user service installation (`-install-service` flag)
- Docker build support via `build.sh`
- Debug logging mode (`-debug` flag)
- Customizable key combinations (`-key1`, `-key2` flags)
- Version flag (`-version`)
- Help flag (`-h`, `-help`)
- Save configuration to file (`-save-config` flag)

### Changed
- Improved xinput event parsing for X11 mode
- Enhanced signal handling for clean shutdown
- Updated documentation with Wayland setup instructions
- Added recommended GNOME extension (g3kb-switch) to docs

### Fixed
- Proper handling of both X11 and Wayland sessions
- Key state tracking for reliable combination detection
- Config file loading with proper defaults

## [1.0.0] - 2026-01-15

### Added
- Initial release
- X11 support via `xinput test-xi2`
- Default Ctrl+Shift (Left/Right Ctrl + Left/Right Shift) key combination
- Basic GNOME layout switching via EvalGjs extension
- Simple CLI with key customization
- MIT License
