#!/bin/sh
set -eu
case "$1" in
    amd64) rust_arch=x86_64-unknown-linux-gnu ;;
    arm64) rust_arch=aarch64-unknown-linux-gnu ;;
    *) echo 'MCC Docker supports only linux/amd64 and linux/arm64.' >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$work"
for component in rustc cargo rust-std; do
    package="${component}-1.89.0-${rust_arch}"
    archive="${package}.tar.xz"
    curl --fail --location --retry 4 --connect-timeout 30 --max-time 600 \
        "https://static.rust-lang.org/dist/2025-08-07/${archive}" -o "$archive"
    awk -v file="$archive" '$2 == file { print; found=1 } END { if (!found) exit 1 }' /checksums/rust.sha256 | sha256sum -c -
    tar -xJf "$archive"
    "./${package}/install.sh" --prefix=/opt/rust --disable-ldconfig
    rm -rf "$archive" "$package"
done
