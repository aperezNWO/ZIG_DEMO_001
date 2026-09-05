# Stage 1: Build the Zig binary
FROM alpine:latest AS builder
RUN apk add --no-cache curl bash
# Download and extract Zig 0.16.0 (or match your local development version)
ARG ZIG_VERSION=0.16.0
RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz -o zig.tar.xz && \
    tar -xf zig.tar.xz && \
    mv zig-x86_64-linux-${ZIG_VERSION} /opt/zig

WORKDIR /app
COPY . .

# Build release-optimized binary
RUN /opt/zig/zig build -Doptimize=ReleaseFast

# Stage 2: Runtime Environment
FROM alpine:latest
WORKDIR /app

# Copy compiled binary and any required assets from builder
COPY --from=builder /app/zig-out/bin/ZIG_DEMO_001 /app/fractal-server

EXPOSE 8080

CMD ["./fractal-server"]