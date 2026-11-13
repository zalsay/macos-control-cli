# syntax=docker/dockerfile:1
# All binaries are built for the target architecture on Ubuntu 22.04 (glibc 2.35).
FROM ubuntu:22.04 AS browser-download
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY docker/firefox.sha512 /checksums/
COPY docker/install-browser.sh /usr/local/bin/install-browser
RUN /bin/sh /usr/local/bin/install-browser "$TARGETARCH"

# This target can be built independently while the Rust implementation changes.
FROM ubuntu:22.04 AS desktop-base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl dbus-x11 fonts-dejavu-core fonts-noto-cjk \
    libasound2 libatk-bridge2.0-0 libdbus-glib-1-2 libgbm1 libgtk-3-0 \
    libnss3 libx11-xcb1 libxt6 locales novnc openbox procps python3 \
    tesseract-ocr tesseract-ocr-eng tesseract-ocr-chi-sim tini \
    websockify x11-utils x11vnc xauth xdotool xvfb \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=browser-download /opt/firefox /opt/firefox
RUN groupadd --gid 1000 mcc && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash mcc \
    && install -d -m 0700 -o mcc -g mcc /home/mcc/.config/mcc \
       /home/mcc/.local/share/mcc/profiles/firefox /home/mcc/.local/share/mcc/transfers /home/mcc/.secrets \
    && chown -R mcc:mcc /home/mcc \
    && install -d -m 0755 /opt/mcc/bin
ENV HOME=/home/mcc LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    DISPLAY=:99 XAUTHORITY=/tmp/mcc-runtime/Xauthority \
    XDG_RUNTIME_DIR=/tmp/mcc-runtime \
    COPIS_DESKTOP_RUNTIME_DIR=/tmp/mcc-runtime/desktop \
    COPIS_DESKTOP_HELPER=/opt/mcc/bin/mcc-linux-helper \
    MCC_CONFIG_DIR=/home/mcc/.config/mcc \
    MCC_DOCKER=1 MCC_FIREFOX_BINARY=/opt/firefox/firefox \
    MCC_FIREFOX_PROFILE_ROOT=/home/mcc/.local/share/mcc/profiles/firefox \
    MCC_UPLOAD_DIR=/home/mcc/.local/share/mcc/transfers \
    MCC_VNC_PASSWORD_FILE=/home/mcc/.secrets/vnc-password \
    PATH=/opt/mcc/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

FROM ubuntu:22.04 AS rust-toolchain
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive CARGO_HOME=/opt/cargo PATH=/opt/rust/bin:$PATH
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl pkg-config xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY docker/rust.sha256 /checksums/rust.sha256
COPY docker/install-rust.sh /usr/local/bin/install-rust
RUN /bin/sh /usr/local/bin/install-rust "$TARGETARCH"

FROM rust-toolchain AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/opt/cargo/git \
    cargo build --release --locked --bin mcc --bin mcc-linux-helper

FROM desktop-base AS runtime
COPY --from=builder /build/target/release/mcc /build/target/release/mcc-linux-helper /opt/mcc/bin/
COPY --chmod=755 docker/desktop-entrypoint.sh /opt/mcc/bin/mcc-desktop-entrypoint
COPY --chmod=755 docker/healthcheck.sh /opt/mcc/bin/mcc-desktop-healthcheck
COPY --chmod=755 docker/vnc-password.py /opt/mcc/bin/mcc-vnc-password
USER mcc:mcc
WORKDIR /home/mcc
EXPOSE 6080 8765
HEALTHCHECK --interval=15s --timeout=10s --start-period=45s --retries=3 \
    CMD ["/opt/mcc/bin/mcc-desktop-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/mcc/bin/mcc-desktop-entrypoint"]
