# Tauri Configuration Shell Implementation Plan

> Execute inline with the primary agent; no delegated review and no full regression.

**Goal:** Deliver a macOS app for configuring Host, selecting a BLE device and managing JSON scripts.
**Architecture:** Tauri RPC only exposes typed actions; native dialogs choose files. Rust uses MCC validation and runs the existing executables. Swift MBC retains its existing input protocol and opts into UUID selection through a shared private config file.
**Spec:** `docs/superpowers/specs/2026-11-18-tauri-configuration-shell-design.md`

- [x] Add MBC selection tests before implementation, then add discovery and verified status using the existing CoreBluetooth client; rebuild and run targeted tests.
- [x] Add a private App store and typed script CRUD; test invalid input, size limits and preservation of imported originals.
- [x] Reuse Host credential commands, add opt-in bound notification and supervise only the owned Host process. Test failed port bind, startup and shutdown using temporary credentials.
- [x] Build the Tauri UI, package macOS App, run targeted smoke tests and review each boundary. No installation, push or real pointer/keyboard input.

## Verification

- Built the macOS `.app` and the matched complete MCC / helper / MBC debug package. Launched the `.app` with an isolated config directory and confirmed a real WindowServer window.
- Ran browser UI interactions against mock RPC for each page. Ran real MCC Host readiness / port conflict / owned-process shutdown and token permission tests on an isolated loopback setup. Script store and validator checks passed.
- Packaged MBC selection and CLI checks passed. Native helper subprocess test passed, including retention of the selected UUID between preflight and dispatch. Real CoreBluetooth scan completed but reported zero candidates; hardware `status` ACK and HID pairing were not verified.
- No real mouse/keyboard input, installation, production Host change, or GitHub push.
