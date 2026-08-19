'use strict';

// LangHelper Bridge
// Watches a folder for translation requests written by the LangHelper tray app
// and answers them with the Copilot models VS Code already has authenticated.
// Plain CommonJS on purpose: the extension installs by copying, with no build step.

const vscode = require('vscode');
const fs = require('fs');
const fsp = require('fs/promises');
const os = require('os');
const path = require('path');

const SCAN_INTERVAL_MS = 300;
const HEARTBEAT_INTERVAL_MS = 15000;
const STALE_REQUEST_MS = 5 * 60 * 1000;

let log;
let state = null;

function resolveBridgeRoot() {
  const base = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  return path.join(base, 'LangHelper', 'bridge');
}

async function writeAtomic(target, text) {
  const tmp = `${target}.${process.pid}.tmp`;
  await fsp.writeFile(tmp, text, 'utf8');
  await fsp.rename(tmp, target);
}

async function pickModel(family) {
  let models = [];
  if (family) {
    models = await vscode.lm.selectChatModels({ vendor: 'copilot', family });
  }
  if (!models.length) models = await vscode.lm.selectChatModels({ vendor: 'copilot' });
  if (!models.length) {
    throw new Error(
      'No GitHub Copilot language model is available. Open VS Code, make sure you are signed in to Copilot, then run "LangHelper: Test Copilot Connection".'
    );
  }
  return models[0];
}

async function runRequest(req) {
  const family =
    (req.model && String(req.model).trim()) ||
    vscode.workspace.getConfiguration('langhelper').get('model') ||
    '';
  const model = await pickModel(family);

  // The stable language model API has no system role, so instruction content is
  // sent as the leading user turn.
  const messages = (req.messages || []).map((m) =>
    m && m.role === 'assistant'
      ? vscode.LanguageModelChatMessage.Assistant(String(m.content == null ? '' : m.content))
      : vscode.LanguageModelChatMessage.User(String(m && m.content != null ? m.content : ''))
  );
  if (!messages.length) throw new Error('Request contained no messages.');

  const cts = new vscode.CancellationTokenSource();
  const timeoutMs = Number(req.timeoutMs) > 0 ? Number(req.timeoutMs) : 120000;
  const timer = setTimeout(() => cts.cancel(), timeoutMs);
  try {
    const response = await model.sendRequest(messages, {}, cts.token);
    let out = '';
    for await (const fragment of response.text) out += fragment;
    if (!out.trim()) throw new Error('The model returned an empty response.');
    return { content: out, modelId: model.id };
  } finally {
    clearTimeout(timer);
    cts.dispose();
  }
}

function describeError(err) {
  if (err instanceof vscode.LanguageModelError) {
    if (err.code === 'NoPermissions' || /consent|permission/i.test(err.message)) {
      return 'VS Code has not been granted permission to use Copilot for LangHelper. Run "LangHelper: Test Copilot Connection" in VS Code and approve the prompt.';
    }
    if (err.code === 'Blocked') {
      return 'Copilot blocked this request by its content filter. Try different wording.';
    }
    return `Copilot error (${err.code}): ${err.message}`;
  }
  return String((err && err.message) || err);
}

async function handleRequestFile(fileName) {
  const full = path.join(state.requestDir, fileName);
  if (state.inFlight.has(fileName)) return;
  state.inFlight.add(fileName);
  try {
    let raw;
    try {
      raw = await fsp.readFile(full, 'utf8');
    } catch {
      return; // Vanished or still being written.
    }

    let req;
    try {
      req = JSON.parse(raw);
    } catch {
      // A partial write parses again on the next scan; only give up once it is clearly stale.
      const stat = await fsp.stat(full).catch(() => null);
      if (stat && Date.now() - stat.mtimeMs > STALE_REQUEST_MS) await fsp.unlink(full).catch(() => {});
      return;
    }

    const id = String(req.id || path.basename(fileName, '.json'));
    await fsp.unlink(full).catch(() => {});
    log.appendLine(`[${new Date().toISOString()}] request ${id} (${(req.messages || []).length} messages)`);

    let payload;
    try {
      const result = await runRequest(req);
      payload = { id, ok: true, content: result.content, modelId: result.modelId };
      log.appendLine(`[${new Date().toISOString()}] answered ${id} with ${result.modelId} (${result.content.length} chars)`);
    } catch (err) {
      payload = { id, ok: false, error: describeError(err) };
      log.appendLine(`[${new Date().toISOString()}] failed ${id}: ${payload.error}`);
    }
    await writeAtomic(path.join(state.responseDir, `${id}.json`), JSON.stringify(payload)).catch((e) =>
      log.appendLine(`[${new Date().toISOString()}] could not write response for ${id}: ${e}`)
    );
  } finally {
    state.inFlight.delete(fileName);
  }
}

async function scan() {
  let files;
  try {
    files = await fsp.readdir(state.requestDir);
  } catch {
    return;
  }
  for (const f of files) {
    if (f.toLowerCase().endsWith('.json')) void handleRequestFile(f);
  }
}

async function writeHeartbeat() {
  const payload = { pid: process.pid, updated: new Date().toISOString() };
  await writeAtomic(path.join(state.root, 'heartbeat.json'), JSON.stringify(payload)).catch(() => {});
}

async function activate(context) {
  log = vscode.window.createOutputChannel('LangHelper Bridge');
  context.subscriptions.push(log);

  const root = resolveBridgeRoot();
  state = {
    root,
    requestDir: path.join(root, 'requests'),
    responseDir: path.join(root, 'responses'),
    inFlight: new Set(),
  };
  await fsp.mkdir(state.requestDir, { recursive: true });
  await fsp.mkdir(state.responseDir, { recursive: true });
  log.appendLine(`LangHelper Bridge active. Bridge folder: ${root}`);

  await writeHeartbeat();
  const heartbeat = setInterval(() => void writeHeartbeat(), HEARTBEAT_INTERVAL_MS);
  const poll = setInterval(() => void scan(), SCAN_INTERVAL_MS);
  context.subscriptions.push({
    dispose: () => {
      clearInterval(heartbeat);
      clearInterval(poll);
      fs.rmSync(path.join(state.root, 'heartbeat.json'), { force: true });
    },
  });

  // fs.watch reacts faster than the poll; the poll stays as the reliability net.
  try {
    const watcher = fs.watch(state.requestDir, (_evt, fileName) => {
      if (fileName && String(fileName).toLowerCase().endsWith('.json')) void handleRequestFile(String(fileName));
    });
    context.subscriptions.push({ dispose: () => watcher.close() });
  } catch (e) {
    log.appendLine(`fs.watch unavailable, polling only: ${e}`);
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('langhelper.showLog', () => log.show(true)),
    vscode.commands.registerCommand('langhelper.openBridgeFolder', () =>
      vscode.env.openExternal(vscode.Uri.file(state.root))
    ),
    vscode.commands.registerCommand('langhelper.testConnection', async () => {
      try {
        const result = await vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title: 'LangHelper: contacting Copilot…' },
          () =>
            runRequest({
              messages: [{ role: 'user', content: 'Reply with exactly: LangHelper OK' }],
              timeoutMs: 60000,
            })
        );
        vscode.window.showInformationMessage(`LangHelper Bridge works. Model: ${result.modelId}. Reply: ${result.content.trim()}`);
      } catch (err) {
        vscode.window.showErrorMessage(`LangHelper Bridge failed: ${describeError(err)}`);
      }
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
