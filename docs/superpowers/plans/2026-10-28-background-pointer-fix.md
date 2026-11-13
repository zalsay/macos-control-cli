# Background pointer semantics: bounded fix and repeat validation

## Contract

- Work only on `mcc-safarier` at baseline `2f32d21248deaffd8c8c1152a39912aa46350c7e`.
- Fix the existing probe's missing hover and incorrect pressed-button semantics; retain browser-effect assertions.
- Reuse the repository's checked Objective-C engine bridge. No global event posting, application activation, DOM input injection, permission prompts, or real account/profile operations.
- Do not add an AppleScript service, remote endpoint, installer, or a second browser-input implementation.
- Code review is performed only by the main agent. No commit, push, merge, release, or installation in this task.

## Evidence before implementation

- Fresh `fix-red-background` reproduces exactly: `hover`, `custom_pointer_drag_buttons`, `pointer_down_buttons_semantics`.
- Coordinates hit the target WebView; visibleRect contains them; the window is visible but not key; `_ignoresMouseMoveEvents` reads false through the checked bridge.
- Waiting two seconds does not fix hover. Direct checked `_simulateMouseMove:` alone also fails.
- WebKit's native test sender sets mouse deltas and an event context; WebEventFactory reads actual pressed buttons for user-driven native events. Verify those differences independently rather than stacking speculative fixes.

## Tasks

1. Isolate the native movement delivery defect, preserving movement event type and normal CSS/browser effects.
2. Provide only scoped, main-thread, per-process mouse-button state through `SafarierObjCSupport`, with signature validation and unconditional restoration. Background threads must retain the original query. If a required capability cannot be proved, refuse the action without a global fallback.
3. Consolidate the working driver into one reusable owning module and keep the reproducible probe/test sources tracked; do not retain duplicated production input paths.
4. Add tests for correct button masks, restoration after success/exception/nesting, invalid capability handling, and no state leakage to background threads.
5. Repeat isolated browser-effect validation for unfocused, covered, and hidden windows. Verify hover entry/exit, buttons during down/drag/up, custom drag, existing click/type/scroll regressions, front/key-window state, and zero owned global pointer events. Run idle-pointer and external-activity rounds separately.
6. Inspect the complete diff and source safety boundaries, stop only owned fixtures, and report exact pass/fail counts and residual limits.

## Build boundary

Normal SwiftPM manifest linking was already broken on this host. Directly compiling original modules is a diagnostic fallback, not a successful normal build. An ignored compatibility manifest may be used for focused tests without changing the project's tools version or language mode; document that distinction.
