import assert from 'node:assert/strict'
import test from 'node:test'
import { apply, createSfaTool, inject } from './index.js'

const profile = '01234567-89ab-cdef-0123-456789abcdef'
const other = '11234567-89ab-cdef-0123-456789abcdef'
const requestID = '21234567-89ab-cdef-0123-456789abcdef'
const connection = '31234567-89ab-cdef-0123-456789abcdef'
const json = (extra = {}, status = 'ok') => ({
  code: status === 'ok' ? 0 : 1,
  stdout: JSON.stringify({ version: 1, requestID, status, ...extra }),
})
const err = error => json({ error }, 'error')
const ok = () => json({ connection })
const released = (extra = {}) => json({
  controlReleased: {
    target: { profileID: profile.toUpperCase() },
    inputReleased: true, artifactsCleaned: true, browserRetained: true, manualInteractionEnabled: true,
    ...extra,
  },
})

function fixture(run) {
  const calls = []
  const tool = createSfaTool({ locks: new Map(), run: (argv, opt) => {
    calls.push([argv, opt.stdin]); return run(argv, calls.length, opt)
  } })
  return { calls, call(operation, owner = 'A', props = {}) {
    return tool.execute({ operation, profile, ...props }, { agent: { session: { id: owner } } })
  } }
}

test('same profile is reserved before await; other profiles remain independent', async () => {
  let complete
  const { calls, call } = fixture((argv) => argv.at(-1) === profile ? new Promise(r => { complete = r }) : ok())
  const first = call('connect')
  assert.equal((await call('connect', 'B', { profile: profile.toUpperCase() })).error, 'SESSION_BUSY')
  assert.equal((await call('connect')).error, 'SESSION_BUSY')
  assert.equal((await call('connect', 'B', { profile: other })).status, 'ok')
  complete(ok())
  assert.equal((await first).connection, connection)
  assert.equal((await call('connect')).reused, true)
  assert.equal((await call('state', 'B')).error, 'SESSION_BUSY')
  assert.equal(calls.length, 2)
})

test('only the owner can operate or release; verified release frees the profile', async () => {
  const { calls, call } = fixture(argv => argv[1] === 'release' ? released() : ok())
  assert.equal((await call('stop')).error, 'CONNECT_REQUIRED')
  assert.equal((await call('navigate', 'A', { url: 'https://example.com' })).error, 'CONNECT_REQUIRED')
  await call('connect')
  assert.equal((await call('stop', 'B')).error, 'SESSION_BUSY')
  assert.equal((await call('stop')).error, 'STOP_UNSUPPORTED')
  assert.equal((await call('release', 'B')).error, 'SESSION_BUSY')
  await call('type', 'A', { frame: requestID, text: 'hello --not-a-flag' })
  assert.deepEqual(calls[1], [['control', 'type', '--connection', connection, '--frame', requestID, '--text-stdin'], 'hello --not-a-flag'])
  assert.equal((await call('release')).status, 'ok')
  assert.equal((await call('connect', 'B')).status, 'ok')
  assert.equal(calls.length, 4)
})

test('unknown connect outcome is quarantined and never retries or launches', async () => {
  const { calls, call } = fixture(() => ({ code: null, stdout: '' }))
  assert.equal((await call('connect', 'A', { startIfNeeded: true })).error, 'INDETERMINATE_RESULT')
  assert.equal((await call('connect')).error, 'RECOVERY_REQUIRED')
  assert.equal((await call('connect', 'B')).error, 'SESSION_BUSY')
  assert.equal(calls.length, 1)
})

test('only explicit cold connect launches and reserves through launch', async () => {
  let acknowledgeLaunch
  const { calls, call } = fixture((argv, n) => n < 3 ? err('RUNNER_EXITED') :
    argv[0] === 'launch' ? new Promise(resolve => { acknowledgeLaunch = resolve }) : ok())
  assert.equal((await call('connect')).error, 'RUNNER_EXITED')
  const launching = call('connect', 'B', { startIfNeeded: true, url: 'https://example.com/' })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal((await call('connect')).error, 'SESSION_BUSY')
  assert.equal((await call('stop', 'B')).error, 'SESSION_BUSY')
  assert.deepEqual(calls[2][0], ['launch', profile, '--url', 'https://example.com/'])
  acknowledgeLaunch({ code: 0, stdout: '已请求 Manager 启动' })
  assert.equal((await launching).status, 'ok')
  assert.deepEqual(calls.map(([argv]) => argv[0]), ['control', 'control', 'launch', 'control'])
})

test('already-running refusal never triggers launch', async () => {
  const { calls, call } = fixture(() => err('PROFILE_ALREADY_RUNNING'))
  assert.equal((await call('connect', 'A', { startIfNeeded: true })).error, 'PROFILE_ALREADY_RUNNING')
  assert.equal(calls.length, 1)
})

test('unknown launch outcome is quarantined without subsequent connect', async () => {
  const { calls, call } = fixture((_argv, n) => n === 1 ? err('RUNNER_EXITED') : { code: 1, stdout: '' })
  assert.equal((await call('connect', 'A', { startIfNeeded: true })).error, 'INDETERMINATE_RESULT')
  assert.equal((await call('connect')).error, 'RECOVERY_REQUIRED')
  assert.equal(calls.length, 2)
})

test('release never unlocks based on a missing session or wrong receipt target', async () => {
  for (const bad of [released({ target: { profileID: other } }), err('SESSION_NOT_FOUND'), err('TIMEOUT')]) {
    const { calls, call } = fixture((_argv, n) => n === 1 ? ok() : bad)
    await call('connect')
    assert.equal((await call('release')).status, 'error')
    assert.equal((await call('connect')).error, 'RECOVERY_REQUIRED')
    assert.equal((await call('connect', 'B')).error, 'SESSION_BUSY')
    assert.equal(calls.length, 2)
  }
})

test('an in-flight browser action excludes release even for the owner', async () => {
  let finish
  const { calls, call } = fixture((_argv, n) => n === 1 ? ok() : new Promise(resolve => { finish = resolve }))
  await call('connect')
  const observing = call('observe')
  assert.equal((await call('release')).error, 'SESSION_BUSY')
  assert.equal((await call('observe', 'B')).error, 'SESSION_BUSY')
  assert.equal(calls.length, 2)
  finish(json())
  assert.equal((await observing).status, 'ok')
})

test('separate tool registrations share existing owners in one process', async () => {
  const one = createSfaTool({ run: argv => argv[1] === 'release' ? released() : ok() })
  const two = createSfaTool({ run: () => assert.fail('must not invoke the CLI or expose the connection') })
  const exec = id => ({ agent: { session: { id } } })
  const args = { operation: 'connect', profile }
  assert.equal((await one.execute(args, exec('one'))).status, 'ok')
  assert.equal((await two.execute(args, exec('two'))).error, 'SESSION_BUSY')
  assert.equal((await one.execute({ ...args, operation: 'release' }, exec('one'))).status, 'ok')
})

test('registration requires trusted caller and forbids injecting owner or argv', async () => {
  let registered
  apply({ effect: cb => cb(), tools: { register: tool => { registered = tool } } })
  assert.deepEqual(inject, ['tools'])
  assert.equal(registered.name, 'sfa')
  assert.equal((await registered.execute({ operation: 'connect', profile }, {})).error, 'DSH_SESSION_REQUIRED')
  const { calls, call } = fixture(() => ok())
  assert.equal((await call('connect', 'A', { owner: 'B' })).error, 'INVALID_REQUEST')
  assert.equal((await call('launch')).error, 'INVALID_REQUEST')
  assert.equal(calls.length, 0)
})
