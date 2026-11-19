# Safarier DSH Codex UI API compatibility

This standalone DSH bundle fixes Codex UI 2.3.0's root-absolute API requests
when Safarier serves DSH beneath `/dsh-mac/`, `/dsh/`, or `/dsh-ubuntu/` and
the upstream proxy strips that prefix. It also adapts the three canonical
`dsh-provider-proxy` 1.3.0 endpoints (`/providers`, `/test`, and `/reset-hits`)
when requested at the origin root under those mounts. It uses DSH's native
`webServer.tapIndex` to place a small classic script at the start of the page
head. DSH adds its relative `<base href="./">` after index taps, so the base
remains first and the shim precedes structured boot rows and client scripts.
It does not modify Codex UI, rewrite gateway routes, or touch any other URL
namespace.

The adapter changes only root-absolute string requests whose same-origin path
is exactly `/api/michengai/dsh-codex-ui` or a child path, or whose pathname is
exactly one of `/dsh-provider-proxy/providers`, `/dsh-provider-proxy/test`, or
`/dsh-provider-proxy/reset-hits`; all rewrites require the document's
same-origin base URL to identify one of the three allowlisted mounts.
It leaves the root deployment, other paths, already-mounted paths,
cross-origin requests, `Request`/`URL` objects, query strings, request bodies,
and fetch options alone. Those other input forms are not used by the affected
Codex UI 2.3.0 root-absolute call sites.

## Test and package

From this directory:

```sh
npm test
npm pack --dry-run
npm pack
```

## Install and activate

Use the DSH CLI's normal bundle-add path for the intended profile, supplying
the produced tarball path:

```sh
dsh plugin --profile web add --save-exact /absolute/path/safarier-dsh-codex-ui-compat-1.1.0.tgz
```

The CLI selects newly added DSH bundles automatically. This adds one profile
dependency and one selected bundle; it does not merge or replace other profile
settings. Review the CLI result and its exact profile before restarting DSH.
Install and restart are separate actions. Without a runtime HMR mechanism, a
normal DSH restart is required to load the bundle; do that only when authorized.

To remove it later, deselect/remove `safarier-dsh-codex-ui-compat` with the DSH
plugin manager/CLI for that same profile. No Codex UI files or global proxy
configuration need to be edited or restored.
