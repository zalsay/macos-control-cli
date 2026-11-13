#!/bin/bash
set -Eeuo pipefail
umask 077

fail() { printf 'MCC desktop: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) != 0 ]] || fail 'run the desktop as the image user mcc, not root.'
[[ $# == 0 ]] || fail 'use docker compose exec mcc mcc ... for CLI commands.'
[[ ${DISPLAY:-} =~ ^:[0-9]+$ ]] || fail 'DISPLAY must name a local Xvfb display, for example :99.'
screen_size=${MCC_SCREEN_SIZE:-1440x900}
[[ $screen_size =~ ^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$ ]] || fail 'MCC_SCREEN_SIZE must be WIDTHxHEIGHT (100–9999 pixels).'
host_enabled=${MCC_HOST_ENABLED:-0}
[[ $host_enabled == 0 || $host_enabled == 1 ]] || fail 'MCC_HOST_ENABLED must be 0 or 1.'
/opt/mcc/bin/mcc-vnc-password --check "$MCC_VNC_PASSWORD_FILE"

for directory in "$XDG_RUNTIME_DIR" "$COPIS_DESKTOP_RUNTIME_DIR" "$MCC_CONFIG_DIR" "$MCC_FIREFOX_PROFILE_ROOT"; do
    [[ ! -L $directory ]] || fail 'runtime/config/profile directories cannot be symlinks.'
    mkdir -p "$directory"
    [[ -O $directory && -w $directory ]] || fail 'runtime/config/profile directory must be writable and owned by mcc (UID 1000).'
    chmod 700 "$directory"
done
if [[ $host_enabled == 1 ]]; then
    [[ ${MCC_UPLOAD_DIR:-} == /* && ! -L $MCC_UPLOAD_DIR ]] || fail 'MCC_UPLOAD_DIR must be an absolute private directory, not a symlink.'
    mkdir -p "$MCC_UPLOAD_DIR"
    [[ -O $MCC_UPLOAD_DIR && -w $MCC_UPLOAD_DIR ]] || fail 'upload directory must be writable and owned by mcc (UID 1000).'
    chmod 700 "$MCC_UPLOAD_DIR"
    for credential in host-tls/host-cert.pem host-tls/host-key.pem host.token; do
        [[ -f "$MCC_CONFIG_DIR/$credential" ]] || fail 'Host credentials missing; initialize mcc host tls/token first (see docs/MCC-DOCKER.md).'
    done
fi
[[ $XAUTHORITY == "$XDG_RUNTIME_DIR/"* ]] || fail 'XAUTHORITY must be inside XDG_RUNTIME_DIR.'
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/dbus.sock"
pids=()
names=()
host_pid=
ready_file="$XDG_RUNTIME_DIR/desktop-ready"
pid_file="$XDG_RUNTIME_DIR/desktop-pids"
rm -f "$ready_file" "$pid_file"

cleanup() {
    local status=$?
    trap - EXIT TERM INT HUP
    rm -f "$ready_file"
    # Host must pause owned input while the daemon/helper are still available.
    if [[ -n $host_pid ]]; then
        kill -TERM "$host_pid" 2>/dev/null || true
        for attempt in {1..70}; do
            if ! kill -0 "$host_pid" 2>/dev/null || [[ $(awk '{print $3}' "/proc/$host_pid/stat" 2>/dev/null) == Z ]]; then break; fi
            sleep 0.1
        done
    fi
    # Then release native input and owned browsers before stopping the display.
    if [[ ${#pids[@]} -gt 0 ]]; then
        timeout 5 /opt/mcc/bin/mcc daemon stop >/dev/null 2>&1 || true
        for ((index=${#pids[@]}-1; index>=0; index--)); do
            kill -TERM -- "-${pids[index]}" 2>/dev/null || true
        done
        for attempt in {1..50}; do
            local alive=false
            for pid in "${pids[@]}"; do
                if kill -0 -- "-$pid" 2>/dev/null; then alive=true; fi
            done
            $alive || break
            sleep 0.1
        done
        for pid in "${pids[@]}"; do kill -KILL -- "-$pid" 2>/dev/null || true; done
        for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    fi
    rm -f "$pid_file"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

start_process() {
    local name=$1
    shift
    setsid -- "$@" &
    pids+=("$!")
    names+=("$name")
    printf '%s %s\n' "$name" "$!" >> "$pid_file"
}

wait_ready() {
    local name=$1
    shift
    for attempt in {1..100}; do
        for index in "${!pids[@]}"; do
            kill -0 "${pids[index]}" 2>/dev/null || fail "${names[index]} exited during startup."
        done
        if timeout 2 "$@" >/dev/null 2>&1; then return; fi
        sleep 0.1
    done
    fail "$name did not become ready."
}

touch "$XAUTHORITY"
chmod 600 "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" . "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
start_process Xvfb Xvfb "$DISPLAY" -screen 0 "${screen_size}x24" -nolisten tcp -auth "$XAUTHORITY" -noreset
wait_ready Xvfb xdpyinfo -display "$DISPLAY"
start_process dbus dbus-daemon --session --nofork --nopidfile --address="$DBUS_SESSION_BUS_ADDRESS"
wait_ready dbus dbus-send --session --type=method_call --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames
start_process openbox openbox --sm-disable
wait_ready openbox bash -c 'xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id # 0x"'
start_process x11vnc x11vnc -display "$DISPLAY" -auth "$XAUTHORITY" \
    -listen 127.0.0.1 -rfbport 5900 -passwdfile "$MCC_VNC_PASSWORD_FILE" \
    -forever -shared -noxdamage -quiet
wait_ready x11vnc python3 -c 'import socket; socket.create_connection(("127.0.0.1", 5900), 1).close()'
start_process noVNC websockify --web=/usr/share/novnc --heartbeat=30 0.0.0.0:6080 127.0.0.1:5900
wait_ready noVNC curl --fail --silent http://127.0.0.1:6080/vnc.html
start_process mcc /opt/mcc/bin/mcc daemon run
if [[ $host_enabled == 1 ]]; then
    start_process host /opt/mcc/bin/mcc host start --listen 0.0.0.0:8765 \
        --tls-cert "$MCC_CONFIG_DIR/host-tls/host-cert.pem" \
        --tls-key "$MCC_CONFIG_DIR/host-tls/host-key.pem" \
        --token-file "$MCC_CONFIG_DIR/host.token" --upload-dir "$MCC_UPLOAD_DIR"
    host_pid=${pids[${#pids[@]}-1]}
fi
# The health command also asks the existing daemon/helper for status.
touch "$ready_file"
wait_ready mcc /opt/mcc/bin/mcc-desktop-healthcheck
printf 'MCC desktop ready; open the loopback noVNC URL published by Compose.\n'

set +e
wait -n "${pids[@]}"
status=$?
set -e
for index in "${!pids[@]}"; do
    if ! kill -0 "${pids[index]}" 2>/dev/null; then
        printf 'MCC desktop: supervised process %s exited; stopping the desktop.\n' "${names[index]}" >&2
    fi
done
# Even an unexpected clean child exit must make the container fail visibly.
if [[ $status == 0 ]]; then status=1; fi
exit "$status"
