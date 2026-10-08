'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Companion } = require('../src/companion.cjs');
const { WindowsStore } = require('../src/windows-store.cjs');
const { fakeVSCode, request } = require('./helpers.cjs');
const { MESSAGES } = require('../src/contract.cjs');
const { HOOK_KEY, HOOK_ENTRY } = require('../src/contract.cjs');
const { Settings, hasDiscardOnlyExporter, environmentOverrideNames } = require('../src/settings.cjs');

test('Windows local setup uses the native broker and preserves consent / ownership planning', async () => {
  const fake = fakeVSCode();
  let receipt = { version: 1, settings: {} };
  let consumed = false;
  let saved;
  const input = request();
  const store = {
    readRequest: async () => ({ value: input, stat: { mtimeMs: Date.now() } }),
    acquireLock: async () => async () => {},
    readReceipt: async () => receipt,
    saveReceipt: async value => { receipt = structuredClone(value); },
    consume: async () => { consumed = true; },
    writeResult: async (_request, status) => { saved = status; },
  };
  const environment = Object.freeze({ COPILOT_OTEL_FILE_EXPORTER_PATH: '\\\\.\\nul' });
  const companion = new Companion(fake.vscode, { platform: 'win32', store, context: fake.context, environment });
  assert.equal((await companion.run()).status, 'configured');
  assert.equal(saved, 'configured');
  assert.equal(consumed, true);
  assert.ok(receipt.owner);
  assert.ok(fake.messages.some(message => message.options?.detail?.includes('discard-only SDK exporter')));
  assert.equal(environment.COPILOT_OTEL_FILE_EXPORTER_PATH, '\\\\.\\nul');
  assert.ok(!JSON.stringify(fake.messages).includes('\\\\.\\nul'));
  fake.vscode.env.remoteName = 'wsl';
  assert.equal((await companion.run()).message, MESSAGES.remote);
});

test('only the platform-specific exact null device is exempted from exporter guards', () => {
  for (const [platform, allowed] of [['win32', '\\\\.\\nul'], ['darwin', '/dev/null']]) {
    for (const value of ['\\\\.\\nul', '/dev/null', 'NUL', 'nul', '\\\\.\\NUL', '\\\\.\\nul ', 'C:\\trace.jsonl']) {
      const environment = { COPILOT_OTEL_FILE_EXPORTER_PATH: value };
      assert.equal(hasDiscardOnlyExporter(environment, platform), value === allowed);
      assert.deepEqual(environmentOverrideNames(environment, undefined, platform),
        value === allowed ? [] : ['COPILOT_OTEL_FILE_EXPORTER_PATH']);
    }
  }
  const fake = fakeVSCode();
  for (const extra of [{}, { OTEL_EXPORTER_OTLP_HEADERS: 'private' }, { COPILOT_OTEL_ENABLED: 'false' }]) {
    const settings = new Settings(fake.configuration, 1, [fake.configuration],
      { COPILOT_OTEL_FILE_EXPORTER_PATH: '\\\\.\\nul', ...extra }, 'win32');
    if (Object.keys(extra).length) assert.throws(() => settings.planConfigure(request(), { version: 1, settings: {} }), /overrides/);
    else assert.ok(settings.planConfigure(request(), { version: 1, settings: {} }).length > 0);
  }
  fake.globals['telemetry.telemetryLevel'] = 'off';
  assert.throws(() => new Settings(fake.configuration, 1, [fake.configuration],
    { COPILOT_OTEL_FILE_EXPORTER_PATH: '\\\\.\\nul' }, 'win32').planConfigure(request(), { version: 1, settings: {} }), /telemetry is off/);
});

test('Windows broker only requests allowlisted receipt and nonce-bound consumption operations', async () => {
  const store = new WindowsStore('C:\\synthetic');
  const requests = [];
  store.call = async value => { requests.push(value); return value.action === 'lock' ? 'synthetic-lock' : true; };
  const unlock = await store.acquireLock();
  await unlock();
  await store.consume({ digest: 'a'.repeat(64) });
  await store.saveReceipt({ version: 1, settings: {} });
  assert.deepEqual(requests, [
    { action: 'lock' }, { action: 'unlock', token: 'synthetic-lock' },
    { action: 'consume', digest: 'a'.repeat(64) },
    { action: 'write', name: 'vscode-settings.receipt.json', value: { version: 1, settings: {} } },
  ]);
});

function snapshotFixture() {
  const fake = fakeVSCode();
  fake.snapshotConfiguration = true;
  let receipt = { version: 1, settings: {} };
  let input = request();
  let consumed = 0;
  const store = {
    assertRoot: async () => {},
    readRequest: async () => ({ value: input, stat: { mtimeMs: Date.now() } }),
    acquireLock: async () => async () => {},
    readReceipt: async () => receipt,
    saveReceipt: async value => { receipt = structuredClone(value); },
    consume: async () => { consumed++; },
    writeResult: async () => {},
  };
  return { fake, companion: new Companion(fake.vscode, { platform: 'win32', store,
    context: fake.context, environment: { COPILOT_OTEL_FILE_EXPORTER_PATH: '\\\\.\\nul' } }),
  get receipt() { return receipt; }, get consumed() { return consumed; },
  request(value) { input = value; } };
}

test('setup, repair, and removal re-read effective configuration snapshots after updates', async () => {
  const f = snapshotFixture();
  f.fake.vscode.workspace.workspaceFolders = [{ uri: 'folder' }];
  const before = f.fake.vscode.workspace.getConfiguration();
  assert.equal((await f.companion.run()).status, 'configured');
  assert.equal(before.get('github.copilot.chat.otel.enabled'), false, 'get remains an old snapshot');
  assert.equal(before.inspect('github.copilot.chat.otel.enabled').globalValue, true, 'inspect can see the new setting');
  assert.equal(f.receipt.hook.installed, true);
  f.request(request({ endpoints: {
    vscodeLocal: `http://127.0.0.1:43181/${'b'.repeat(64)}/vscodeLocal`,
    vscodeCopilot: `http://127.0.0.1:43181/${'b'.repeat(64)}/vscodeCopilot`,
  } }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.match((await f.companion.check()).vscodeLocal, /effective configured/);
  f.request(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: {} });
  assert.deepEqual(f.receipt.settings, {});
  assert.equal(f.receipt.hook, undefined);
});

test('fresh configuration still rejects real effective overrides without losing the receipt', async () => {
  const f = snapshotFixture();
  f.fake.effective['chat.agentHost.otel.enabled'] = false;
  const result = await f.companion.run();
  assert.equal(result.message, MESSAGES.effective);
  assert.ok(f.receipt.owner);
  assert.ok(f.receipt.settings['chat.agentHost.otel.enabled']);
  f.request(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'removed');
});

test('configuration and new workspace overrides are re-read after approval before any writes', async () => {
  for (const change of ['capture', 'folder']) {
    const f = snapshotFixture();
    const configuration = f.fake.vscode.workspace.getConfiguration;
    f.fake.consent = () => {
      if (change === 'capture') f.fake.globals['github.copilot.chat.otel.captureContent'] = true;
      else {
        f.fake.vscode.workspace.workspaceFolders = [{ uri: 'new-folder' }];
        f.fake.vscode.workspace.getConfiguration = (_section, resource) => {
          const current = configuration();
          return !resource ? current : { ...current,
            inspect: key => ({ ...current.inspect(key),
              ...(key === HOOK_KEY ? { workspaceFolderValue: { [HOOK_ENTRY]: false } } : {}) }) };
        };
      }
      return 'Configure';
    };
    assert.equal((await f.companion.run()).message, MESSAGES.conflict);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.consumed, 0);
  }
});
