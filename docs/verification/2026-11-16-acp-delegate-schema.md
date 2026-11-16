# ACP delegation schema compatibility with DSH rc.2

## Failure and cause

The model rejected `acp_delegate` with `invalid_function_parameters`: the
object `{"type":"string","description":"Short task label."}` was supplied
where the schema's root `description` annotation must be a string.

The active web profile links `dsh-acp-agents` 0.4.8 to
`/Users/yingzhang/Documents/deepseek-harness/default-workspace/dsh-acp-agents-local`.
Its `lib/delegation.js` converted a complete JSON Schema into an implicit
parameter property map, then passed that map directly to `ctx.tools.register()`.
DSH 0.2.2-rc.2 registers and projects raw JSON Schema. Its `defineTool()` helper
is the separate entry point that compiles author-facing parameter maps.
The native executor therefore sent the malformed property map to the model.

## Minimal correction

In the linked plugin's `lib/delegation.js`, remove `hostParameters()` and pass
the existing `tool.inputSchema` directly as `parameters`. The MCP bridge already
uses these same schemas. No parameter is renamed, no constraint is removed,
and execution handlers are unchanged. Safarier app source and runtime image
are unchanged by this correction; rebuilding the app is unnecessary for this
external linked plugin. A plugin reinstall or link replacement can overwrite
this local fix. The linked directory has no Git metadata.

Original file backup: `.build/acp-schema-20261116/delegation.original.js`.

## Focused verification

Added `tests/delegation-schema.test.mjs` in the linked plugin. It loads Cordis,
the system prompt service, the tool registry, native executor, and Ajv from
the mounted installed DSH runtime. It registers the four delegation tools and
validates their actual projected schemas, without a model request or child task.

Before the correction, the test reproduced:
`acp_delegate: data/description must be string`.

After the correction, it passed and checked required agent/prompt fields,
string description, string/boolean option values, permission-mode enum,
timeout bounds, unknown-property rejection, result wait bounds, and cancel's
required task id. The existing test
`configured agents share one discovery/delegation catalog and preserve parent selection`
also passed. Only these two tests ran; no full regression suite ran.

Commands use the installed Node and set `DSH_SCHEMA_HOST_PACKAGE` to the
mounted `@deepseek-ai/dsh/package.json`, then run:

```sh
node --test tests/delegation-schema.test.mjs
node --test --test-name-pattern='configured agents share one discovery/delegation catalog' tests/plugin.test.mjs
```

Passing logs are saved in `.build/acp-schema-20261116/`.
Main agent reviewed the production diff: one registration expression changed,
and the obsolete conversion function removed; original CRLF was preserved.

The existing native `重启服务` action restarted DSH (66144 → 69880).
Manager 58512 and both existing browser processes 58538/58541 remained alive.
The new DSH process listens on loopback port 57899 and returns HTTP 401 to an
unauthenticated request, confirming the protected service is reachable.
This verifies schema generation and reload, not a completed authenticated model
conversation, child-agent execution, or the previously reported browser takeover.
