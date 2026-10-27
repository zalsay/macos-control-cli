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
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"action":"permissions"'*)
      requested=false
      case "$line" in *'"request":true'*) requested=true ;; esac
      data="{\"screenRecording\":true,\"accessibility\":true,\"chromeAutomation\":{\"target\":\"com.google.Chrome\",\"requested\":$requested,\"granted\":true,\"status\":\"granted\",\"osStatus\":0}}" ;;
    *'"action":"apps"'*) data='{"apps":[{"pid":123,"bundleId":"com.google.Chrome","name":"Google Chrome"}]}' ;;
    *'"action":"windows"'*) data="{\"windows\":[$window]}" ;;
    *'"action":"window"'*) data="{\"window\":$window}" ;;
    *'"action":"observe"'*)
      path=$(printf '%s' "$line" | sed -n 's/.*"imagePath":"\([^"]*\)".*/\1/p')
      printf '\377\330\377\331' > "$path"
      data="{\"imagePath\":\"$path\",\"width\":1600,\"height\":1200,\"bounds\":{\"x\":0,\"y\":0,\"width\":800,\"height\":600},\"capturedAtMs\":1}" ;;
    *'"action":"type"'*'"text":"paused"'*) printf '{"id":"%s","ok":false,"error":{"code":"USER_PAUSED","message":"secret fixture detail"}}\n' "$id"; continue ;;
    *'"action":"type"'*'"text":"eof"'*) exit 0 ;;
    *'"action":"type"'*'"text":"slow"'*) printf active > "$runtime_dir/input-started"; IFS= read -r ignored; data='{"sent":true}' ;;
    *'"action":"cancel"'*) data='{"cancelled":true}' ;;
    *) data='{"sent":true}' ;;
  esac
  printf '{"id":"%s","ok":true,"data":%s}\n' "$id" "$data"
done
