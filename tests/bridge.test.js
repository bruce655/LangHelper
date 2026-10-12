'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

test('bridge catalog, strict selection, metadata and cancellation', async () => {
  const base = await fsp.mkdtemp(path.join(os.tmpdir(), 'langhelper-bridge-test-'));
  const subscriptions = [];
  const standbySubscriptions = [];
  let calls = 0;
  class CancellationTokenSource {
    constructor() { this.token = { isCancellationRequested: false }; }
    cancel() { this.token.isCancellationRequested = true; }
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
    lm: { selectChatModels: async () => [model] }, CancellationTokenSource,
    LanguageModelError: class extends Error {},
    LanguageModelChatMessage: { User: (content) => ({ content }), Assistant: (content) => ({ content }) },
    workspace: { getConfiguration: () => ({ get: () => 'claude-sonnet-5.5' }) },
    window: { createOutputChannel: () => ({ appendLine() {}, dispose() {} }) },
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
  } finally {
    for (const disposable of standbySubscriptions) disposable.dispose();
    for (const disposable of subscriptions) disposable.dispose();
    await fsp.rm(base, { recursive: true, force: true });
  }
});
