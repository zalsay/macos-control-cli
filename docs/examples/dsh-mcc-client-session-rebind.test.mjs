import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { MccClient } from './mcc-client.js';

const TOKEN = 'a'.repeat(64);
const CA = 'synthetic test CA';

class FakeWebSocket extends EventEmitter {
  constructor(url, protocols, options, scenario) {
    super();
    this.url = url;
    this.protocols = protocols;
    this.options = options;
    this.protocol = 'mcc.remote.v1';
    this.readyState = 0;
    this.sent = [];
    this.scenario = scenario;
    this.index = scenario.sockets.length;
    scenario.sockets.push(this);
    queueMicrotask(() => {
      if (scenario.authStatusCode) {
        this.emit('unexpected-response', {}, { statusCode: scenario.authStatusCode });
        return;
      }
      this.readyState = 1;
      this.emit('open');
      queueMicrotask(() => this.message({
        remoteProtocol: 1,
        version: 'test-host',
        scope: scenario.scope ?? 'chrome',
        bootId: scenario.bootId ?? 'boot-new',
        capabilities: [],
      }));
    });
  }

  message(value) {
    this.emit('message', Buffer.from(JSON.stringify(value)), false);
  }

  send(raw, callback) {
    const value = JSON.parse(raw);
    this.sent.push(value);
    callback?.(null);
    queueMicrotask(() => {
      if (value.type === 'session') {
        if (this.scenario.closeCachedSession && value.session) {
          this.scenario.closeCachedSession = false;
          this.readyState = 3;
          this.emit('close', 1006, Buffer.alloc(0));
          return;
        }
        const reply = this.scenario.sessionReply?.(value, this)
          ?? {
            type: 'session',
            session: this.scenario.session ?? 'session-new',
            bootId: this.scenario.bootId ?? 'boot-new',
            state: this.scenario.state ?? 'ready',
          };
        this.message(reply);
        return;
      }
      if (value.type === 'ack') {
        this.message({ type: 'acked', id: value.id, sequence: value.sequence });
        return;
      }
      this.scenario.rpcRequests.push(value);
      if (this.scenario.disconnectAfterRpc) {
        this.readyState = 3;
        this.emit('close', 1006, Buffer.alloc(0));
        return;
      }
      this.message({
        type: 'result',
        id: value.id,
        sequence: value.sequence,
        response: {
          protocolVersion: 1,
          ok: true,
          scope: value.scope,
          ...(value.request.action === 'connect' ? { connectionId: 'new-control-connection' } : {}),
          ...(value.request.action === 'windows' ? { windows: [] } : { running: true }),
        },
        image: null,
      });
    });
  }

  close() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    queueMicrotask(() => this.emit('close', 1000, Buffer.alloc(0)));
  }

  terminate() {
    this.readyState = 3;
    this.emit('close', 1006, Buffer.alloc(0));
  }
}

function createScenario(overrides = {}) {
  return {
    sockets: [],
    rpcRequests: [],
    ...overrides,
  };
}

function fakeWebSocketFor(scenario) {
  return class extends FakeWebSocket {
    constructor(url, protocols, options) {
      super(url, protocols, options, scenario);
    }
  };
}

async function fixture(scenario) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'mcc-client-test-'));
  const stateDir = path.join(root, 'state');
  await mkdir(stateDir, { recursive: true });
  const caCert = path.join(root, 'ca.pem');
  const tokenFile = path.join(root, 'token');
  await writeFile(caCert, CA);
  await writeFile(tokenFile, TOKEN);
  const client = new MccClient({
    url: 'wss://mcc.test',
    scope: 'chrome',
    stateDir,
    caCert,
    tokenFile,
    servername: 'mcc.test',
  }, { WebSocketImpl: fakeWebSocketFor(scenario) });
  return {
    client,
    stateDir,
    async setCache(value) {
      await writeFile(path.join(stateDir, 'session.json'), JSON.stringify(value));
    },
    async getCache() {
      return JSON.parse(await readFile(path.join(stateDir, 'session.json'), 'utf8'));
    },
    async cleanup() {
      await rm(root, { recursive: true, force: true });
    },
  };
}

test('stale boot accepts Host-issued session and starts its sequence at one', async (t) => {
  const scenario = createScenario({
    bootId: 'boot-current',
    session: 'session-current',
  });
  const f = await fixture(scenario);
  t.after(f.cleanup);
  await f.setCache({ session: 'session-old', bootId: 'boot-old', sequence: 23 });

  const result = await f.client.run({ action: 'status' });

  assert.equal(result.response.running, true);
  assert.equal(scenario.sockets.length, 1);
  assert.deepEqual(scenario.rpcRequests.map((r) => [r.session, r.sequence]), [['session-current', 1]]);
  assert.deepEqual(await f.getCache(), { session: 'session-current', bootId: 'boot-current', sequence: 1, requiresAttach: true });
});

test('legacy unknown cached session gets one empty-session handshake; status/windows then continue', async (t) => {
  const scenario = createScenario({ closeCachedSession: true, bootId: 'boot-current' });
  const f = await fixture(scenario);
  t.after(f.cleanup);
  await f.setCache({ session: 'expired-session', bootId: 'boot-old', sequence: 8 });

  await f.client.run({ action: 'status' });
  await f.client.run({ action: 'windows' });

  assert.equal(scenario.sockets.length, 3);
  assert.deepEqual(scenario.sockets[0].sent.map((m) => m.type), ['session']);
  assert.equal(scenario.sockets[1].sent[0].type, 'session');
  assert.equal(scenario.sockets[1].sent[0].session, null);
  assert.equal(scenario.sockets[1].sent[0].bootId, null);
  assert.equal(scenario.sockets[2].sent[0].session, 'session-new');
  assert.deepEqual(scenario.rpcRequests.map((r) => [r.request.action, r.sequence]), [['status', 1], ['windows', 2]]);
  assert.equal(scenario.sockets[0].options.rejectUnauthorized, true);
  assert.equal(scenario.sockets[0].options.ca, CA);
  assert.equal(scenario.sockets[0].options.servername, 'mcc.test');
  assert.equal(scenario.sockets[0].options.headers.Authorization, `Bearer ${TOKEN}`);
  assert.deepEqual(scenario.sockets[0].protocols, ['mcc.remote.v1']);
});

test('authentication failure is not retried as a stale session', async (t) => {
  const scenario = createScenario({ authStatusCode: 401 });
  const f = await fixture(scenario);
  t.after(f.cleanup);

  await assert.rejects(f.client.run({ action: 'status' }), (err) => err.code === 'CONNECT_REJECTED');

  assert.equal(scenario.sockets.length, 1);
  assert.equal(scenario.sockets[0].sent.length, 0);
});

test('RPC disconnect is never replayed after the request was sent', async (t) => {
  const scenario = createScenario({ disconnectAfterRpc: true, bootId: 'boot-current', session: 'session-current' });
  const f = await fixture(scenario);
  t.after(f.cleanup);
  await f.setCache({ session: 'session-current', bootId: 'boot-current', sequence: 0 });

  await assert.rejects(f.client.run({ action: 'connect', windowId: 'w' }), (err) => err.code === 'WS_CLOSED');

  assert.equal(scenario.sockets.length, 1);
  assert.equal(scenario.rpcRequests.length, 1);
});

test('same session and boot keep sequence monotonic', async (t) => {
  const scenario = createScenario({ bootId: 'boot-stable', session: 'session-stable' });
  const f = await fixture(scenario);
  t.after(f.cleanup);

  await f.client.run({ action: 'status' });
  await f.client.run({ action: 'windows' });

  assert.deepEqual(scenario.rpcRequests.map((r) => [r.session, r.sequence]), [
    ['session-stable', 1],
    ['session-stable', 2],
  ]);
});

test('paused Host gate blocks writes and does not clear the pause state', async (t) => {
  const scenario = createScenario({ state: 'paused', bootId: 'boot-paused', session: 'session-paused' });
  const f = await fixture(scenario);
  t.after(f.cleanup);

  await assert.rejects(f.client.run({ action: 'click', connectionId: 'c', frameId: 'f', x: 1, y: 1 }), (err) => err.code === 'USER_PAUSED');
  await f.client.run({ action: 'status' });

  assert.deepEqual(scenario.rpcRequests.map((r) => [r.request.action, r.sequence]), [['status', 1]]);
  assert.deepEqual(await f.getCache(), { session: 'session-paused', bootId: 'boot-paused', sequence: 1 });
});

test('new session refuses old control connection ids and does not reuse them', async (t) => {
  const scenario = createScenario({ bootId: 'boot-new', session: 'session-new' });
  const f = await fixture(scenario);
  t.after(f.cleanup);
  await f.setCache({ session: 'session-old', bootId: 'boot-old', sequence: 17 });

  await assert.rejects(
    f.client.run({ action: 'observe', connectionId: 'old-control-connection' }),
    (err) => err.code === 'SESSION_REBOUND' && /本次命令未发送/.test(err.message),
  );
  assert.deepEqual(await f.getCache(), { session: 'session-new', bootId: 'boot-new', sequence: 0, requiresAttach: true });

  await assert.rejects(
    f.client.run({ action: 'observe', connectionId: 'old-control-connection' }),
    (err) => err.code === 'SESSION_REBOUND',
  );

  await f.client.run({ action: 'windows' });

  assert.equal(scenario.rpcRequests.some((r) => r.request.connectionId === 'old-control-connection'), false);
  const attached = await f.client.run({ action: 'connect', windowId: 'w' });
  assert.equal(attached.response.connectionId, 'new-control-connection');
  assert.deepEqual(scenario.rpcRequests.map((r) => [r.request.action, r.sequence]), [['windows', 1], ['connect', 2]]);
  assert.equal((await f.getCache()).requiresAttach, false);
});
