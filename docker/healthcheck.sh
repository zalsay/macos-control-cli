#!/bin/bash
set -euo pipefail
[[ -f "$XDG_RUNTIME_DIR/desktop-ready" ]]
count=0
host_pid=
while read -r name pid; do
    [[ $pid =~ ^[0-9]+$ ]]
    kill -0 "$pid"
    # kill -0 also succeeds for zombies, which are not healthy processes.
    [[ $(awk '{print $3}' "/proc/$pid/stat") != Z ]]
    count=$((count + 1))
    if [[ $name == host ]]; then host_pid=$pid; fi
done < "$XDG_RUNTIME_DIR/desktop-pids"
case ${MCC_HOST_ENABLED:-0} in
    0) [[ $count == 6 && -z $host_pid ]] ;;
    1)
        [[ $count == 7 && -n $host_pid ]]
        # Inspect the Host's owned listener without consuming its TLS/auth
        # failure budget with unauthenticated network health probes.
        python3 - "$host_pid" <<'PY'
from pathlib import Path
import sys
root = Path('/proc') / sys.argv[1]
owned = set()
for fd in (root / 'fd').iterdir():
    try:
        owned.add(fd.readlink().as_posix())
    except FileNotFoundError:
        pass  # A connection may close while enumerating descriptors.
for table in ('tcp', 'tcp6'):
    path = root / 'net' / table
    if not path.exists():
        continue
    for row in path.read_text().splitlines()[1:]:
        fields = row.split()
        if (fields[1].rsplit(':', 1)[1] == '223D' and fields[3] == '0A'
                and f'socket:[{fields[9]}]' in owned):
            sys.exit(0)
sys.exit(1)
PY
        ;;
    *) exit 1 ;;
esac
timeout 2 xdpyinfo -display "$DISPLAY" >/dev/null
timeout 2 xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id # 0x'
curl --fail --silent --max-time 2 http://127.0.0.1:6080/vnc.html >/dev/null
timeout 4 /opt/mcc/bin/mcc daemon status | python3 -c 'import json,sys; v=json.load(sys.stdin); sys.exit(0 if v.get("ok") is True and v.get("running") is True else 1)'
