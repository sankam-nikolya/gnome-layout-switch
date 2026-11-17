# Multi-stage build — no Go required on the host
# Usage:
#   bash build.sh              # binary only
#   bash build.sh --test       # binary + unit tests
#
# Build-arg RUN_TESTS=1 enables "go test ./..." before the final link.

FROM golang:1.27-alpine AS builder

ARG RUN_TESTS=0

RUN apk add --no-cache ca-certificates

WORKDIR /src
COPY go.mod .
COPY *.go .

# Optional unit tests (default: off). Enable with:
#   docker build --build-arg RUN_TESTS=1 ...
#   or: bash build.sh --test
RUN if [ "$RUN_TESTS" = "1" ]; then \
      echo "==> Running unit tests..." && go test ./... ; \
    else \
      echo "==> Skipping unit tests (pass RUN_TESTS=1 or build.sh --test)" ; \
    fi

# Static binary, stripped
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w -X main.appVersion=1.3.0" \
    -o /gnome-layout-switch \
    gnome-layout-switch.go
