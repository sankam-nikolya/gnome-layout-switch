.PHONY: lint lint-fix fmt build clean

# Run all configured linters
lint:
	golangci-lint run ./...

# Auto-fix issues where possible
lint-fix:
	golangci-lint run --fix ./...

# Format code (golangci-lint v2+)
fmt:
	golangci-lint fmt ./...

# Build the binary using Docker
build:
	bash build.sh

# Clean build artifacts
clean:
	bash build.sh --clean

# Run lint, then build (CI pipeline)
ci: lint build

# Install golangci-lint if not present
install-lint:
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
