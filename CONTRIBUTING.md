# Contributing to gnome-layout-switch

Thank you for your interest in contributing!

## Prerequisites

- **Docker** (recommended) — build without installing Go
- **Go 1.27+** (optional) — local development and testing
- **golangci-lint** — code quality checks (install via `make install-lint`)

## Quick Start

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

## Development Workflow

1. Format code: `make fmt`
2. Run linters: `make lint`
3. Auto-fix issues: `make lint-fix`
4. Run full CI pipeline: `make ci` (lint + build)

## Making Changes

1. Create a feature branch from `main`
2. Make your changes
3. Run `make ci` to verify everything passes
4. Submit a pull request

## Code Style

- Follow standard Go formatting (`gofumpt` via `make fmt`)
- All linters in `.golangci.yml` must pass
- Add doc comments for new exported functions and types
- Keep functions focused and under 120 lines (`funlen` linter)

## Testing

No automated tests exist currently. When adding tests:

- Place test files alongside the code they test (`*_test.go`)
- Use table-driven tests for multiple cases
- Run `go test ./...` to execute

## Reporting Issues

- Use GitHub Issues for bugs and feature requests
- Include GNOME version, session type (X11/Wayland), and steps to reproduce
- Attach relevant logs (`journalctl --user -u gnome-layout-switch.service -f`)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.