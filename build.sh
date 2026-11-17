#!/usr/bin/env bash
set -euo pipefail

# Build gnome-layout-switch using Docker.
# No Go, Node or other toolchains required on the host.
#
# Usage:
#   bash build.sh              # produce ./gnome-layout-switch (no tests)
#   bash build.sh --test       # build and run unit tests
#   bash build.sh --install    # build, then install binary to ~/.local/bin
#   bash build.sh --test --install
#   bash build.sh --clean      # remove build artifacts

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

BINARY_NAME="gnome-layout-switch"
IMAGE_NAME="gnome-layout-builder"
OUTPUT="$ROOT/$BINARY_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

DO_TEST=0
DO_INSTALL=0
DO_CLEAN=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

  (none)         Build static binary (tests NOT run)
  --test         Run unit tests during Docker build
  --install      After build, copy binary to ~/.local/bin
  --clean        Remove local binary and Docker image
  -h, --help     Show this help

Examples:
  bash build.sh
  bash build.sh --test
  bash build.sh --test --install
EOF
}

for arg in "$@"; do
  case "$arg" in
    --test)    DO_TEST=1 ;;
    --install) DO_INSTALL=1 ;;
    --clean)   DO_CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      error "Unknown option: $arg"
      usage
      exit 1
      ;;
  esac
done

do_clean() {
  info "Cleaning..."
  rm -f "$OUTPUT"
  docker image rm -f "$IMAGE_NAME" 2>/dev/null || true
  info "Done."
}

do_build() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Docker not installed or not in PATH."
    exit 1
  fi

  # Remove old image to avoid broken layer
  docker image rm -f "$IMAGE_NAME" 2>/dev/null || true

  local build_args=()
  if [[ "$DO_TEST" -eq 1 ]]; then
    info "Building static binary with Docker (golang:1.27-alpine) + unit tests..."
    build_args+=(--build-arg "RUN_TESTS=1")
  else
    info "Building static binary with Docker (golang:1.27-alpine). Tests skipped (use --test)..."
  fi

  docker build --no-cache "${build_args[@]}" -t "$IMAGE_NAME" -f Dockerfile .

  info "Extracting binary..."
  # Use --entrypoint cat to avoid depending on CMD in image
  docker run --rm --entrypoint cat "$IMAGE_NAME" /gnome-layout-switch > "$OUTPUT"

  if [[ ! -s "$OUTPUT" ]]; then
    error "Extracted binary empty. Build failed."
    rm -f "$OUTPUT"
    exit 1
  fi

  chmod +x "$OUTPUT"
  info "Binary ready: $OUTPUT"
  ls -lh "$OUTPUT"
}

do_install() {
  if [[ ! -x "$OUTPUT" ]]; then
    error "Binary not found. Run ./build.sh first."
    exit 1
  fi

  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
  cp -f "$OUTPUT" "$INSTALL_DIR/"
  info "Installed to $INSTALL_DIR/$BINARY_NAME"

  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "Add \$HOME/.local/bin to PATH if not present."
  fi

  echo
  info "Install systemd user service:"
  echo "  $INSTALL_DIR/$BINARY_NAME --install-service"
  echo
  info "Or run manually:"
  echo "  # X11"
  echo "  $INSTALL_DIR/$BINARY_NAME"
  echo
  echo "  # Wayland (auto-detect)"
  echo "  $INSTALL_DIR/$BINARY_NAME --auto-input"
  echo
  echo "  # Wayland (explicit device)"
  echo "  $INSTALL_DIR/$BINARY_NAME --input /dev/input/event3"
}

if [[ "$DO_CLEAN" -eq 1 ]]; then
  do_clean
  exit 0
fi

do_build

if [[ "$DO_INSTALL" -eq 1 ]]; then
  do_install
fi
