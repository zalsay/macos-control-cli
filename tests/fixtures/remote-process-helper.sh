#!/bin/sh
# Test-only proxy around the shared fake helper; no GUI input or capture.
umask 077
helper="$(dirname "$0")/fake-helper.sh"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$COPIS_DESKTOP_RUNTIME_DIR/native-requests.ndjson"
  printf '%s\n' "$line"
done | "$helper" "$@" | while IFS= read -r response; do
  case "$response" in
    *'"imagePath":'*'"width":1600,"height":1200'*)
      path=$(printf '%s' "$response" | sed -n 's/.*"imagePath":"\([^"]*\)".*/\1/p')
      # Structurally framed 1600x1200 JPEG (SOI, SOF, SOS, entropy, EOI),
      # matching the fake helper's dimensions. It is not a real screenshot.
      [ -n "$path" ] || exit 1
      printf '\377\330\377\300\000\013\010\004\260\006\100\001\001\021\000\377\332\000\010\001\001\000\000\077\000\000\377\331' > "$path" || exit 1
      ;;
  esac
  # Only adapt this test's synthetic select-file receipt; all transport and
  # other native replies remain the original fake helper's output.
  id=$(printf '%s' "$response" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  if [ -n "$id" ] && printf '%s' "$response" | grep -Fq '"data":{"sent":true}' &&
     grep -F "\"id\":\"$id\"" "$COPIS_DESKTOP_RUNTIME_DIR/native-requests.ndjson" | grep -Fq '"action":"select-file"'; then
    response=$(printf '%s' "$response" | sed 's/"data":{"sent":true}/"data":{"selected":true,"dialogClosed":true}/')
  fi
  # Capture only the dummy transport receipt needed to prove pause ACK.
  if [ -n "$id" ] && grep -F "\"id\":\"$id\"" "$COPIS_DESKTOP_RUNTIME_DIR/native-requests.ndjson" | grep -Fq '"action":"transport-pause"'; then
    printf '%s\n' "$response" >> "$COPIS_DESKTOP_RUNTIME_DIR/native-pause-responses.ndjson"
  fi
  printf '%s\n' "$response"
done
