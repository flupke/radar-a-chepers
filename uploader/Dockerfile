FROM rustlang/rust:nightly AS builder
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:trixie-slim
WORKDIR /app
RUN mkdir /tmp/infractions
COPY --from=builder /app/target/release/uploader .
ENTRYPOINT ["./uploader"]
