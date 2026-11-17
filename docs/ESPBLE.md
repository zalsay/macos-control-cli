# ESP32 BLE command interface

`mcc --eb` (`espble`) adapts the `macos-ble-control` / `mbc` client maintained in this project's [`mbc/`](../mbc/README.md) directory. Full MCC builds bundle both BLE executable names and their sources under `source/mbc/`; a separate MBC installation is unnecessary. The current client targets the paired `pilot-2` device. The existing BLE protocol and ESP firmware are unchanged.

The executable next to MCC is preferred. Only when that file is absent does MCC search `PATH` for `macos-ble-control`, retaining compatibility with separately installed clients. A present but broken, nonexecutable or failed bundled client returns an error without trying a PATH client or replaying input.

From source, `sh mbc/build.sh` builds the BLE executables under `target/mbc/`; `bash build.sh debug` builds a complete MCC package. Its `module.json` declares `bleClient: macos-ble-control`; the installer checks both BLE binaries and their signatures before installing a declared BLE package. Older packages without the declaration remain supported. Full installation keeps the BLE executables in MCC's stable directory and does not replace standalone `~/.local/bin/mbc` or `macos-ble-control` commands.

```bash
mcc --eb --help
mcc --eb status
mcc --eb move 52,54
mcc --eb click 52,54
mcc --eb click
mcc --eb type 'Hello 123!'
mcc --eb key cmd+a
mcc --eb scroll -3,0
```

The first subcommand becomes the corresponding MBC flag: `status` becomes `--status`, `move` becomes `--move`, and likewise for `click`, `type`, `key`, and `scroll`. Subsequent arguments pass through unchanged as separate argument values, without a shell. Text containing spaces, quotes, a leading `--`, or newlines remains one value.

MBC flag sequences are also supported, including its command preview:

```bash
mcc --eb --move 52,54 --click
mcc --eb move 52,54 --click
mcc --eb --type 'Hello' --key enter
mcc --eb --dry-run --move 52,54 --click
```

Only the first bare subcommand is translated. Use MBC flags for subsequent actions; for example, use `move 52,54 --click`, not `move 52,54 click`.

## JSON scripts

`mcc script --connection <id> --file /absolute/flow.json` also works with the existing `--remote` prefix. Set `"eb":true` on each desired input step; other steps retain the original backend. Script coordinates are window screenshot pixels, as for per-operation Host input. See [JSON format, examples and execution limits](SCRIPT.md).

## Coordinates and input

- Coordinates are integer screen percentages from **0 to 100**, not ordinary MCC's window-frame pixels. The current ESP firmware is configured for one 3440×1440 screen. S3 computes the existing mouse curves.
- `click x,y` moves and left-clicks. Without coordinates, MBC uses the last explicit move/click target in the current argument sequence, or reads the sending Mac's main-screen pointer and rounds to percentages. Reading the pointer assumes sender and HID recipient are the same Mac and introduces rounding error.
- `type` uses the firmware's US HID keyboard mapping: printable ASCII, newline, and Tab. The client splits text and preserves trailing spaces. Direct Chinese / arbitrary Unicode input is unsupported; the target Mac's input source determines the resulting characters.
- `key` supports the client's existing key names and `cmd`/`gui`, `ctrl`, `shift`, and `alt` combinations.
- `scroll v[,h]` accepts -127 to 127. Positive values scroll up/right; negative values scroll down/left. This differs from ordinary MCC's `--delta-y`, where positive means down.

The BLE client retains responsibility for validating the entire sequence, connecting, writing packets, and waiting for each firmware acknowledgment. Its current connection/command timeout is 20 seconds. `OK` confirms firmware handling, not the UI result; observe the target application to verify that result. Failure does not trigger an automatic retry or a software-input fallback.

## Output and lifecycle

BLE invocations directly inherit the client's standard input/output/error and preserve its numeric exit status. They do **not** add MCC's normal single-line JSON envelope. An MCC-side parse/startup error still uses MCC's normal error envelope; a missing executable returns `BLE_CLIENT_NOT_FOUND` with complete-package/build/PATH guidance.

`mcc --eb`, `mcc --eb help`, `mcc --eb -h`, and `mcc --eb --help` display local help without requiring MBC, connecting to Bluetooth, or creating MCC runtime/config state. `--dry-run` requires MBC but does not connect to Bluetooth.

The standalone prefix form (`mcc --eb …`) is local-only and is also available in `desktop-control` mode. That prefix form is unavailable through the Chrome-only entry or `--remote`; the per-operation flag described below is supported through Host. It does not start MCC's desktop daemon/helper, Chrome, or model requests, and does not attach to an existing desktop connection. End your own MCC desktop input connection before switching input methods; do not use BLE to bypass an explicit user pause. Inputs affect the target Mac's current focus; window observation, activation, and pause management remain separate.

## Per-operation ESP input through Host

Add the valueless `--eb` option to an ordinary `click`, `click-target`, `type`, `press`, or `scroll` request. The macOS Host uses its own MBC for that input. Docker/Linux Hosts reject `eb:true` with `BLE_UNSUPPORTED` before input; they never fall back to X11. Omit the option on the next request to use software input again. `host start` does not change. Both client and Host need matching updated builds; the installed versions are not updated by source edits.

```bash
mcc --remote wss://host.example:8765/mcc/v1 \
  --ca-cert /absolute/host-ca.pem --token-file /absolute/access.token \
  click --connection <connectionId> --frame <frameId> --x 100 --y 200 --eb

mcc --remote wss://host.example:8765/mcc/v1 \
  --ca-cert /absolute/host-ca.pem --token-file /absolute/access.token \
  type --connection <connectionId> --frame <frameId> --text 'Hello' --eb
```

Direct Host API requests use the optional boolean field `"eb": true`; `false` or omission uses the original input path:

```json
{"action":"click","connectionId":"conn-id","frameId":"frame-id","x":100,"y":200,"eb":true}
```

These coordinates retain ordinary MCC **window screenshot pixels**. The existing Service converts them to screen points, then the native helper maps them to MBC percentages. Returned `screenPoint` for BLE pointer input is the rounded mapped point, and `eb:true` identifies the transport; it does not prove the application result. Output remains MCC JSON. Screenshots, OCR, Jev, session ownership, frame retention/geometry, window activation, focus checks, countdown, and manual pause remain in the existing chain. `click-target --eb` forwards its selected point through the same single-click path. The standalone prefix form `mcc --eb click 52,54` retains its own percent-coordinate syntax and local-only behavior.

The Host Mac must be the ESP HID recipient, have Bluetooth access, and have `pilot-2` paired. The helper prefers its sibling `macos-ble-control` and uses PATH only when absent. An old client without the internal controlled-input handshake fails before receiving an input permit. No software fallback or automatic replay occurs.

Current firmware limits are explicit:

- Pointer operations support one active display, the main display. Integer percentages can shift the point by up to half a percent per axis; a rounded point outside the target window is rejected. Double-click is rejected because existing firmware cannot guarantee double-click timing.
- HID wheel notches differ from MCC pixel scrolling: each 40 requested pixels maps to one notch, rounding the magnitude up and reversing the sign for the firmware convention. The result is approximate.
- Text is US keyboard ASCII. MBC validates the entire plan before activation or input. A request may contain at most 16 firmware commands, including text chunks and trailing spaces; split longer text into separately submitted requests. Unicode and unsupported keys fail before input.
- Each firmware command requires a fresh helper permit after focus/geometry checks and waits for the original write confirmation and firmware ACK. The internal MBC `--host-controlled` process mode uses `HOST_READY n` / `GO n` / `HOST_ACK n` and a final `HOST_DONE n`; it is not a remote shell or a firmware protocol change.
- ESP-generated HID pointer events are indistinguishable from physical mouse events to the existing monitor. Pointer soft-pauses are suppressed only during an authorized pointer packet's interval; physical mouse motion during that interval cannot reliably pause it. The toolbar's explicit pause/cancel and focus-loss checks remain active. Outside that interval the original pointer monitor applies.
- Firmware cannot revoke an already accepted packet. Pause/disconnect during delivery or a missing ACK stops later permits and preserves an uncertain/recovery state; it never returns a confirmed-stop receipt for outstanding ESP input. Check the desktop and let ESP finish before stopping your owned Host/daemon, recovering its state, and starting a fresh helper. Resuming the toolbar or submitting another request cannot clear that uncertainty.

The same operation-level option is accepted locally through the existing daemon/helper, with the same gates and limits.

## Focused validation

```bash
cargo test --locked --test espble
cargo test --locked --test remote_args --test remote_protocol
cargo test --locked --test behavior eb_
cargo test --locked --test semantic_click semantic_eb_
cargo test --locked --test remote_process remote_eb_
bash tests/espble-native.sh
sh mbc/build.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s mbc/tests -p test_mbc_cli.py -v
bash build.sh debug
python3 tests/mbc-package.py dist/copis-chrome-4.0.0-darwin-arm64
./dist/copis-chrome-4.0.0-darwin-arm64/mcc --eb status
```

The Rust integration tests substitute only the BLE executable and exercise MCC's real parser, dispatch, argument transport, stdio, failure exit status, sibling-client preference, missing-backend behavior, local help, and lack of desktop runtime creation. MBC's CLI tests use dry runs and invalid inputs. The package check validates signatures, included sources, operation without a standalone MBC on PATH, temporary-prefix installation, and rejection of incomplete BLE payloads. Status exercises the bundled real client and requires the actual device. These are scoped checks for this interface, not a full MCC or ESP firmware regression run. Intel builds use the `darwin-x64` directory and require native Intel validation.
