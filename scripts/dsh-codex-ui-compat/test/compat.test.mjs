import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { runInNewContext } from 'node:vm'
import { apply, inject, name } from '../index.js'
import { browserBootstrapScript } from '../browser-bootstrap.js'

const api = '/api/michengai/dsh-codex-ui'
function browser({
  page = 'https://dsh.example/dsh-mac/',
  base = 'https://dsh.example/dsh-mac/',
  fetchImpl,
} = {}) {
  const calls = []
  const context = {
    URL,
    Request,
    AbortController,
    Symbol,
    Reflect,
    Object,
    Set,
    String,
    globalThis: undefined,
    location: new URL(page),
    document: { baseURI: base },
    fetch: fetchImpl ?? function (...args) {
      calls.push({ receiver: this, args })
      return Promise.resolve({ ok: true })
    },
  }
  context.globalThis = context
  runInNewContext(browserBootstrapScript(), context)
  return { context, calls }
}

test('bundle metadata is a DSH bundle with a native webServer tap entry', async () => {
  const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'))
  const patch = await readFile(new URL('../cordis.patch.yml', import.meta.url), 'utf8')

  assert.equal(manifest.name, name)
  assert.equal(manifest.dsh.bundle.patch, './cordis.patch.yml')
  assert.deepEqual(inject, ['webServer'])
  assert.match(patch, /id: safarier-codex-ui-api-compat/)
  assert.match(patch, /name: safarier-dsh-codex-ui-compat/)
  assert.doesNotMatch(patch, /webServer/)
})

test('Cordis tap inserts the shim before structured DSH rows and app modules', () => {
  let transform
  let disposed = false
  apply({
    webServer: {
      tapIndex: (callback) => { transform = callback; return () => { disposed = true } },
    },
    effect: (setup) => setup(),
  })
  const withRows = '<html><head><script src="/plugins/bootstrap.js"></script><script type="module" src="/app.js"></script></head><body></body></html>'
  const tapped = transform(withRows)
  const renderedByShell = tapped.replace(/<head(?:\s[^>]*)?>/i, (opening) => `${opening}<base href="./">`)

  assert.ok(renderedByShell.indexOf('<base href="./">') < renderedByShell.indexOf('safarier.dsh-codex-ui-api-compat'))
  assert.ok(renderedByShell.indexOf('safarier.dsh-codex-ui-api-compat') < renderedByShell.indexOf('/plugins/bootstrap.js'))
  assert.ok(renderedByShell.indexOf('/plugins/bootstrap.js') < renderedByShell.indexOf('/app.js'))
  assert.doesNotMatch(browserBootstrapScript(), /<\/script/i)
  assert.equal(disposed, false)
})

test('rewrites every Codex UI 2.3.0 API request shape under allowlisted mounts', async (t) => {
  const paths = [
    '/dependencies',
    '/dependencies?action=progress',
    '/dependencies?dependency=%40michengai%2Fdsh-codex-ui',
    '/dependencies?action=update-all',
    '/settings-skin',
    '/composer',
    '/composer/models',
    '/composer/prediction',
    '/composer/prediction/stream',
    '/sidebar',
    '/sections',
    '/sections?save=1',
    '/theme',
    '/desktop-menu?action=status',
    '/desktop-menu?action=restart',
  ]
  for (const mount of ['/dsh-mac/', '/dsh/', '/dsh-ubuntu/']) {
    await t.test(mount, async () => {
      const { context, calls } = browser({ page: `https://dsh.example${mount}`, base: `https://dsh.example${mount}` })
      for (const path of paths) {
        await context.fetch(`${api}${path}`)
        assert.equal(calls.at(-1).args[0], `https://dsh.example${mount}api/michengai/dsh-codex-ui${path}`)
      }
    })
  }
})

test('rewrites only canonical dsh-provider-proxy 1.3.0 paths and preserves queries', async (t) => {
  const paths = [
    '/dsh-provider-proxy/providers',
    '/dsh-provider-proxy/test',
    '/dsh-provider-proxy/reset-hits',
    '/dsh-provider-proxy/providers?model=example%2Fmodel&enabled=1',
    '/dsh-provider-proxy/test?probe=1',
    '/dsh-provider-proxy/reset-hits?scope=local',
  ]
  for (const mount of ['/dsh-mac/', '/dsh/', '/dsh-ubuntu/']) {
    await t.test(mount, async () => {
      const { context, calls } = browser({ page: `https://dsh.example${mount}`, base: `https://dsh.example${mount}` })
      for (const path of paths) {
        await context.fetch(path)
        assert.equal(calls.at(-1).args[0], `https://dsh.example${mount}${path.slice(1)}`)
      }
    })
  }
})

test('provider-proxy exact paths preserve POST init identity, values, receiver, and argument arity', async () => {
  const { context, calls } = browser()
  const headers = new Map([['content-type', 'application/json'], ['x-test', 'kept']])
  const init = { method: 'POST', headers, body: '{"provider":"kept"}', cache: 'no-store' }
  const receiver = { marker: true }

  await Reflect.apply(context.fetch, receiver, ['/dsh-provider-proxy/test?probe=1', init, 'extra-argument'])
  const [stringInput, stringInit] = calls.at(-1).args
  assert.equal(calls.at(-1).receiver, receiver)
  assert.equal(stringInput, 'https://dsh.example/dsh-mac/dsh-provider-proxy/test?probe=1')
  assert.equal(stringInit, init)
  assert.equal(calls.at(-1).args.length, 3)
  assert.equal(stringInit.method, 'POST')
  assert.equal(stringInit.headers, headers)
  assert.equal(stringInit.body, '{"provider":"kept"}')
})

test('preserves POST init identity, values, receiver, and argument arity', async () => {
  const { context, calls } = browser()
  const controller = new AbortController()
  const headers = new Map([['content-type', 'application/json'], ['x-test', 'kept']])
  const init = { method: 'POST', headers, body: '{"draft":"kept"}', cache: 'no-store', credentials: 'same-origin', signal: controller.signal }
  const receiver = { marker: true }

  await Reflect.apply(context.fetch, receiver, [`${api}/sections?save=1`, init, 'extra-argument'])
  const [stringInput, stringInit] = calls.at(-1).args
  assert.equal(calls.at(-1).receiver, receiver)
  assert.equal(stringInput, `https://dsh.example/dsh-mac${api}/sections?save=1`)
  assert.equal(stringInit, init)
  assert.equal(calls.at(-1).args.length, 3)
  assert.equal(stringInit.method, 'POST')
  assert.equal(stringInit.headers, headers)
  assert.equal(stringInit.body, '{"draft":"kept"}')
  assert.equal(stringInit.credentials, 'same-origin')
  assert.equal(stringInit.signal, controller.signal)

  await context.fetch(`${api}/composer`)
  assert.equal(calls.at(-1).args.length, 1)
})

test('rewrites only root-absolute same-origin requests in the exact API namespace', async () => {
  const { context, calls } = browser()
  const unchanged = [
    'https://elsewhere.example/api/michengai/dsh-codex-ui/theme',
    '//dsh.example/api/michengai/dsh-codex-ui/theme',
    '/api/michengai/dsh-codex-ui-evil/theme',
    '/api/michengai/dsh-codex-ui-other/theme',
    '/dsh-mac/api/michengai/dsh-codex-ui/theme',
    '/elsewhere/api/michengai/dsh-codex-ui/theme',
    '/api/michengai/other/theme',
  ]

  for (const input of unchanged) {
    await context.fetch(input)
    assert.equal(calls.at(-1).args[0], input)
  }

  await context.fetch(`${api}`)
  assert.equal(calls.at(-1).args[0], `https://dsh.example/dsh-mac${api}`)
})

test('provider-proxy allowlist rejects non-canonical paths and neighboring namespaces', async () => {
  const { context, calls } = browser()
  const unchanged = [
    '/dsh-provider-proxy/providers/',
    '/dsh-provider-proxy/providers/child',
    '/dsh-provider-proxy/provider',
    '/dsh-provider-proxy/Providers',
    '/dsh-provider-proxy/%74est',
    '/dsh-provider-proxy/reset-hits-extra',
    '/dsh-provider-proxy-evil/providers',
  ]

  for (const input of unchanged) {
    await context.fetch(input)
    assert.equal(calls.at(-1).args[0], input)
  }
})

test('provider-proxy rewrites retain the existing deployment, mount, and origin guards', async (t) => {
  const input = '/dsh-provider-proxy/providers?mode=check'
  const cases = [
    { page: 'https://dsh.example/', base: 'https://dsh.example/' },
    { page: 'https://dsh.example/other/', base: 'https://dsh.example/other/' },
    { page: 'https://dsh.example/dsh-mac/', base: 'https://evil.example/dsh-mac/' },
    { page: 'https://elsewhere.example/dsh-mac/', base: 'https://dsh.example/dsh-mac/' },
  ]

  for (const item of cases) {
    await t.test(item.base, async () => {
      const { context, calls } = browser(item)
      await context.fetch(input)
      assert.equal(calls.at(-1).args[0], input)
    })
  }
})

test('preserves root deployment and ignores non-allowlisted or cross-origin base URLs', async (t) => {
  const cases = [
    { page: 'https://dsh.example/', base: 'https://dsh.example/', input: `${api}/theme` },
    { page: 'https://dsh.example/other/', base: 'https://dsh.example/other/', input: `${api}/theme` },
    { page: 'https://dsh.example/dsh-mac/', base: 'https://evil.example/dsh-mac/', input: `${api}/theme` },
  ]

  for (const item of cases) {
    await t.test(item.base, async () => {
      const { context, calls } = browser(item)
      await context.fetch(item.input)
      assert.equal(calls.at(-1).args[0], item.input)
    })
  }
})

test('leaves Request/URL objects and unrelated fetch options untouched and installs idempotently', async () => {
  const { context, calls } = browser()
  const original = context.fetch
  const other = new URL(`https://dsh.example${api}/theme`)
  const init = { method: 'GET', cache: 'no-store' }

  await context.fetch(other, init)
  assert.equal(calls.at(-1).args[0], other)
  assert.equal(calls.at(-1).args[1], init)
  assert.equal(calls.at(-1).args.length, 2)

  const request = new Request(`https://dsh.example${api}/theme`)
  await context.fetch(request, init)
  assert.equal(calls.at(-1).args[0], request)
  assert.equal(calls.at(-1).args[1], init)

  runInNewContext(browserBootstrapScript(), context)
  assert.equal(context.fetch, original)
})

test('does not catch or retry errors from the original fetch', () => {
  const failure = new Error('native fetch failure')
  let attempts = 0
  const { context } = browser({
    fetchImpl() {
      attempts += 1
      throw failure
    },
  })

  assert.throws(() => context.fetch(`${api}/theme`), (error) => error === failure)
  assert.equal(attempts, 1)
})
