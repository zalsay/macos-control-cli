#!/bin/sh
set -eu
case "$1" in
    amd64) firefox_arch=linux-x86_64 ;;
    arm64) firefox_arch=linux-aarch64 ;;
    *) echo 'MCC Docker supports only linux/amd64 and linux/arm64.' >&2; exit 1 ;;
esac
firefox_version=153.7.0esr
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$work"
firefox_file="firefox-${firefox_version}-${firefox_arch}.tar.xz"
curl --fail --location --retry 4 --connect-timeout 30 --max-time 600 \
    "https://archive.mozilla.org/pub/firefox/releases/${firefox_version}/${firefox_arch}/en-US/firefox-${firefox_version}.tar.xz" -o "$firefox_file"
awk -v file="$firefox_file" '$2 == file { print; found=1 } END { if (!found) exit 1 }' /checksums/firefox.sha512 | sha512sum -c -
mkdir -p /opt /usr/local/bin
tar -xJf "$firefox_file" -C /opt
