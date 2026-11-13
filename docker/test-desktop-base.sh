#!/bin/bash
# Runs the dependency/visible-browser smoke without building or using Rust.
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
image=${1:-mcc-desktop-base:dev}
security_options=(--security-opt no-new-privileges:true)
if [[ $# -gt 1 ]]; then security_options+=(--security-opt "seccomp=$2"); fi
docker run --rm -i --name "mcc-packaging-base-smoke-$$" --user 1000:1000 --cap-drop ALL \
    "${security_options[@]}" --shm-size 1gb \
    --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
    --entrypoint python3 "$image" - < "$script_directory/test-desktop-base.py"
