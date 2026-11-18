#!/usr/bin/env bash
set -euo pipefail

# install.sh — one-command installer/uninstaller for gnome-layout-switch.
#
# Two install modes:
#   * user (default)  — binary in ~/.local/bin + systemd --user service.
#   * system (global) — binary in /usr/local/bin + systemd SYSTEM service for
#                       the greeter (login screen) AND user service for the
#                       current logged-in session.
#
# Uninstall (--uninstall) removes everything the installer created and rolls
# back to the previous state (restores GNOME shortcuts, removes added groups,
# deletes units/binaries/config), leaving no traces.
#
# Target systems: Ubuntu 22.04 - 26.04 (GDM).
#
# Usage:
#   ./install.sh                     # user install
#   ./install.sh --system            # global install (login screen too)
#   ./install.sh --uninstall         # remove + rollback
#   ./install.sh --dry-run           # show what would be done, change nothing
#   ./install.sh --help

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP="gnome-layout-switch"
SERVICE="${APP}.service"
INSTALL_DIR="${HOME}/.local/bin"
SYS_INSTALL_DIR="/usr/local/bin"
CONF_DIR="${HOME}/.config/${APP}"
UNIT_DIR="${HOME}/.config/systemd/user"
SYS_UNIT_DIR="/etc/systemd/system"
SYS_STATE_DIR="/var/lib/${APP}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

DRY=0
FAIL=0
WARN=0
MODE="user"                # user | system | uninstall
GREETER_TYPE="wayland"     # wayland | x11  (login screen)
GREETER_USER=""            # auto-detected: gdm / lightdm / sddm
GREETER_DISPLAY=":0"       # X11 greeter DISPLAY
GREETER_XAUTH="/var/lib/gdm3/.Xauthority"

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; }
step()  { echo -e "${BOLD}==>${NC} $*"; }

v_pass() { echo -e "  ${GREEN}PASS${NC} $*"; }
v_warn() { echo -e "  ${YELLOW}WARN${NC} $*"; WARN=$((WARN + 1)); }
v_fail() { echo -e "  ${RED}FAIL${NC} $*"; FAIL=$((FAIL + 1)); }

# run command via sudo; in dry-run just print it
sudo_run() {
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: sudo $*"
    return 0
  fi
  local SUDO=(sudo)
  if [[ ! -t 0 ]]; then SUDO=(sudo -n); fi
  if ! "${SUDO[@]}" "$@"; then
    error "sudo command failed"
    return 1
  fi
}

print_help() {
  cat <<EOF
${APP} installer/uninstaller — install, configure, and start the layout-switch daemon.

USAGE:
  $0 [--system] [--uninstall] [--dry-run] [--help] [OPTIONS]

MODES:
  (none)      User install: binary to ~/.local/bin, systemd user service.
  --system    Global install: binary to /usr/local/bin + systemd system service
              for the greeter (login screen), AND user service for the current
              session. Requires sudo.
  --uninstall Remove everything and roll back to the previous state
              (restore shortcuts, remove added groups, no traces left).

OPTIONS:
  --dry-run        Print planned actions and run read-only checks.
  --help           Show this help and exit.
  --greeter=wayland|x11   Login-screen session type (default: wayland).
  --greeter-user=NAME     Greeter user (default: auto-detect gdm/lightdm/sddm).
  --display=:N            X11 greeter DISPLAY (default: :0).
  --xauthority=PATH       X11 greeter XAUTHORITY (default: /var/lib/gdm3/.Xauthority).

WHAT IT DOES (install):
  - Detects session type (X11 / Wayland).
  - Copies binary (builds via build.sh if missing).
  - Installs and starts the daemon service.
  - On Wayland: adds user to the 'input' group.
  - On X11: uses xinput test-xi2 (requires xinput and the graphical DISPLAY/XAUTHORITY environment).
  - On GNOME: installs the matching Shell extension (legacy for 42–44,
    modern ESM for 45+) and disables system language-switch shortcut
    (switch-input-source / switch-input-source-backward), backing up
    previous values to ~/.config/${APP}/shortcuts.backup.
  - Verifies and reports PASS/WARN/FAIL per check.
EOF
}

# --- argument parsing --------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) print_help; exit 0 ;;
    --dry-run) DRY=1 ;;
    --system|--global) MODE="system" ;;
    --uninstall) MODE="uninstall" ;;
    --greeter=wayland|--greeter=x11) GREETER_TYPE="${1#*=}" ;;
    --greeter=*) error "Invalid --greeter: ${1#*=} (use wayland or x11)"; exit 1 ;;
    --greeter-user=*)
      GREETER_USER="${1#*=}"
      if [[ ! "$GREETER_USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        error "Invalid greeter user name"
        exit 1
      fi
      ;;
    --display=*)
      GREETER_DISPLAY="${1#*=}"
      if [[ ! "$GREETER_DISPLAY" =~ ^:[0-9]+$ ]]; then
        error "Invalid display format (use :N)"
        exit 1
      fi
      ;;
    --xauthority=*)
      GREETER_XAUTH="${1#*=}"
      if [[ ! "$GREETER_XAUTH" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
        error "Invalid Xauthority path"
        exit 1
      fi
      ;;
    *) error "Unknown option: $1"; print_help; exit 1 ;;
  esac
  shift
done

if [[ "$(id -u)" -eq 0 ]]; then
    error "Do not run as root. Run as a normal user (sudo is used internally)."
    exit 1
  fi

# --- session / desktop detection ---------------------------------------------

SESSION="unknown"
INPUT_ACTIVE=1

detect_session() {
  local t
  t="${XDG_SESSION_TYPE:-}"
  case "$(echo "$t" | tr '[:upper:]' '[:lower:]')" in
    wayland) SESSION="wayland"; return 0 ;;
    x11)     SESSION="x11"; return 0 ;;
  esac
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then SESSION="wayland"; return 0; fi
  if [[ -n "${DISPLAY:-}" ]]; then SESSION="x11"; return 0; fi
  SESSION="unknown"
  return 1
}

is_gnome() {
  local d
  d="${XDG_CURRENT_DESKTOP:-} ${DESKTOP_SESSION:-}"
  if grep -qi "gnome" <<<"$d"; then
    return 0
  fi
  if gsettings list-schemas 2>/dev/null | grep -qx "org.gnome.desktop.wm.keybindings"; then
    return 0
  fi
  return 1
}

detect_greeter_user() {
  local u
  for u in gdm lightdm sddm; do
    if getent passwd "$u" >/dev/null 2>&1; then
      echo "$u"
      return 0
    fi
  done
  return 1
}

greeter_uid() {
  getent passwd "$GREETER_USER" 2>/dev/null | cut -d: -f3
}

# --- binary ----------------------------------------------------------------

BIN=""

resolve_binary() {
  local repo_bin="${ROOT}/${APP}"
  if [[ -x "$repo_bin" ]]; then
    info "Using existing binary: $repo_bin"
    BIN="$repo_bin"
    return 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: build via 'bash build.sh' (Docker), no prebuilt binary found."
    BIN="$repo_bin"
    return 0
  fi
  info "No prebuilt binary found. Building with build.sh (Docker)..."
  if ! command -v docker >/dev/null 2>&1; then
    error "Binary not found and build unavailable"
    exit 1
  fi
  ( cd "$ROOT" && bash build.sh )
  if [[ ! -x "$repo_bin" ]]; then
    error "Build did not produce binary"
    exit 1
  fi
  BIN="$repo_bin"
}

install_binary() {
  step "Installing binary"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: cp -f '$BIN' '$INSTALL_DIR/$APP'"
  else
    mkdir -p "$INSTALL_DIR"
    cp -f "$BIN" "$INSTALL_DIR/$APP"
    chmod 0755 "$INSTALL_DIR/$APP"
    info "Installed to $INSTALL_DIR/$APP"
  fi
  BIN="$INSTALL_DIR/$APP"
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "\$HOME/.local/bin is not in PATH — add it to ~/.profile:"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

# --- systemd user service ----------------------------------------------------

# Build ExecStart for the user service according to the current session.
# X11: plain binary (xinput test-xi2, no input group).
# Wayland: --auto-input (/dev/input/event*, needs input group).
user_service_exec() {
  local exe="${1:-$BIN}"
  if [[ "$SESSION" == "wayland" ]]; then
    echo "$exe --auto-input"
  else
    # X11 or unknown: do not force --auto-input (avoids permission denied)
    echo "$exe"
  fi
}

write_user_unit() {
  local exe_line unit_path
  exe_line="$(user_service_exec "$BIN")"
  unit_path="$UNIT_DIR/$SERVICE"
  mkdir -p "$UNIT_DIR"
  cat > "$unit_path" <<EOF
[Unit]
Description=GNOME Keyboard Layout Switcher (Ctrl+Shift)
Documentation=https://github.com/sankam-nikolya/gnome-layout-switch
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$exe_line
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
  info "Service unit written to $unit_path"
  if [[ "$SESSION" == "wayland" ]]; then
    info "ExecStart uses --auto-input (Wayland /dev/input path)"
  else
    info "ExecStart without --auto-input (X11 uses xinput; session=$SESSION)"
  fi
}

install_service() {
  step "Installing systemd user service"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found. Cannot install service. Run daemon manually:"
    warn "  $(user_service_exec "$BIN")"
    return 1
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    warn "systemd user session (DBus) not available. Install and start manually after writing the unit."
    warn "  systemctl --user daemon-reload"
    warn "  systemctl --user enable --now $SERVICE"
    return 1
  fi
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: write $UNIT_DIR/$SERVICE with ExecStart=$(user_service_exec "$BIN")"
    info "Plan: import DISPLAY/XAUTHORITY/XDG_SESSION_TYPE into systemd --user"
    info "Plan: systemctl --user enable --now $SERVICE"
    return 0
  fi
  # The user manager can start before GNOME exports its graphical-session
  # variables. Import them now so xinput can connect to the active X server.
  local -a graphical_env=()
  local var
  for var in DISPLAY XAUTHORITY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP; do
    if [[ -n "${!var:-}" ]]; then graphical_env+=("$var"); fi
  done
  if [[ ${#graphical_env[@]} -gt 0 ]]; then
    systemctl --user import-environment "${graphical_env[@]}" >/dev/null 2>&1 || true
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
      dbus-update-activation-environment --systemd "${graphical_env[@]}" >/dev/null 2>&1 || true
    fi
  fi
  write_user_unit
  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE" >/dev/null 2>&1 \
    || warn "systemctl --user enable failed."
  # Restart, rather than start, so an already-running 1.3.x daemon is replaced
  # with the newly installed binary and updated X11 event parser.
  systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
  sleep 1
  case "$(systemctl --user is-active "$SERVICE" 2>/dev/null)" in
    active)
      info "Service is running."
      ;;
    *)
      warn "Service did not stay running in this session."
      systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
      systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true
      warn "Enabled. Will start automatically on next login."
      ;;
  esac
}

# --- input group (Wayland only) ---------------------------------------------

ensure_input_group() {
  step "Checking 'input' group membership"
  if id -nG | tr ' ' '\n' | grep -qx "input"; then
    INPUT_ACTIVE=1
    info "User already in 'input' group."
    return 0
  fi
  INPUT_ACTIVE=0
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: sudo usermod -aG input $USER (required on Wayland)"
    warn "Group applies only after log out and back in."
    return 1
  fi
  warn "User not in 'input' group (required to read /dev/input/eventX)."
  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo not found. Add yourself manually:"
    warn "  su -c 'usermod -aG input $USER'"
    return 1
  fi
  if sudo_run usermod -aG input "$USER"; then
    info "Added to 'input' group."
    warn "Takes effect only after log out and back in."
    warn "Daemon may fail to read keyboard device until then."
  else
    error "Failed to add user to group"
  fi
}

add_user_to_group() {
  local u="$1"
  if id -nG "$u" | tr ' ' '\n' | grep -qx "input"; then
    info "User '$u' already in 'input' group."
    return 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: sudo usermod -aG input $u"
    return 0
  fi
  if sudo_run usermod -aG input "$u"; then
    info "Added '$u' to 'input' group."
  else
    error "Failed to add user to group"
    return 1
  fi
}

# --- disable GNOME language-switch shortcut --------------------------------

disable_shortcuts() {
  step "Disabling GNOME system shortcut for language switching"
  if ! is_gnome; then
    warn "GNOME not detected. Skipping shortcut changes."
    return 0
  fi
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found. Skipping shortcut changes."
    return 0
  fi
  local val1 val2 ts backup
  val1="$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source 2>/dev/null || echo '@as []')"
  val2="$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source-backward 2>/dev/null || echo '@as []')"
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$CONF_DIR/shortcuts.backup"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: gsettings set switch-input-source '[]' (current: $val1)"
    info "Plan: gsettings set switch-input-source-backward '[]' (current: $val2)"
    return 0
  fi
  mkdir -p "$CONF_DIR"
  if [[ -e "$backup" ]]; then
    cp -f "$backup" "$backup.$ts"
  fi
  local tmp
  tmp="$(mktemp "${CONF_DIR}/shortcuts.backup.XXXXXX")" || { error "Failed to create temp file"; return 1; }
  chmod 600 "$tmp"
  {
    echo "# ${APP} — previous GNOME language-switching shortcuts (backed up $ts)"
    echo "gsettings set org.gnome.desktop.wm.keybindings switch-input-source \"$val1\""
    echo "gsettings set org.gnome.desktop.wm.keybindings switch-input-source-backward \"$val2\""
  } > "$tmp" && mv -f "$tmp" "$backup" || { rm -f "$tmp"; error "Failed to write backup"; return 1; }
  if gsettings set org.gnome.desktop.wm.keybindings switch-input-source "[]"; then
    info "Disabled 'switch-input-source'."
  else
    warn "Could not set switch-input-source."
  fi
  if gsettings set org.gnome.desktop.wm.keybindings switch-input-source-backward "[]"; then
    info "Disabled 'switch-input-source-backward'."
  else
    warn "Could not set switch-input-source-backward."
  fi
  info "Backup saved to: $backup"
  info "Restore with: bash $backup"
}

# --- system (global) install ------------------------------------------------

write_user_state() {
  # records exactly what the user-mode install changed, for clean rollback
  local st="$CONF_DIR/install-state"
  mkdir -p "$CONF_DIR"
  local tmp
  tmp="$(mktemp "${CONF_DIR}/install-state.XXXXXX")" || { error "Failed to create temp file"; return 1; }
  chmod 600 "$tmp"
  {
    echo "MODE=user"
    echo "BINARY_USER=1"
    [[ "$INPUT_ACTIVE" -eq 0 ]] && echo "INPUT_USER_ADDED=1"
    echo "SHORTCUTS_BACKUP=$CONF_DIR/shortcuts.backup"
  } > "$tmp" && mv -f "$tmp" "$st" || { rm -f "$tmp"; error "Failed to write state"; return 1; }
  info "Install state written to $st (used by --uninstall)"
}

write_system_state() {
  # system state is root-owned: only used when --system was run
  local st="$SYS_STATE_DIR/install-state"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: write state to $st"
    return 0
  fi
  sudo_run mkdir -p "$SYS_STATE_DIR"
  local tmp
  tmp="$(sudo_run mktemp "${SYS_STATE_DIR}/install-state.XXXXXX")" || { error "Failed to create temp file"; return 1; }
  sudo_run chmod 600 "$tmp"
  {
    echo "MODE=system"
    echo "BINARY_SYSTEM=1"
    echo "GREETER_USER=$GREETER_USER"
    echo "INPUT_GDM_ADDED=1"
    echo "GDM_SHORTCUTS_BACKUP=$SYS_STATE_DIR/gdm-shortcuts.backup"
  } | sudo_run tee "$tmp" >/dev/null && sudo_run mv -f "$tmp" "$st" || { sudo_run rm -f "$tmp"; error "Failed to write state"; return 1; }
  info "Install state written to $st (used by --uninstall)"
}

disable_greeter_shortcuts() {
  # Best-effort: disables the language-switch shortcut inside the greeter
  # session by talking to the greeter's DBus (only possible while the login
  # screen is running). Backs up previous values for --uninstall.
  local uid="$1"
  local bus="/run/user/$uid/bus"
  local backup="$SYS_STATE_DIR/gdm-shortcuts.backup"
  local envs=(XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=$bus)
  if [[ "$GREETER_TYPE" == "x11" ]]; then
    envs+=(DISPLAY=$GREETER_DISPLAY XAUTHORITY=$GREETER_XAUTH XDG_SESSION_TYPE=x11)
  else
    envs+=(XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-0)
  fi
  if [[ ! -S "$bus" ]]; then
    warn "Greeter session not running. Cannot disable shortcut."
    warn "Run at boot:"
    warn "  sudo -u $GREETER_USER ${envs[*]} gsettings set org.gnome.desktop.wm.keybindings switch-input-source \"[]\""
    return 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: disable greeter switch-input-source via $bus"
    return 0
  fi
  local val
  val="$(sudo -u "$GREETER_USER" env "${envs[@]}" gsettings get org.gnome.desktop.wm.keybindings switch-input-source 2>/dev/null || echo '@as []')"
  sudo_run mkdir -p "$SYS_STATE_DIR"
  local tmp
  tmp="$(sudo_run mktemp "${SYS_STATE_DIR}/gdm-shortcuts.backup.XXXXXX")" || { error "Failed to create temp file"; return 1; }
  sudo_run chmod 600 "$tmp"
  echo "gsettings set org.gnome.desktop.wm.keybindings switch-input-source \"$val\"" \
    | sudo_run tee "$tmp" >/dev/null && sudo_run mv -f "$tmp" "$backup" || { sudo_run rm -f "$tmp"; error "Failed to write backup"; return 1; }
  if sudo -u "$GREETER_USER" env "${envs[@]}" gsettings set org.gnome.desktop.wm.keybindings switch-input-source "[]" \
     && sudo -u "$GREETER_USER" env "${envs[@]}" gsettings set org.gnome.desktop.wm.keybindings switch-input-source-backward "[]"; then
    info "Disabled language-switch shortcut for greeter ($GREETER_USER)."
  else
    warn "Could not disable greeter shortcut (login screen not up)."
  fi
}

install_system() {
  step "Installing globally (system service, works on the login screen)"
  if [[ -z "$GREETER_USER" ]]; then
    GREETER_USER="$(detect_greeter_user || true)"
    if [[ -z "$GREETER_USER" ]]; then
      error "Greeter user not found"
      exit 1
    fi
  fi
  local uid
  uid="$(greeter_uid)"
  if [[ -z "$uid" ]]; then
    error "Invalid greeter user"
    exit 1
  fi
  info "Greeter user: $GREETER_USER (uid $uid), session: $GREETER_TYPE"

  # 1. binary to /usr/local/bin
  step "Installing binary to $SYS_INSTALL_DIR"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: sudo cp -f '$BIN' '$SYS_INSTALL_DIR/$APP'"
  else
    sudo_run cp -f "$BIN" "$SYS_INSTALL_DIR/$APP"
    sudo_run chmod 0755 "$SYS_INSTALL_DIR/$APP"
    info "Installed to $SYS_INSTALL_DIR/$APP"
  fi

  # 2. input group for the greeter (Wayland greeter reads /dev/input/eventX)
  step "Adding greeter user to the 'input' group"
  if [[ "$GREETER_TYPE" == "wayland" ]]; then
    add_user_to_group "$GREETER_USER" || true
  else
    info "X11 greeter does not need the 'input' group."
  fi

  # 3. systemd system unit
  step "Writing systemd system unit"
  local envs
  if [[ "$GREETER_TYPE" == "x11" ]]; then
    envs="Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
Environment=DISPLAY=$GREETER_DISPLAY
Environment=XAUTHORITY=$GREETER_XAUTH
Environment=XDG_SESSION_TYPE=x11"
  else
    envs="Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
Environment=XDG_SESSION_TYPE=wayland
Environment=WAYLAND_DISPLAY=wayland-0"
  fi
  # Greeter X11: no --auto-input (xinput path). Greeter Wayland: --auto-input.
  local greeter_exec
  if [[ "$GREETER_TYPE" == "x11" ]]; then
    greeter_exec="$SYS_INSTALL_DIR/$APP"
  else
    greeter_exec="$SYS_INSTALL_DIR/$APP --auto-input"
  fi
  local unit
  unit="[Unit]
Description=GNOME Keyboard Layout Switcher (login screen / greeter)
Documentation=https://github.com/sankam-nikolya/gnome-layout-switch
After=display-manager.service
Wants=display-manager.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$GREETER_USER
$envs
ExecStart=$greeter_exec
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: write $SYS_UNIT_DIR/$SERVICE (User=$GREETER_USER, $GREETER_TYPE, ExecStart=$greeter_exec)"
  else
    printf '%s' "$unit" | sudo_run tee "$SYS_UNIT_DIR/$SERVICE" >/dev/null
    info "Unit written to $SYS_UNIT_DIR/$SERVICE (ExecStart=$greeter_exec)"
  fi

  # 4. enable and try to start
  step "Enabling and starting the system service"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: sudo systemctl daemon-reload && systemctl enable --now $SERVICE"
  else
    sudo_run systemctl daemon-reload
    sudo_run systemctl enable "$SERVICE" >/dev/null 2>&1 || warn "systemctl enable failed."
    sudo_run systemctl start "$SERVICE" || true
    sleep 1
    case "$(systemctl is-active "$SERVICE" 2>/dev/null)" in
      active)
        info "Service is running."
        ;;
      *)
        warn "Service not active yet (login screen is not up now)."
        warn "It will start automatically at boot / on the login screen."
        ;;
    esac
  fi

  # 5. disable the greeter's own language-switch shortcut (best effort)
  disable_greeter_shortcuts "$uid" || true

  write_system_state
}

# --- verification ----------------------------------------------------------

EXT_UUID="gnome-layout-switch@gnome-layout-switch"
EXT_DST="${HOME}/.local/share/gnome-shell/extensions/${EXT_UUID}"

# Detect GNOME Shell major version (e.g. 42, 46, 48).
# Returns empty string if detection fails.
detect_gnome_shell_major() {
  local ver major
  if command -v gnome-shell >/dev/null 2>&1; then
    ver="$(gnome-shell --version 2>/dev/null || true)"
    # "GNOME Shell 46.0" / "GNOME Shell 42.9" / "GNOME Shell 48.beta"
    major="$(echo "$ver" | sed -nE 's/.*GNOME Shell ([0-9]+).*/\1/p')"
    if [[ -n "$major" ]]; then
      echo "$major"
      return 0
    fi
  fi
  # Fallback: try gsettings / session (less reliable)
  if command -v gsettings >/dev/null 2>&1; then
    # Some environments expose version via other means; leave empty on failure
    :
  fi
  return 1
}

# Choose extension source directory according to GNOME Shell version.
# GNOME 45+ requires ES modules; 42–44 use legacy imports.
# Layout expected under $ROOT/extension/:
#   modern/gnome-layout-switch@gnome-layout-switch/   (45+)
#   legacy/gnome-layout-switch@gnome-layout-switch/   (42–44)
#   gnome-layout-switch@gnome-layout-switch/          (fallback / default modern)
resolve_extension_src() {
  local major src_modern src_legacy src_default
  src_modern="${ROOT}/extension/${EXT_UUID}"
  src_legacy="${ROOT}/extension/legacy/${EXT_UUID}"
  src_default="${ROOT}/extension/${EXT_UUID}"

  major="$(detect_gnome_shell_major || true)"

  if [[ -n "$major" ]]; then
    if [[ "$major" -ge 45 ]]; then
      if [[ -d "$src_modern" ]]; then
        echo "$src_modern"
        info "GNOME Shell $major detected → using modern (ESM) extension"
        return 0
      fi
      if [[ -d "$src_default" ]]; then
        echo "$src_default"
        info "GNOME Shell $major detected → using default extension sources"
        return 0
      fi
    elif [[ "$major" -ge 42 ]]; then
      if [[ -d "$src_legacy" ]]; then
        echo "$src_legacy"
        info "GNOME Shell $major detected → using legacy (pre-45) extension"
        return 0
      fi
      if [[ -d "$src_default" ]]; then
        echo "$src_default"
        warn "GNOME Shell $major detected but no legacy sources — using default (may not load on <45)"
        return 0
      fi
    else
      warn "GNOME Shell $major is older than 42 — extension may not work"
      if [[ -d "$src_legacy" ]]; then
        echo "$src_legacy"
        return 0
      fi
    fi
  else
    # Cannot detect version: prefer modern, then default, then legacy
    if [[ -d "$src_modern" ]]; then
      echo "$src_modern"
      warn "Could not detect GNOME Shell version — using modern (45+) extension"
      return 0
    fi
    if [[ -d "$src_default" ]]; then
      echo "$src_default"
      warn "Could not detect GNOME Shell version — using default extension sources"
      return 0
    fi
    if [[ -d "$src_legacy" ]]; then
      echo "$src_legacy"
      warn "Could not detect GNOME Shell version — using legacy extension"
      return 0
    fi
  fi
  return 1
}

install_extension() {
  step "Installing GNOME Shell extension (${EXT_UUID})"
  local EXT_SRC
  if ! EXT_SRC="$(resolve_extension_src)"; then
    warn "Extension sources not found under ${ROOT}/extension/ — skip"
    return 0
  fi
  if [[ ! -d "$EXT_SRC" ]]; then
    warn "Extension sources not found at $EXT_SRC — skip"
    return 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: install extension from $EXT_SRC to $EXT_DST and enable it"
    return 0
  fi
  mkdir -p "$(dirname "$EXT_DST")"
  if command -v gnome-extensions >/dev/null 2>&1; then
    # Disable before replacing files; GNOME 42 may otherwise keep the old
    # extension object loaded while its directory is being replaced.
    gnome-extensions disable "$EXT_UUID" >/dev/null 2>&1 || true
  fi
  local stage="${EXT_DST}.new.$$"
  rm -rf "$stage"
  cp -a "$EXT_SRC" "$stage"
  rm -rf "$EXT_DST"
  mv "$stage" "$EXT_DST"
  info "Extension installed to $EXT_DST (from $(basename "$(dirname "$EXT_SRC")")/$(basename "$EXT_SRC"))"
  if command -v gnome-extensions >/dev/null 2>&1; then
    if gnome-extensions enable "$EXT_UUID" 2>/dev/null; then
      info "GNOME extension enabled: $EXT_UUID"
    else
      warn "gnome-extensions enable failed — inspect: gnome-extensions info $EXT_UUID"
    fi
  else
    warn "gnome-extensions CLI not found; enable the extension in Extensions app"
  fi
}

check_backend() {
  if command -v gdbus >/dev/null 2>&1 &&
     gdbus call --session --dest org.gnome.Shell \
       --object-path /org/gnome/Shell/Extensions/GnomeLayoutSwitch \
       --method org.gnome.Shell.Extensions.GnomeLayoutSwitch.GetCurrent >/dev/null 2>&1; then
    v_pass "extension D-Bus (GnomeLayoutSwitch.GetCurrent) reachable"
  else
    v_warn "extension D-Bus is not reachable yet"
    v_warn "  Check: gnome-extensions info ${EXT_UUID}"
    if [[ "$SESSION" == "wayland" ]]; then
      v_warn "  If it was just enabled, log out and back in on Wayland"
    fi
  fi
}

verify() {
  step "Verifying installation ($SESSION session)"

  if [[ -x "$BIN" ]]; then
    v_pass "binary present: $BIN"
  else
    v_fail "binary missing: $BIN"
  fi

  local ver
  if ver="$("$BIN" --version 2>&1)"; then
    v_pass "$ver"
  else
    v_fail "cannot run '$BIN --version'"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    if [[ "$(systemctl --user is-enabled "$SERVICE" 2>/dev/null)" == "enabled" ]]; then
      v_pass "service enabled"
    else
      v_fail "service is not enabled"
    fi
    case "$(systemctl --user is-active "$SERVICE" 2>/dev/null)" in
      active) v_pass "service is active (running)" ;;
      *)      v_warn "service is not running yet — it starts on next login" ;;
    esac
    if command -v journalctl >/dev/null 2>&1; then
      if journalctl --user -u "$SERVICE" --since "10 minutes ago" -p err --no-pager 2>/dev/null | grep -q .; then
        v_warn "recent errors in the service log"
      else
        v_pass "no recent errors in the service log"
      fi
    fi
  else
    v_warn "systemd user session not available — service checks skipped"
  fi

  if [[ "$SESSION" == "wayland" ]]; then
    if id -nG | tr ' ' '\n' | grep -qx "input"; then
      v_pass "user is in the 'input' group"
    else
      v_warn "user is not in the 'input' group in this session — log out and back in"
    fi
    check_backend
    local rc=0 out
    out="$(timeout 3 "$BIN" --auto-input --debug 2>&1)" || rc=$?
    if grep -q "Auto-detected keyboard" <<<"$out"; then
      v_pass "keyboard device auto-detected"
    else
      v_warn "no keyboard device detected — check the 'input' group and device"
    fi
    if [[ $rc -eq 124 ]]; then
      v_pass "daemon stayed alive during the 3s smoke run"
    else
      v_warn "daemon exited early during the smoke run"
    fi
  else
    if command -v xinput >/dev/null 2>&1; then
      v_pass "xinput available"
    else
      v_fail "xinput not found (required on X11)"
    fi
    if [[ -n "${DISPLAY:-}" ]]; then
      v_pass "DISPLAY is set"
    else
      v_warn "DISPLAY is not set"
    fi
    check_backend
    local rc=0 out
    out="$(timeout 3 "$BIN" --debug 2>&1)" || rc=$?
    if [[ $rc -eq 124 ]]; then
      v_pass "daemon stayed alive during the 3s smoke run"
    else
      v_warn "daemon exited early during the smoke run"
    fi
  fi
}

verify_system() {
  step "Verifying system installation (greeter: $GREETER_TYPE)"
  if [[ -x "$SYS_INSTALL_DIR/$APP" ]]; then
    v_pass "binary present: $SYS_INSTALL_DIR/$APP"
  else
    v_fail "binary missing: $SYS_INSTALL_DIR/$APP"
  fi
  local ver
  if ver="$("$SYS_INSTALL_DIR/$APP" --version 2>&1)"; then
    v_pass "$ver"
  else
    v_fail "cannot run --version"
  fi
  if [[ "$(systemctl is-enabled "$SERVICE" 2>/dev/null)" == "enabled" ]]; then
    v_pass "system service enabled"
  else
    v_fail "system service is not enabled"
  fi
  case "$(systemctl is-active "$SERVICE" 2>/dev/null)" in
    active) v_pass "system service is active" ;;
    *)      v_warn "system service not active now — it starts with the login screen" ;;
  esac
  if id -nG "$GREETER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "input"; then
    v_pass "greeter user in the 'input' group"
  else
    v_warn "greeter user not in the 'input' group"
  fi
  if [[ -f "$SYS_UNIT_DIR/$SERVICE" ]]; then
    v_pass "unit present: $SYS_UNIT_DIR/$SERVICE"
  else
    v_fail "unit missing"
  fi
}

# --- uninstall / rollback ---------------------------------------------------

# Always attempt to remove known install artifacts even if install-state is
# missing (e.g. binary was installed via build.sh --install or -install-service).

restore_shortcuts() {
  local backup="$1"
  if [[ ! -f "$backup" ]]; then
    return 0
  fi
  info "Restoring GNOME shortcuts from $backup"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: bash '$backup' && rm -f '$backup'"
    return 0
  fi
  if bash "$backup" 2>/dev/null; then
    info "GNOME shortcuts restored."
    rm -f "$backup"
    rm -f "$backup".*
    return 0
  else
    warn "Could not restore shortcuts automatically — keep the backup: $backup"
    warn "Restore manually: bash $backup"
    return 1
  fi
}

remove_extension() {
  local dst="${HOME}/.local/share/gnome-shell/extensions/${EXT_UUID}"
  step "Removing GNOME Shell extension (${EXT_UUID})"
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: gnome-extensions disable ${EXT_UUID}; rm -rf '$dst'"
    return 0
  fi
  if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions disable "$EXT_UUID" 2>/dev/null || true
  fi
  if [[ -d "$dst" ]]; then
    rm -rf "$dst"
    info "Removed extension directory $dst"
  else
    info "Extension directory not present: $dst"
  fi
}

rollback_user() {
  local st="$CONF_DIR/install-state"
  local removed_any=0

  step "Rolling back user install"

  # 1) stop + disable + remove the user service unit (always try)
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user show-environment >/dev/null 2>&1; then
      if [[ "$DRY" -eq 1 ]]; then
        info "Plan: systemctl --user stop/disable $SERVICE; rm unit; daemon-reload"
      else
        systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
        systemctl --user disable "$SERVICE" >/dev/null 2>&1 || true
        systemctl --user reset-failed "$SERVICE" >/dev/null 2>&1 || true
      fi
    fi
  fi
  if [[ -f "$UNIT_DIR/$SERVICE" ]]; then
    if [[ "$DRY" -eq 1 ]]; then
      info "Plan: rm -f '$UNIT_DIR/$SERVICE'"
    else
      rm -f "$UNIT_DIR/$SERVICE"
      info "Removed user service unit: $UNIT_DIR/$SERVICE"
      removed_any=1
    fi
  else
    info "User service unit not found: $UNIT_DIR/$SERVICE"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    if [[ "$DRY" -eq 0 ]]; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
  fi

  # 2) user binary (~/.local/bin)
  if [[ -f "$INSTALL_DIR/$APP" ]] || [[ -L "$INSTALL_DIR/$APP" ]]; then
    if [[ "$DRY" -eq 1 ]]; then
      info "Plan: rm -f '$INSTALL_DIR/$APP'"
    else
      rm -f "$INSTALL_DIR/$APP"
      info "Removed $INSTALL_DIR/$APP"
      removed_any=1
    fi
  else
    info "User binary not found: $INSTALL_DIR/$APP"
  fi

  # 3) extension (installed by install.sh)
  remove_extension
  removed_any=1

  # 4) remove user from 'input' group only if the installer added them
  if [[ -f "$st" ]] && grep -q '^INPUT_USER_ADDED=1$' "$st"; then
    if id -nG | tr ' ' '\n' | grep -qx "input"; then
      if [[ "$DRY" -eq 1 ]]; then
        info "Plan: sudo gpasswd -d $USER input"
      else
        if sudo_run gpasswd -d "$USER" input; then
          info "Removed $USER from the 'input' group."
        else
          warn "Could not remove $USER from the 'input' group."
        fi
      fi
    else
      info "User is no longer in the 'input' group."
    fi
  fi

  # 5) restore shortcuts, then remove config dir when safe
  local keep_conf=0
  if ! restore_shortcuts "$CONF_DIR/shortcuts.backup"; then
    keep_conf=1
  fi
  if [[ "$keep_conf" -eq 0 ]] && [[ -d "$CONF_DIR" ]]; then
    if [[ "$DRY" -eq 1 ]]; then
      info "Plan: rm -rf '$CONF_DIR'"
    else
      rm -rf "$CONF_DIR"
      info "Removed config directory $CONF_DIR"
      removed_any=1
    fi
  elif [[ -f "$st" ]]; then
    # At least drop install-state if we keep the dir for a failed shortcut restore
    if [[ "$DRY" -eq 1 ]]; then
      info "Plan: rm -f '$st'"
    else
      rm -f "$st"
      info "Removed install-state (kept $CONF_DIR for shortcut backup)"
    fi
  fi

  if [[ "$removed_any" -eq 0 && "$DRY" -eq 0 ]]; then
    info "Nothing user-scoped left to remove."
  fi
}

rollback_system() {
  local st="$SYS_STATE_DIR/install-state"
  local removed_any=0

  step "Rolling back system install"

  # 1) stop + disable + remove the system service unit (always try)
  if [[ "$DRY" -eq 1 ]]; then
    info "Plan: sudo systemctl stop/disable $SERVICE; rm -f $SYS_UNIT_DIR/$SERVICE; daemon-reload"
  else
    if command -v systemctl >/dev/null 2>&1; then
      sudo_run systemctl stop "$SERVICE" 2>/dev/null || true
      sudo_run systemctl disable "$SERVICE" 2>/dev/null || true
      sudo_run systemctl reset-failed "$SERVICE" 2>/dev/null || true
    fi
    if [[ -f "$SYS_UNIT_DIR/$SERVICE" ]]; then
      sudo_run rm -f "$SYS_UNIT_DIR/$SERVICE"
      info "Removed system service unit: $SYS_UNIT_DIR/$SERVICE"
      removed_any=1
    else
      info "System service unit not found: $SYS_UNIT_DIR/$SERVICE"
    fi
    if command -v systemctl >/dev/null 2>&1; then
      sudo_run systemctl daemon-reload || true
    fi
  fi

  # 2) system binary
  if [[ -f "$SYS_INSTALL_DIR/$APP" ]] || [[ -L "$SYS_INSTALL_DIR/$APP" ]]; then
    if [[ "$DRY" -eq 1 ]]; then
      info "Plan: sudo rm -f '$SYS_INSTALL_DIR/$APP'"
    else
      sudo_run rm -f "$SYS_INSTALL_DIR/$APP"
      info "Removed $SYS_INSTALL_DIR/$APP"
      removed_any=1
    fi
  else
    info "System binary not found: $SYS_INSTALL_DIR/$APP"
  fi

  # 3) greeter group removal (only if the installer added them)
  if [[ -f "$st" ]] && grep -q '^INPUT_GDM_ADDED=1$' "$st"; then
    local gu
    gu="$(sed -n 's/^GREETER_USER=//p' "$st")"
    if [[ -n "$gu" ]] && id -nG "$gu" 2>/dev/null | tr ' ' '\n' | grep -qx "input"; then
      if [[ "$DRY" -eq 1 ]]; then
        info "Plan: sudo gpasswd -d $gu input"
      else
        sudo_run gpasswd -d "$gu" input || warn "Could not remove $gu from 'input' group."
      fi
    fi
  fi

  # 4) system state dir
  if [[ -d "$SYS_STATE_DIR" ]]; then
    if [[ "$DRY" -eq 1 ]]; then
      info "Plan: sudo rm -rf '$SYS_STATE_DIR'"
    else
      sudo_run rm -rf "$SYS_STATE_DIR"
      info "Removed system state dir $SYS_STATE_DIR"
      removed_any=1
    fi
  fi

  if [[ "$removed_any" -eq 0 && "$DRY" -eq 0 ]]; then
    info "Nothing system-scoped left to remove."
  fi
}

do_uninstall() {
  step "Uninstalling and rolling back to previous state"
  if [[ "$DRY" -eq 1 ]]; then
    echo "  DRY RUN — nothing will be changed."
  fi

  # Always attempt both scopes so partial installs (binary-only, unit-only,
  # extension-only, missing install-state) are still cleaned up.
  rollback_system
  rollback_user

  echo
  info "Uninstall finished."
  info "Verify:"
  echo "  systemctl --user status $SERVICE 2>/dev/null || true"
  echo "  systemctl status $SERVICE 2>/dev/null || true"
  echo "  ls -la $INSTALL_DIR/$APP $SYS_INSTALL_DIR/$APP 2>/dev/null || true"
  echo "  ls -la ${HOME}/.local/share/gnome-shell/extensions/${EXT_UUID} 2>/dev/null || true"
}

# --- summary -----------------------------------------------------------------

summary() {
  echo
  step "Summary"
  if [[ "$DRY" -eq 1 ]]; then
    echo "  DRY RUN — nothing changed."
    echo
  fi
  if [[ "$MODE" == "system" ]]; then
    echo "  Mode:         system (global) + user session"
    echo "  Greeter:      $GREETER_USER ($GREETER_TYPE)"
    echo "  Binary:       $SYS_INSTALL_DIR/$APP"
    echo "  Service:      $SERVICE (system, User=$GREETER_USER)"
    echo "  User service: $SERVICE (systemd --user, this session)"
    echo "  Logs (gdm):   journalctl -u $SERVICE -f"
    echo "  Logs (user):  journalctl --user -u $SERVICE -f"
  else
    if [[ "$SESSION" == "wayland" ]]; then
      echo "  Session:   Wayland (reads /dev/input/eventX)"
      if [[ "$INPUT_ACTIVE" -eq 0 ]]; then
        echo "  Next step: Log out and back in for 'input' group to apply"
      fi
    else
      echo "  Session:   X11 (uses xinput test-xi2)"
    fi
    echo "  Binary:  $INSTALL_DIR/$APP"
    echo "  Service: $SERVICE (user)"
    echo "  Logs:    journalctl --user -u $SERVICE -f"
  fi
  if is_gnome; then
    echo "  Restore keys: bash $CONF_DIR/shortcuts.backup"
  fi
  echo
  echo -e "  ${GREEN}PASS${NC} checks passed."
  echo -e "  ${YELLOW}WARN${NC} count: $WARN"
  echo -e "  ${RED}FAIL${NC} count: $FAIL"
}

# --- main --------------------------------------------------------------------

if [[ "$MODE" == "uninstall" ]]; then
  do_uninstall
  exit $((FAIL > 0 ? 1 : 0))
fi

if ! detect_session; then
  error "Cannot detect session type"
  exit 1
fi
info "Detected session: $SESSION"
if [[ "$SESSION" == "x11" ]] && ! command -v xinput >/dev/null 2>&1; then
  error "xinput is required for X11 sessions. Install it first: sudo apt install xinput"
  exit 1
fi

resolve_binary

if [[ "$MODE" == "system" ]]; then
  install_system
  # Also set up the current user session so layout switching works after login,
  # not only on the greeter/login screen.
  step "Also installing for the current user session"
  # Prefer the system binary path for the user service when available
  if [[ -x "$SYS_INSTALL_DIR/$APP" ]]; then
    BIN="$SYS_INSTALL_DIR/$APP"
  elif [[ -x "$BIN" ]]; then
    :
  fi
  if is_gnome; then
    install_extension || true
    disable_shortcuts
  fi
  if [[ "$SESSION" == "wayland" ]]; then
    ensure_input_group || true
  fi
  install_service || true
  write_user_state
  verify_system
  # user-side checks (service enabled in this session)
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    if [[ "$(systemctl --user is-enabled "$SERVICE" 2>/dev/null)" == "enabled" ]]; then
      v_pass "user service enabled"
    else
      v_warn "user service not enabled (login screen still covered by system unit)"
    fi
  fi
  summary
  exit $((FAIL > 0 ? 1 : 0))
fi

install_binary
if is_gnome; then
  # Install and enable the extension before starting the daemon: otherwise
  # the first backend check races extension registration on GNOME 42.
  install_extension || true
  disable_shortcuts
fi
if [[ "$SESSION" == "wayland" ]]; then
  ensure_input_group || true
fi
install_service || true
write_user_state
verify
summary

exit $((FAIL > 0 ? 1 : 0))
