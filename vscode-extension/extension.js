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
const { randomUUID } = require('crypto');

const SCAN_INTERVAL_MS = 300;
const HEARTBEAT_INTERVAL_MS = 15000;
const STALE_REQUEST_MS = 5 * 60 * 1000;
const STALE_LOCK_MS = 5000;
const STALE_HEARTBEAT_MS = HEARTBEAT_INTERVAL_MS * 3;
const CANCEL_MEMORY_MS = 2 * 60 * 1000;

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

async function pickModel(selection) {
  const models = await vscode.lm.selectChatModels({ vendor: 'copilot' });
  if (!models.length) {
    throw new Error(
      'No GitHub Copilot language model is available. Open VS Code, make sure you are signed in to Copilot, then run "LangHelper: Test Copilot Connection".'
    );
  }
  if (selection) {
    const selected = models.find((m) => m.id === selection || m.family === selection);
    if (!selected) throw new Error(`The requested Copilot model "${selection}" is unavailable. Refresh the model list and select an available model.`);
    return selected;
  }
  return models[0];
}

async function runRequest(req) {
  const family =
    (req.model && String(req.model).trim()) ||
    vscode.workspace.getConfiguration('langhelper').get('model') ||
    '';
  const cts = new vscode.CancellationTokenSource();
  if (req.id) state.cancellations.set(req.id, cts);
  const timeoutMs = Number(req.timeoutMs) > 0 ? Number(req.timeoutMs) : 120000;
  const timer = setTimeout(() => cts.cancel(), timeoutMs);
  try {
    const model = await pickModel(family);
    if (cts.token.isCancellationRequested || state.cancelled.has(req.id)) {
      throw new Error('Request cancelled before model dispatch.');
    }
    // The stable API has no system role; instructions use the leading user turn.
    const messages = (req.messages || []).map((m) =>
      m && m.role === 'assistant'
        ? vscode.LanguageModelChatMessage.Assistant(String(m.content == null ? '' : m.content))
        : vscode.LanguageModelChatMessage.User(String(m && m.content != null ? m.content : ''))
    );
    if (!messages.length) throw new Error('Request contained no messages.');
    const response = await model.sendRequest(messages, {}, cts.token);
    let out = '';
    for await (const fragment of response.text) out += fragment;
    if (!out.trim()) throw new Error('The model returned an empty response.');
    return { content: out, modelId: model.id, modelName: model.name, provider: 'vscode' };
  } finally {
    if (req.id) state.cancellations.delete(req.id);
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
    if (req.action !== 'cancel' && state.cancelled.delete(id)) {
      log.appendLine(`[${new Date().toISOString()}] skipped ${id}: cancelled before it was dispatched`);
      return;
    }
    log.appendLine(`[${new Date().toISOString()}] request ${id} (${(req.messages || []).length} messages)`);

    let payload;
    try {
      if (req.action === 'cancel') {
        const cts = state.cancellations.get(req.targetId);
        if (cts) cts.cancel();
        // Remember the cancel even if the target has not been picked up yet.
        state.cancelled.set(req.targetId, Date.now());
        await fsp.rm(path.join(state.responseDir, `${req.targetId}.json`), { force: true });
        return;
      }
      if (req.action === 'models') {
        const models = await vscode.lm.selectChatModels({ vendor: 'copilot' });
        payload = { id, ok: true, models: models.map((m) => ({
          id: m.id, name: m.name, family: m.family, vendor: m.vendor,
        })) };
      } else {
        const result = await runRequest({ ...req, id });
        payload = { id, ok: true, ...result };
        log.appendLine(`[${new Date().toISOString()}] answered ${id} with ${result.modelId} (${result.content.length} chars)`);
      }
    } catch (err) {
      payload = { id, ok: false, error: describeError(err) };
      log.appendLine(`[${new Date().toISOString()}] failed ${id}: ${payload.error}`);
    }
    if (state.cancelled.delete(id)) return;
    const responseFile = path.join(state.responseDir, `${id}.json`);
    await writeAtomic(responseFile, JSON.stringify(payload)).catch((e) =>
      log.appendLine(`[${new Date().toISOString()}] could not write response for ${id}: ${e}`)
    );
    if (state.cancelled.delete(id)) {
      await fsp.rm(responseFile, { force: true }).catch(() => {});
    }
  } finally {
    state.inFlight.delete(fileName);
  }
}

async function scan() {
  if (!(await ensureLeader())) return;
  for (const [id, at] of state.cancelled) {
    if (Date.now() - at > CANCEL_MEMORY_MS) state.cancelled.delete(id);
  }
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

async function ensureLeader() {
  if (state.disposed) return false;
  if (state.lockHeld) return verifyLock();
  if (state.claiming) return false;
  state.claiming = true;
  const lockPath = path.join(state.root, 'owner.json');
  try {
    let handle;
    try {
      handle = await fsp.open(lockPath, 'wx');
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
      let owner;
      try {
        owner = JSON.parse(await fsp.readFile(lockPath, 'utf8'));
        if (!owner || typeof owner.pid !== 'number') throw new Error('Malformed lock format');
      } catch {
        // A malformed lock can belong to a live owner, so only reclaim it when
        // it is old and no instance is publishing a fresh heartbeat.
        const stat = await fsp.stat(lockPath).catch(() => null);
        const beat = await fsp.stat(path.join(state.root, 'heartbeat.json')).catch(() => null);
        const beatFresh = beat && Date.now() - beat.mtimeMs < STALE_HEARTBEAT_MS;
        if (stat && Date.now() - stat.mtimeMs > STALE_LOCK_MS && !beatFresh) {
          await fsp.unlink(lockPath).catch(() => {});
          try {
            handle = await fsp.open(lockPath, 'wx');
          } catch {
            return false;
          }
        } else {
          return false;
        }
      }
      if (!handle) {
        try { process.kill(owner.pid, 0); return false; }
        catch (e) {
          if (e.code !== 'ESRCH') return false;
          await fsp.unlink(lockPath);
          return false;
        }
      }
    }
    try { await handle.writeFile(JSON.stringify({ pid: process.pid, ownerId: state.ownerId })); }
    finally { await handle.close(); }
    state.lockHeld = true;
    if (state.disposed) {
      releaseOwnership();
      return false;
    }
    log.appendLine('This VS Code window owns the bridge; other windows stay on standby.');
    return true;
  } catch (err) {
    log.appendLine(`Bridge ownership error: ${err.message}`);
    return false;
  } finally { state.claiming = false; }
}

// A leader keeps owner.json pointing at itself: repair it if it was damaged,
// and step down if another instance has legitimately taken over.
function verifyLock() {
  const lockPath = path.join(state.root, 'owner.json');
  let owner = null;
  try { owner = JSON.parse(fs.readFileSync(lockPath, 'utf8')); }
  catch (err) {
    if (!(err instanceof SyntaxError) && err.code !== 'ENOENT') {
      log.appendLine(`Could not verify bridge ownership: ${err.message}`);
      state.lockHeld = false;
      return false;
    }
  }
  if (owner && typeof owner.pid === 'number') {
    if (owner.ownerId !== state.ownerId || owner.pid !== process.pid) {
      state.lockHeld = false;
      log.appendLine('Another VS Code window took over the bridge; this window is now on standby.');
    }
    return state.lockHeld;
  }
  try {
    fs.writeFileSync(lockPath, JSON.stringify({ pid: process.pid, ownerId: state.ownerId }));
    return true;
  } catch (err) {
    log.appendLine(`Could not repair bridge ownership: ${err.message}`);
    state.lockHeld = false;
    return false;
  }
}

function releaseOwnership() {
  // Never repair a lock during disposal: it may already belong to a successor.
  for (const name of ['heartbeat.json', 'owner.json']) {
    const file = path.join(state.root, name);
    try {
      const owner = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (owner.ownerId === state.ownerId && owner.pid === process.pid) {
        fs.rmSync(file, { force: true });
      }
    } catch (err) {
      if (err.code !== 'ENOENT') log.appendLine(`Could not release ${name}: ${err.message}`);
    }
  }
  state.lockHeld = false;
}

async function writeHeartbeat() {
  if (!(await ensureLeader())) return;
  if (state.disposed || !verifyLock()) return;
  const payload = { pid: process.pid, ownerId: state.ownerId, updated: new Date().toISOString(), protocolVersion: 2 };
  const target = path.join(state.root, 'heartbeat.json');
  const temp = `${target}.${state.ownerId}.tmp`;
  try {
    fs.writeFileSync(temp, JSON.stringify(payload), 'utf8');
    fs.renameSync(temp, target);
  } catch (err) {
    log.appendLine(`Could not publish bridge heartbeat: ${err.message}`);
  }
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
    cancellations: new Map(),
    cancelled: new Map(),
    lockHeld: false,
    claiming: false,
    ownerId: randomUUID(),
    disposed: false,
  };
  await fsp.mkdir(state.requestDir, { recursive: true });
  await fsp.mkdir(state.responseDir, { recursive: true });
  log.appendLine(`LangHelper Bridge active. Bridge folder: ${root}`);

  await writeHeartbeat();
  const heartbeat = setInterval(() => void writeHeartbeat(), HEARTBEAT_INTERVAL_MS);
  const poll = setInterval(() => void scan(), SCAN_INTERVAL_MS);
  context.subscriptions.push({
    dispose: () => {
      state.disposed = true;
      clearInterval(heartbeat);
      clearInterval(poll);
      for (const cts of state.cancellations.values()) cts.cancel();
      releaseOwnership();
    },
  });

  // fs.watch reacts faster than the poll; the poll stays as the reliability net.
  try {
    const watcher = fs.watch(state.requestDir, (_evt, fileName) => {
      if (fileName && String(fileName).toLowerCase().endsWith('.json')) void scan();
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
