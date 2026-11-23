# DSH SFA tool

Use `sfa` in DSH instead of sending SFA commands through Bash. The tool takes a
profile UUID and binds a verified connection to the initiating DSH session.
For example:

```json
{"operation":"connect","profile":"01234567-89ab-cdef-0123-456789abcdef"}
```

Use the same profile with `state`, `observe`, `navigate`, `click-target`,
`click`, `press`, `type` and `release`. No connection ID needs to be copied among
calls. A duplicate `connect` from the owning session reuses its connection;
other sessions get `SESSION_BUSY`. The lock is taken before a connect call and
held until a verified release. Independent profiles have independent locks.

For a cold launch, explicitly include `"startIfNeeded":true` with `connect`
(and optionally an HTTP(S) `url`). Launch is attempted at most once, only if
native connect first reports `RUNNER_EXITED`, and while holding the profile
lock. No standalone launch is exposed. `stop` requires ownership but returns
`STOP_UNSUPPORTED`: the native CLI cannot gracefully stop a single browser
environment. `release` relinquishes control and keeps its browser open.

If a connect or release receipt is missing or ambiguous, do not retry or
restart: the lock stays reserved and the tool reports `RECOVERY_REQUIRED` on
later operations by that owner. Check the original receipt and coordinate with
the operator. Locks survive plugin reloads within the same DSH process, not
process restarts. Raw shell/CLI and other DSH processes do not share these locks.
Native Safarier authorization and validation remain in effect.

## Test and package

```sh
npm test
npm pack --dry-run
npm pack
```

Install only into the intended Safarier DSH profile, using the normal DSH
bundle-add workflow and the packaged tarball; for example, with that runtime's
`DSH_HOME` and launcher already selected:

```sh
dsh plugin --profile web add --save-exact /absolute/path/safarier-dsh-sfa-tool-0.1.0.tgz
```

The runtime expects the installed local launcher at `~/.local/bin/sfa` and
uses the existing local control daemon. It does not start, stop, or reset the
daemon or change profile settings. Activation and migrating existing DSH
workflow instructions away from raw shell calls are separate deployment steps.
