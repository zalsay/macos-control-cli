#!/bin/sh
# 测试专用：不采集屏幕、不投递真实输入。
mode=chrome
if [ "$#" -eq 1 ] && [ "$1" = "--desktop" ]; then
  mode=desktop
elif [ "$#" -ne 0 ]; then
  exit 2
fi
if [ "$mode" = desktop ]; then
  runtime_dir=$COPIS_DESKTOP_RUNTIME_DIR
  window='{"windowId":42,"pid":123,"title":"Fixture","bundleId":"com.google.Chrome","appName":"Google Chrome","bounds":{"x":0,"y":0,"width":800,"height":600}}'
else
  runtime_dir=$COPIS_CHROME_RUNTIME_DIR
  window='{"windowId":42,"pid":123,"title":"Fixture","bounds":{"x":0,"y":0,"width":800,"height":600}}'
fi
# A marker (never the secret itself) exposes unintended credential inheritance.
if [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${JEV_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY+x}" ]; then
  [ -z "$runtime_dir" ] || printf inherited > "$runtime_dir/key-inherited"
fi
[ -z "$runtime_dir" ] || printf '%s' "$mode" > "$runtime_dir/helper-mode"
transport_phase=awaitingCountdown
transport_paused=false
transport_recovery=false
transport_epoch=0
transport_lease=null
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"expectedInputEpoch":'*)
      case "$line" in
        *'"action":"click"'*|*'"action":"scroll"'*|*'"action":"type"'*|*'"action":"press"'*|*'"action":"select-file"'*|*'"action":"chrome-start"'*)
          expected=$(printf '%s' "$line" | sed -n 's/.*"expectedInputEpoch":\([0-9]*\).*/\1/p')
          if [ "$transport_paused" = true ] || [ "$expected" != "$transport_epoch" ]; then
            printf '{"id":"%s","ok":false,"error":{"code":"USER_PAUSED","message":"fake stale epoch"}}\n' "$id"
            continue
          fi ;;
      esac ;;
  esac
  case "$line" in
    *'"action":"transport-state"'*|*'"action":"transport-pause"'*|*'"action":"transport-recover"'*)
      if [ "${MCC_FAKE_TRANSPORT_UNSUPPORTED:-0}" = 1 ]; then
        printf '{"id":"%s","ok":false,"error":{"code":"UNKNOWN_ACTION","message":"unsupported fake transport"}}\n' "$id"
        continue
      fi
      if [ "${MCC_FAKE_TRANSPORT_WRONG_ACK:-0}" = 1 ]; then
        printf '{"id":"transport-stale","ok":true,"data":{"paused":true}}\n'
      fi
      if [ "$transport_paused" = true ] && [ "$transport_lease" != null ] && [ -n "${MCC_FAKE_REMOTE_RESUME:-}" ] && [ -e "$MCC_FAKE_REMOTE_RESUME" ]; then
        rm "$MCC_FAKE_REMOTE_RESUME"
        transport_epoch=$((transport_epoch + 1)); transport_paused=false; transport_phase=countdown; transport_recovery=false
      fi
      extra=''
      case "$line" in
        *'"action":"transport-pause"'*)
          if [ "$transport_paused" != true ]; then transport_epoch=$((transport_epoch + 1)); fi
          transport_paused=true; transport_phase=paused; transport_recovery=true; extra=',"recovered":false' ;;
        *'"action":"transport-recover"'*)
          transport_epoch=$((transport_epoch + 1)); transport_paused=false; transport_phase=awaitingCountdown; transport_recovery=false; transport_lease=null ;;
      esac
      data="{\"transportPauseVersion\":1,\"paused\":$transport_paused,\"phase\":\"$transport_phase\",\"inputEpoch\":$transport_epoch,\"lease\":$transport_lease,\"recoveryRequired\":$transport_recovery$extra}" ;;
    *'"action":"permissions"'*)
      requested=false
      case "$line" in *'"request":true'*) requested=true ;; esac
      data="{\"screenRecording\":true,\"accessibility\":true,\"chromeAutomation\":{\"target\":\"com.google.Chrome\",\"requested\":$requested,\"granted\":true,\"status\":\"granted\",\"osStatus\":0}}" ;;
    *'"action":"apps"'*) data='{"apps":[{"pid":123,"bundleId":"com.google.Chrome","name":"Google Chrome"}]}' ;;
    *'"action":"windows"'*) data="{\"windows\":[$window]}" ;;
    *'"action":"window"'*)
      if [ -n "${MCC_FAKE_REMOTE_WINDOW_FAIL:-}" ] && [ -e "$MCC_FAKE_REMOTE_WINDOW_FAIL" ]; then
        printf '{"id":"%s","ok":false,"error":{"code":"WINDOW_UNAVAILABLE","message":"fake unavailable"}}\n' "$id"
        continue
      fi
      if [ -n "${MCC_FAKE_REMOTE_SLOW_WINDOW:-}" ] && [ -e "$MCC_FAKE_REMOTE_SLOW_WINDOW" ]; then
        printf active > "${MCC_FAKE_REMOTE_SLOW_WINDOW}.started"
        (sleep 2; printf '{"id":"%s","ok":true,"data":{"window":%s}}\n' "$id" "$window") &
        continue
      fi
      # Optional synthetic lease for focused state-machine tests; real connect only
      # prepares an anchor and does not create an execution lease.
      if [ "${MCC_FAKE_PREPARE_LEASE:-0}" = 1 ]; then
        case "$line" in *'"prepareToast":true'*) transport_lease=1; transport_phase=running ;; esac
      fi
      data="{\"window\":$window}" ;;
    *'"action":"observe"'*)
      path=$(printf '%s' "$line" | sed -n 's/.*"imagePath":"\([^"]*\)".*/\1/p')
      printf '\377\330\377\331' > "$path"
      extra=''
      if [ "${MCC_FAKE_REMOTE_OCR:-0}" = 1 ]; then
        extra=',"coordinateSpace":"frame-pixels","imageTransform":"crop-only","ocr":{"status":"ok","truncated":false,"items":[{"text":"Save","bbox":{"x":10,"y":20,"width":100,"height":40},"center":{"x":60,"y":40},"confidence":0.99}]}'
      fi
      data="{\"imagePath\":\"$path\",\"width\":1600,\"height\":1200,\"bounds\":{\"x\":0,\"y\":0,\"width\":800,\"height\":600},\"capturedAtMs\":1$extra}" ;;
    *'"action":"click"'*)
      if [ "$transport_lease" = null ]; then transport_lease=1; transport_phase=running; fi
      if [ -n "${MCC_FAKE_REMOTE_TRACE:-}" ]; then printf 'click\n' >> "$MCC_FAKE_REMOTE_TRACE"; fi
      data='{"sent":true}' ;;
    *'"action":"type"'*'"text":"paused"'*) printf '{"id":"%s","ok":false,"error":{"code":"USER_PAUSED","message":"secret fixture detail"}}\n' "$id"; continue ;;
    *'"action":"type"'*'"text":"eof"'*) exit 0 ;;
    *'"action":"type"'*'"text":"slow"'*) printf active > "$runtime_dir/input-started"; IFS= read -r ignored; data='{"sent":true}' ;;
    *'"action":"transport-disconnect"'*)
      expected=$(printf '%s' "$line" | sed -n 's/.*"expectedInputEpoch":\([0-9]*\).*/\1/p')
      if [ "$transport_paused" = true ] || [ "$transport_recovery" = true ] || [ "$expected" != "$transport_epoch" ]; then
        printf '{"id":"%s","ok":false,"error":{"code":"USER_PAUSED","message":"fake paused"}}\n' "$id"
        continue
      fi
      transport_lease=null; transport_phase=awaitingCountdown; transport_epoch=$((transport_epoch + 1))
      data='{"cancelled":true}' ;;
    *'"action":"cancel"'*)
      transport_lease=null
      if [ "$transport_recovery" != true ]; then transport_paused=false; transport_phase=awaitingCountdown; fi
      data='{"cancelled":true}' ;;
    *) data='{"sent":true}' ;;
  esac
  printf '{"id":"%s","ok":true,"data":%s}\n' "$id" "$data"
done
