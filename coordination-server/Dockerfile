# Dockerfile for the Aonsoku coordination server.
# Builds a minimal static binary and serves it on port 3000.
# The data directory and stable HMAC key must be persisted across restarts
# (design §14).

FROM rust:1.96-slim AS builder

WORKDIR /build
COPY . .
RUN cargo build --release --bin aonsoku-coordination-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/aonsoku-coordination-server /usr/local/bin/aonsoku-coordination-server

ENV AONSOKU_COORD_LISTEN=0.0.0.0:3000
ENV AONSOKU_COORD_DATA_DIR=/data

VOLUME ["/data"]
EXPOSE 3000

CMD ["aonsoku-coordination-server"]