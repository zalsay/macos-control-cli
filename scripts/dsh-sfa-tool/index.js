import { execFile } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'safarier-dsh-sfa-tool'
export const inject = ['tools']

const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i
const uuid = v => typeof v === 'string' && UUID.test(v)
const fail = (error) => ({ status: 'error', error })
const uncertain = () => fail('INDETERMINATE_RESULT')
const connectRejected = new Set([
  'RUNNER_EXITED', 'PROFILE_ALREADY_RUNNING', 'PROFILE_NOT_ALLOWED', 'SESSION_BUSY',
  'UNAUTHORIZED', 'INVALID_REQUEST', 'BACKGROUND_LAUNCH_UNVERIFIED', 'REPLAY_WINDOW_FULL',
])

// Shared by registrations in the same DSH process, including plugin reloads.
const lockKey = Symbol.for('safarier.dsh.sfa-tool.profile-lock.v1')
const processLocks = (globalThis[lockKey] ??= new Map())
const operations = {
  connect: ['startIfNeeded', 'url'], release: [], stop: [], state: [], observe: [],
  navigate: ['url'], 'click-target': ['target'], click: ['frame', 'x', 'y'],
  press: ['frame', 'key'], type: ['frame', 'text'],
}

function validURL(raw) {
  try {
    if (typeof raw !== 'string' || raw.length > 4096) return false
    const url = new URL(raw)
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password
  } catch { return false }
}

function validArgs(args) {
  if (!args || !uuid(args.profile) || !Object.hasOwn(operations, args.operation)) return false
  const { operation, startIfNeeded, url, frame, target, x, y, key, text } = args
  const fields = ['profile', 'operation', ...operations[operation]]
  if (Object.keys(args).some(k => !fields.includes(k))) return false
  if (operation === 'connect') return (startIfNeeded === undefined || typeof startIfNeeded === 'boolean') &&
    (url === undefined || (startIfNeeded === true && validURL(url)))
  if (operation === 'navigate') return validURL(url)
  if (operation === 'click-target') return typeof target === 'string' && !!target.trim() && target.length <= 512 && !target.startsWith('--') && !/\p{Cc}/u.test(target)
  if (operation === 'click') return uuid(frame) && [x, y].every(v => Number.isFinite(v) && v >= 0)
  if (operation === 'press') return uuid(frame) && typeof key === 'string' &&
    /^(Backspace|Delete|Enter|Tab|Escape|Left|Right|Up|Down|Home|End|PageUp|PageDown)$/.test(key)
  if (operation === 'type') return uuid(frame) && typeof text === 'string' && !!text && Buffer.byteLength(text) <= 16384
  return true
}

function nativeCLI(argv, { signal, stdin } = {}) {
  const bin = join(homedir(), '.local', 'bin', 'sfa')
  return new Promise(resolve => {
    let result = { code: null, stdout: '' }
    const child = execFile(bin, argv, { signal, timeout: 90000, maxBuffer: 2 ** 21 }, (error, stdout) => {
      if (!error) result = { code: 0, stdout }
      else if (Number.isInteger(error.code) && !error.killed) result = { code: error.code, stdout }
    })
    // The callback may fire on abort before the subprocess exits. Do not
    // relinquish the in-flight slot while the child still owns its pipes.
    child.once('close', () => resolve(result))
    child.stdin?.on('error', () => {})
    child.stdin?.end(stdin)
  })
}

function controlReply({ code, stdout } = {}) {
  try {
    const r = JSON.parse(stdout)
    if (r.version !== 1 || !uuid(r.requestID)) return uncertain()
    if (code === 0 && r.status === 'ok' && r.error === undefined) return r
    if (code === 1 && r.status === 'error' && typeof r.error === 'string' && /^[A-Z_]+$/.test(r.error)) return r
  } catch { /* A missing or truncated reply is not proof of refusal. */ }
  return uncertain()
}

function releaseConfirmed(r, profile) {
  const receipt = r.controlReleased
  return r.status === 'ok' && receipt?.target?.profileID?.toLowerCase?.() === profile &&
    ['inputReleased', 'artifactsCleaned', 'browserRetained', 'manualInteractionEnabled'].every(k => receipt[k] === true)
}

function operationArgs(args, connection) {
  const { operation: op, url, target, frame, x, y, key } = args
  const argv = ['control', op, '--connection', connection]
  if (op === 'navigate') argv.push('--url', url)
  if (op === 'click-target') argv.push('--target', target)
  if (['click', 'press', 'type'].includes(op)) argv.push('--frame', frame)
  if (op === 'click') argv.push('--x', String(x), '--y', String(y))
  if (op === 'press') argv.push('--key', key)
  if (op === 'type') argv.push('--text-stdin')
  return argv
}

export function createSfaTool({ run = nativeCLI, locks = processLocks } = {}) {
  async function invoke(argv, options) {
    try { return await run(argv, options) } catch { return { code: null, stdout: '' } }
  }
  return {
    name: 'sfa',
    description: 'Control Safarier through a DSH-session-owned connection. Use this tool instead of Bash sfa. Connect before operations, release when done. Cold-start only with connect and explicit startIfNeeded. Release preserves the browser; native browser stop is unavailable.',
    parameters: {
      operation: { type: 'string', enum: Object.keys(operations), required: true },
      profile: { type: 'string', required: true, description: 'Safarier profile UUID (not a name)' },
      startIfNeeded: { type: 'boolean', description: 'Explicitly allow connect to cold-launch a stopped browser' },
      url: { type: 'string' }, target: { type: 'string' }, frame: { type: 'string' },
      x: { type: 'number' }, y: { type: 'number' }, key: { type: 'string' }, text: { type: 'string' },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }],
    },
    async execute(args, exec) {
      const owner = exec?.agent?.session?.id
      const signal = exec?.signal
      if (typeof owner !== 'string' || !owner) return fail('DSH_SESSION_REQUIRED')
      if (!validArgs(args)) return fail('INVALID_REQUEST')
      if (signal?.aborted) return fail('CANCELLED')
      const { operation: op } = args
      const profile = args.profile.toLowerCase()
      let entry = locks.get(profile)
      if (entry && (entry.owner !== owner || entry.inFlight)) return fail('SESSION_BUSY')
      if (entry?.uncertain) return fail('RECOVERY_REQUIRED')
      if (op === 'connect') {
        if (entry?.connection) return { ...entry.reply, reused: true }
        // Synchronous reservation before the first await prevents two callers
        // (including simultaneous cold starts) from reaching the same profile.
        entry = { owner, inFlight: true }
        locks.set(profile, entry)
        const connect = async () => controlReply(await invoke(['control', 'connect', '--profile', profile], { signal }))
        try {
          let reply = await connect()
          if (reply.error === 'RUNNER_EXITED' && args.startIfNeeded === true && !signal?.aborted) {
            const launch = ['launch', profile]
            if (args.url !== undefined) launch.push('--url', args.url)
            // Native launch has its own profile-running guard. Exit 0 means its
            // registration was requested, not that control has been acquired.
            if ((await invoke(launch, { signal })).code !== 0 || signal?.aborted) {
              entry.uncertain = true
              return uncertain()
            }
            reply = await connect()
          }
          if (reply.status === 'ok' && uuid(reply.connection)) {
            entry.connection = reply.connection
            entry.reply = reply
            return reply
          }
          if (connectRejected.has(reply.error)) {
            locks.delete(profile)
            return reply
          }
          entry.uncertain = true
          return uncertain()
        } finally { entry.inFlight = false }
      }
      if (!entry?.connection) return fail('CONNECT_REQUIRED')
      if (op === 'stop') return fail('STOP_UNSUPPORTED')
      entry.inFlight = true
      try {
        const reply = controlReply(await invoke(operationArgs(args, entry.connection), { signal, stdin: args.text }))
        if (op === 'release') {
          if (releaseConfirmed(reply, profile)) locks.delete(profile)
          // Only native, explicitly retryable no-effect rejections are safe
          // to leave in the ordinary active state after an attempted release.
          else if (!['SESSION_BUSY', 'INVALID_POINTER_STATE'].includes(reply.error)) {
            entry.uncertain = true
            return reply.status === 'ok' ? fail('CLEANUP_UNCONFIRMED') : reply
          }
        } else if (['SESSION_NOT_FOUND', 'SESSION_EXPIRED'].includes(reply.error)) {
          entry.uncertain = true
        }
        return reply
      } finally { entry.inFlight = false }
    },
  }
}

export function apply(ctx) {
  ctx.effect(() => ctx.tools.register(createSfaTool()))
}
