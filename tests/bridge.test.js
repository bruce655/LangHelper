'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

test('bridge catalog, strict selection, metadata and cancellation', { timeout: 10000 }, async () => {
  const base = await fsp.mkdtemp(path.join(os.tmpdir(), 'langhelper-bridge-test-'));
  const subscriptions = [];
  const standbySubscriptions = [];
  let calls = 0;
  let pendingSelection;
  let selectionStarted;
  let cancellationObserved;
  const logs = [];
  class CancellationTokenSource {
    constructor() { this.token = { isCancellationRequested: false }; }
    cancel() {
      this.token.isCancellationRequested = true;
      if (cancellationObserved) cancellationObserved();
    }
    dispose() {}
  }
  const model = {
    id: 'copilot-sonnet-55', family: 'claude-sonnet-5.5', name: 'Claude Sonnet 5.5', vendor: 'copilot',
    async sendRequest(messages, options, token) {
      calls++;
      return { text: (async function* () {
        if (messages[0].content === 'slow') {
          while (!token.isCancellationRequested) await new Promise((r) => setTimeout(r, 10));
          throw new Error('Cancelled');
        }
        yield 'Translated';
      })() };
    },
  };
  const vscode = {
    lm: { selectChatModels: async () => {
      if (pendingSelection) {
        selectionStarted();
        return pendingSelection;
      }
      return [model];
    } }, CancellationTokenSource,
    LanguageModelError: class extends Error {},
    LanguageModelChatMessage: { User: (content) => ({ content }), Assistant: (content) => ({ content }) },
    workspace: { getConfiguration: () => ({ get: () => 'claude-sonnet-5.5' }) },
    window: { createOutputChannel: () => ({ appendLine(line) { logs.push(line); }, dispose() {} }) },
    commands: { registerCommand: () => ({ dispose() {} }) },
  };
  const sandbox = {
    require: (name) => name === 'vscode' ? vscode : require(name),
    process: { env: { LOCALAPPDATA: base }, pid: process.pid, kill: process.kill.bind(process) },
    module: { exports: {} }, setTimeout, clearTimeout, setInterval, clearInterval,
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '..', 'vscode-extension', 'extension.js'), 'utf8'), sandbox);
  const root = path.join(base, 'LangHelper', 'bridge');
  async function request(id, body) {
    const temp = path.join(root, 'requests', `${id}.tmp`);
    await fsp.writeFile(temp, JSON.stringify({ id, ...body }));
    await fsp.rename(temp, path.join(root, 'requests', `${id}.json`));
  }
  async function response(id) {
    const file = path.join(root, 'responses', `${id}.json`);
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      try { return JSON.parse(await fsp.readFile(file, 'utf8')); }
      catch (err) { if (err.code !== 'ENOENT') throw err; }
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`No response for ${id}`);
  }
  try {
    await sandbox.module.exports.activate({ subscriptions });
    const standby = { ...sandbox, module: { exports: {} } };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '..', 'vscode-extension', 'extension.js'), 'utf8'), standby);
    await standby.module.exports.activate({ subscriptions: standbySubscriptions });
    async function queuedRequest(id, body, ageMs = 0) {
      const name = `${id}.pending`;
      const file = path.join(root, 'requests', name);
      await fsp.writeFile(file, JSON.stringify({ id, ...body }));
      const at = new Date(Date.now() - ageMs);
      await fsp.utimes(file, at, at);
      await sandbox.handleRequestFile(name);
      assert.equal(fs.existsSync(file), false, 'handled queued request must be consumed');
    }
    const message = { model: model.id, messages: [{ content: 'hello' }] };
    await queuedRequest('stale', message, 301000);
    await queuedRequest('expired', { ...message, expiresAt: new Date(Date.now() - 1000).toISOString() });
    await queuedRequest('stale-catalog', { action: 'models' }, 301000);
    assert.equal(calls, 0, 'stale and expired requests must not dispatch');
    for (const id of ['stale', 'expired', 'stale-catalog']) {
      assert.equal(fs.existsSync(path.join(root, 'responses', `${id}.json`)), false);
      assert.ok(logs.some((line) => line.includes(`discarded ${id}: request expired`)));
    }
    await queuedRequest('long-timeout-catalog', { action: 'models', expiresAt: new Date(Date.now() + 600000).toISOString() }, 301000);
    assert.equal((await response('long-timeout-catalog')).ok, true, 'explicit deadlines must support configured timeouts longer than five minutes');
    await queuedRequest('old-cancel', { action: 'cancel', targetId: 'cancelled-queued' }, 301000);
    await queuedRequest('cancelled-queued', message);
    assert.equal(calls, 0, 'old cancellation must still suppress its queued target');
    await request('catalog', { action: 'models' });
    assert.equal((await response('catalog')).models[0].id, model.id);
    assert.equal(calls, 0, 'catalog must not spend a completion');
    await request('missing', { model: 'nonexistent', messages: [{ content: 'hello' }] });
    assert.equal((await response('missing')).ok, false);
    assert.equal(calls, 0, 'unavailable model must not silently fall back');
    await request('translation', { model: model.id, messages: [{ content: 'hello' }] });
    const translated = await response('translation');
    assert.equal(translated.modelId, model.id);
    assert.equal(translated.provider, 'vscode');
    assert.equal(translated.content, 'Translated');
    assert.equal(calls, 1, 'two VS Code windows must not send duplicate completions');
    for (const disposable of standbySubscriptions.splice(0)) disposable.dispose();
    assert.equal(fs.existsSync(path.join(root, 'heartbeat.json')), true, 'standby disposal must not remove the active heartbeat');
    await request('slow', { model: model.family, messages: [{ content: 'slow' }] });
    while (calls < 2) await new Promise((r) => setTimeout(r, 10));
    await request('cancel', { action: 'cancel', targetId: 'slow' });
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(fs.existsSync(path.join(root, 'responses', 'slow.json')), false);
    let releaseSelection;
    pendingSelection = new Promise((resolve) => { releaseSelection = resolve; });
    const selecting = new Promise((resolve) => { selectionStarted = resolve; });
    await request('selecting', { model: model.id, messages: [{ content: 'hello' }] });
    await selecting;
    const cancelled = new Promise((resolve) => { cancellationObserved = resolve; });
    await request('cancel-selecting', { action: 'cancel', targetId: 'selecting' });
    await cancelled;
    cancellationObserved = null;
    pendingSelection = null;
    releaseSelection([model]);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(calls, 2, 'cancel during model selection must not dispatch a completion');
    assert.equal(fs.existsSync(path.join(root, 'responses', 'selecting.json')), false);
    pendingSelection = new Promise((resolve) => { releaseSelection = resolve; });
    const expirySelection = new Promise((resolve) => { selectionStarted = resolve; });
    const expiryFile = path.join(root, 'requests', 'expires-selecting.pending');
    await fsp.writeFile(expiryFile, JSON.stringify({
      id: 'expires-selecting', ...message, expiresAt: new Date(Date.now() + 150).toISOString(),
    }));
    const expiryHandler = sandbox.handleRequestFile('expires-selecting.pending');
    await expirySelection;
    await new Promise((resolve) => setTimeout(resolve, 200));
    pendingSelection = null;
    releaseSelection([model]);
    await expiryHandler;
    assert.equal(calls, 2, 'expiration during model selection must prevent dispatch');
    assert.match((await response('expires-selecting')).error, /expired before model dispatch/);

    // A request cancelled before it is picked up must never reach the model.
    await request('cancel-early', { action: 'cancel', targetId: 'early' });
    await new Promise((r) => setTimeout(r, 150));
    await request('early', { model: model.id, messages: [{ content: 'hello' }] });
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(calls, 2, 'a queued cancellation must prevent dispatch');
    assert.equal(fs.existsSync(path.join(root, 'responses', 'early.json')), false);
    assert.equal(fs.existsSync(path.join(root, 'requests', 'early.json')), false, 'a cancelled request file must be consumed');

    // A damaged lock of a live owner (fresh heartbeat) must not be reclaimed.
    await standby.module.exports.activate({ subscriptions: standbySubscriptions });
    const lockPath = path.join(root, 'owner.json');
    const originalOwnerId = JSON.parse(await fsp.readFile(lockPath, 'utf8')).ownerId;
    await fsp.writeFile(lockPath, ''); // corrupted empty lock
    const past = new Date(Date.now() - 6000);
    await fsp.utimes(lockPath, past, past);
    assert.equal(await standby.ensureLeader(), false, 'fresh heartbeat must prevent reclaiming a malformed lock');
    // The live leader repairs its own lock on the next heartbeat.
    await sandbox.writeHeartbeat();
    assert.equal(JSON.parse(await fsp.readFile(lockPath, 'utf8')).pid, process.pid);
    assert.equal(await standby.ensureLeader(), false);

    // With no heartbeat (owner crashed before publishing), a stale malformed lock is recovered.
    await fsp.rm(path.join(root, 'heartbeat.json'), { force: true });
    await fsp.writeFile(lockPath, '');
    assert.equal(await standby.ensureLeader(), false, 'a fresh malformed lock must wait for the grace period');
    await fsp.utimes(lockPath, past, past);
    assert.equal(await standby.ensureLeader(), true);
    assert.equal(JSON.parse(await fsp.readFile(lockPath, 'utf8')).pid, process.pid);
    await standby.writeHeartbeat();
    const successorLock = await fsp.readFile(lockPath, 'utf8');
    const successorHeartbeat = await fsp.readFile(path.join(root, 'heartbeat.json'), 'utf8');
    assert.notEqual(JSON.parse(successorLock).ownerId, originalOwnerId, 'each activation must have a unique ownership token');
    assert.equal(JSON.parse(successorLock).ownerId, JSON.parse(successorHeartbeat).ownerId);
    // The two test windows share a PID; only the per-instance token distinguishes them.
    for (const disposable of subscriptions.splice(0)) disposable.dispose();
    assert.equal(await fsp.readFile(lockPath, 'utf8'), successorLock, 'former leader disposal must preserve the successor lock');
    assert.equal(await fsp.readFile(path.join(root, 'heartbeat.json'), 'utf8'), successorHeartbeat, 'former leader disposal must preserve the successor heartbeat');
    assert.equal(await sandbox.ensureLeader(), false, 'a disposed instance must not reclaim leadership');
    for (const disposable of standbySubscriptions.splice(0)) disposable.dispose();
    assert.equal(fs.existsSync(lockPath), false, 'current leader disposal must remove its own lock');
    assert.equal(fs.existsSync(path.join(root, 'heartbeat.json')), false, 'current leader disposal must remove its own heartbeat');
  } finally {
    for (const disposable of standbySubscriptions) disposable.dispose();
    for (const disposable of subscriptions) disposable.dispose();
    await fsp.rm(base, { recursive: true, force: true });
  }
});
