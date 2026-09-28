# syntax=docker/dockerfile:1.7

# ----- build stage -----
# Produce a fully static Linux binary. CGO is off, no glibc/musl linkage.
FROM golang:1.27-alpine AS builder
ARG VERSION=dev

WORKDIR /src

# Cache modules separately from sources.
COPY go.mod ./
RUN go mod download

COPY . .

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

RUN go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o /out/hello .

# ----- runtime stage -----
# alpine 3.20 instead of scratch / distroless because we need a shell
# to handle hot-swap signals in Part II (docker exec + kill -HUP 1).
# tini reaps zombies and forwards signals to PID 1 cleanly.
FROM alpine:3.20 AS runtime

RUN apk add --no-cache ca-certificates tini \
 && addgroup -S app && adduser -S app -G app

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --from=builder /out/hello /usr/local/bin/hello

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/hello

USER app
EXPOSE 8080

# /tmp is where docker cp drops new binaries during hot-swap.
# Perms kept writable so supervisor can copy the new binary into place.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
