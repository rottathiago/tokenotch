'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { FILES } = require('../src/private-store.cjs');
const {
  LIMIT, HOOK_KEY, HOOK_ENTRY, SOURCES, SETTING_RULES, MESSAGES,
  validateRequest, validateReceipt, uriNonce, fingerprint
} = require('../src/contract.cjs');
const { NONCE, TOKEN, request, uri, fixture, fakeVSCode } = require('./helpers.cjs');

const LOCAL = SOURCES.vscodeLocal;
const HOST = SOURCES.vscodeCopilot;

test('exact public settings, global updates, preservation, private receipt/result, no automatic reload', async t => {
  const f = await fixture(t);
  f.fake.globals[HOOK_KEY] = { '/another/hooks': false, '/other/enabled': true };
  f.fake.globals[`${LOCAL}.headers`] = { authorization: 'private-header' };
  const original = structuredClone(f.fake.globals);
  const input = await f.write();
  f.fake.consent = async (_message, _options, items) => {
    assert.equal(f.fake.updates.length, 0);
    assert.deepEqual(await f.read('request'), input);
    await assert.rejects(fs.access(path.join(f.root, FILES.receipt)));
    return items[0];
  };
  const result = await f.companion.run({ uri: uri() });
  assert.equal(result.status, 'configured');
  assert.deepEqual(f.fake.updates.map(item => item.key), [
    `${LOCAL}.exporterType`, `${LOCAL}.protocol`, `${LOCAL}.otlpEndpoint`, `${LOCAL}.captureContent`,
    `${HOST}.exporterType`, `${HOST}.otlpEndpoint`, `${HOST}.captureContent`, `${LOCAL}.enabled`, `${HOST}.enabled`, HOOK_KEY
  ]);
  assert.ok(f.fake.updates.every(item => item.target === f.fake.vscode.ConfigurationTarget.Global));
  assert.equal(f.fake.globals[`${LOCAL}.protocol`], 'http/json');
  assert.equal(f.fake.globals[`${LOCAL}.exporterType`], 'otlp-http');
  assert.equal(f.fake.globals[`${HOST}.exporterType`], 'otlp-http');
  assert.equal(f.fake.globals[`${HOST}.captureContent`], false);
  assert.equal(f.fake.globals[`${HOST}.otlpProtocol`], undefined);
  assert.deepEqual(f.fake.globals[HOOK_KEY], { ...original[HOOK_KEY], [HOOK_ENTRY]: true });
  assert.deepEqual(f.fake.globals[`${LOCAL}.headers`], original[`${LOCAL}.headers`]);
  const receipt = await f.read('receipt');
  assert.equal(receipt.settings[`${LOCAL}.otlpEndpoint`].installed[0].sha256, fingerprint(input.endpoints.vscodeLocal));
  const saved = await f.read('result');
  assert.deepEqual(saved, { version: 1, nonce: NONCE, operation: 'configure', ...result });
  assert.ok(!JSON.stringify(receipt).includes(TOKEN));
  assert.ok(!JSON.stringify(receipt).includes('/another/hooks'));
  assert.ok(!JSON.stringify(receipt).includes('private-header'));
  assert.ok(!JSON.stringify(f.fake.messages).includes(TOKEN));
  assert.ok(!JSON.stringify(saved).includes(TOKEN));
  assert.ok(!JSON.stringify(saved).includes(f.root));
  for (const name of ['receipt', 'result']) {
    const stat = await fs.lstat(path.join(f.root, FILES[name]));
    assert.equal(stat.mode & 0o7777, 0o600);
    assert.ok(stat.size <= LIMIT);
  }
  assert.deepEqual(await fs.readdir(f.root), [FILES.result, FILES.receipt].sort());
  assert.deepEqual(f.fake.executions, []);
});

test('repeat setup is idempotent and removing restores only owned global fields', async t => {
  const f = await fixture(t);
  f.fake.globals[HOOK_KEY] = { '/other': true, [HOOK_ENTRY]: false };
  f.fake.globals[`${LOCAL}.enabled`] = false;
  const original = structuredClone(f.fake.globals);
  await f.write();
  assert.equal((await f.companion.run()).status, 'configured');
  const receipt = await f.read('receipt');
  const writes = f.fake.updates.length;
  await f.write(request({ nonce: '2'.repeat(64) }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.equal(f.fake.updates.length, writes);
  assert.deepEqual(await f.read('receipt'), receipt);
  await f.write(request({ operation: 'remove' }));
  const beforeRemoval = f.fake.updates.length;
  assert.equal((await f.companion.run({ operation: 'remove' })).status, 'removed');
  assert.deepEqual(f.fake.updates.slice(beforeRemoval, beforeRemoval + 2).map(item => item.key),
    [`${LOCAL}.enabled`, `${HOST}.enabled`]);
  assert.deepEqual(f.fake.globals, original);
  assert.deepEqual(await f.read('receipt'), { version: 1, settings: {} });
});

test('preexisting identical hook entry is never adopted or removed', async t => {
  const f = await fixture(t);
  f.fake.globals[HOOK_KEY] = { [HOOK_ENTRY]: true, other: false };
  await f.write(request({ metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.equal((await f.read('receipt')).hook, undefined);
  await f.write(request({ operation: 'remove', metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals[HOOK_KEY], { [HOOK_ENTRY]: true, other: false });
  assert.equal(f.fake.updates.length, 0);
});

test('hooks-only works without metrics schema or permission to enable telemetry', async t => {
  const f = await fixture(t, { environment: { OTEL_EXPORTER_OTLP_ENDPOINT: 'external-secret' } });
  for (const key of Object.keys(SETTING_RULES)) f.fake.unsupported.add(key);
  f.fake.globals['telemetry.telemetryLevel'] = 'off';
  await f.write(request({ metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.deepEqual(f.fake.updates.map(item => item.key), [HOOK_KEY]);
});

test('removal flags allow metrics-only disable and preserve user edits and unrelated hooks', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  f.fake.globals[`${LOCAL}.otlpEndpoint`] = 'https://external.example/edited';
  f.fake.globals[`${HOST}.enabled`] = false;
  f.fake.globals[HOOK_KEY].other = true;
  await f.write(request({ operation: 'remove', hooks: false }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.equal(f.fake.globals[`${LOCAL}.otlpEndpoint`], 'https://external.example/edited');
  assert.equal(f.fake.globals[`${HOST}.enabled`], false);
  assert.deepEqual(f.fake.globals[HOOK_KEY], { [HOOK_ENTRY]: true, other: true });
  assert.deepEqual(Object.keys((await f.read('receipt')).settings), []);
  assert.ok((await f.read('receipt')).hook);
  await f.write(request({ operation: 'remove', metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals[HOOK_KEY], { other: true });
});

test('edited hook entry remains unchanged during removal', async t => {
  const f = await fixture(t);
  await f.write(request({ metrics: false, endpoints: undefined }));
  await f.companion.run();
  f.fake.globals[HOOK_KEY][HOOK_ENTRY] = false;
  await f.write(request({ operation: 'remove', metrics: false, endpoints: undefined }));
  await f.companion.run();
  assert.deepEqual(f.fake.globals[HOOK_KEY], { [HOOK_ENTRY]: false });
  assert.equal((await f.read('receipt')).hook, undefined);
});

test('hooks-only removal retains metrics ownership and effective settings', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  await f.write(request({ operation: 'remove', metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.equal(f.fake.globals[`${LOCAL}.enabled`], true);
  assert.equal(Object.keys((await f.read('receipt')).settings).length, 9);
  assert.deepEqual(f.fake.globals[HOOK_KEY], {});
});

test('endpoint-free removal succeeds without a receiver or ownership receipt', async t => {
  const f = await fixture(t);
  for (const key of Object.keys(SETTING_RULES)) f.fake.unsupported.add(key);
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal(Object.hasOwn(await f.read('request'), 'endpoints'), false);
  assert.equal((await f.companion.run({ uri: uri() })).status, 'removed');
  assert.equal((await f.read('result')).status, 'removed');
  assert.deepEqual(await f.read('receipt'), { version: 1, settings: {} });
  assert.equal(f.fake.updates.length, 0);
  await assert.rejects(fs.access(path.join(f.root, FILES.request)));
});

test('endpoint-free metrics removal uses receipt ownership and preserves hooks', async t => {
  const f = await fixture(t);
  await f.write();
  assert.equal((await f.companion.run()).status, 'configured');
  await f.write(request({ operation: 'remove', hooks: false, endpoints: undefined }));
  assert.equal((await f.companion.run({ uri: uri() })).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: { [HOOK_ENTRY]: true } });
  const receipt = await f.read('receipt');
  assert.deepEqual(receipt.settings, {});
  assert.ok(receipt.hook);
});

const conflicts = [
  [`${LOCAL}.otlpEndpoint`, 'https://external.example/collector'],
  [`${HOST}.otlpEndpoint`, 'http://127.0.0.1:1234/existing'],
  [`${LOCAL}.exporterType`, 'console'],
  [`${HOST}.exporterType`, 'file'],
  [`${LOCAL}.protocol`, 'grpc'],
  [`${LOCAL}.captureContent`, true],
  [`${HOST}.captureContent`, true],
  [`${LOCAL}.outfile`, '/private/capture'],
  [`${HOST}.outFile`, '/private/capture'],
  [`${HOST}.dbSpanExporter.enabled`, true]
];
for (const [key, value] of conflicts) {
  test(`preexisting ${key} conflict is refused before any setting changes`, async t => {
    const f = await fixture(t);
    f.fake.defaults[key] ??= '';
    f.fake.globals[key] = value;
    await f.write();
    const result = await f.companion.run();
    assert.equal(result.status, 'blocked');
    assert.equal(result.message, MESSAGES.conflict);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.fake.globals[key], value);
    assert.equal((await f.read('result')).status, 'blocked');
    assert.ok(await f.read('request'));
    assert.ok(!JSON.stringify(f.fake.messages).includes(String(value)) || typeof value !== 'string');
  });
}

test('active default external collector is not silently replaced', async t => {
  const f = await fixture(t);
  f.fake.globals[`${LOCAL}.enabled`] = true;
  await f.write();
  assert.equal((await f.companion.run()).message, MESSAGES.conflict);
  assert.equal(f.fake.updates.length, 0);
});

for (const variable of [
  'OTEL_EXPORTER_OTLP_HEADERS', 'COPILOT_OTEL_ENABLED', 'GITHUB_COPILOT_OTEL_ENABLED',
  'VSCODE_OTEL_ENDPOINT', 'VSCODE_AGENT_HOST_OTEL_ENDPOINT', 'otel_exporter_otlp_endpoint'
]) {
  test(`process override ${variable} blocks metrics without exposing its value`, async t => {
    const secret = 'do-not-show-me';
    const environment = Object.freeze({ [variable]: secret });
    const f = await fixture(t, { environment });
    const input = await f.write();
    assert.equal((await f.companion.run()).message, MESSAGES.environment);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.fake.stateUpdates.length, 0);
    assert.deepEqual(await f.read('request'), input);
    await assert.rejects(fs.access(path.join(f.root, FILES.receipt)));
    const message = f.fake.messages.at(-1);
    assert.equal(message.options.modal, true);
    assert.ok(message.options.detail.split('\n').includes(variable));
    assert.match(message.options.detail, /Cmd\+Q/);
    assert.match(message.options.detail, /Activity-only setup/);
    assert.ok(!JSON.stringify(f.fake.messages).includes(secret));
    assert.deepEqual(await f.read('result'), {
      version: 1, nonce: NONCE, operation: 'configure', status: 'blocked', message: MESSAGES.environment
    });
    assert.deepEqual(environment, { [variable]: secret });
  });
}

test('empty OTel variables and unrelated environment variables do not block metrics', async t => {
  const f = await fixture(t, { environment: {
    OTEL_EXPORTER_OTLP_ENDPOINT: '', COPILOT_OTEL_ENABLED: undefined, UNRELATED: 'private-value'
  } });
  await f.write();
  assert.equal((await f.companion.run()).status, 'configured');
  assert.ok(!JSON.stringify(f.fake.messages).includes('private-value'));
});

test('the exact Copilot discard-only SDK marker allows approved setup without changing the environment', async t => {
  const environment = Object.freeze({ COPILOT_OTEL_FILE_EXPORTER_PATH: '/dev/null' });
  const f = await fixture(t, { environment });
  let diagnostics = await f.companion.check();
  assert.equal(diagnostics.vscodeLocal, 'not configured');
  assert.equal(diagnostics.vscodeCopilot, 'not configured');
  assert.deepEqual(diagnostics.reasons, []);
  assert.match(f.fake.messages.at(-1).message, /discard-only SDK exporter.*may still suppress delivery/);
  await f.write();
  f.fake.consent = (_message, options, items) => {
    assert.match(options.detail, /discard-only SDK exporter/);
    assert.match(options.detail, /verify actual usage/);
    assert.equal(f.fake.updates.length, 0);
    return items[0];
  };
  assert.equal((await f.companion.run()).status, 'configured');
  assert.equal(f.fake.globals[`${LOCAL}.exporterType`], 'otlp-http');
  assert.equal(f.fake.globals[`${LOCAL}.captureContent`], false);
  diagnostics = await f.companion.check();
  for (const source of Object.keys(SOURCES)) {
    assert.equal(diagnostics[source], 'effective configured; reload may be needed; awaiting actual data');
  }
  assert.deepEqual(environment, { COPILOT_OTEL_FILE_EXPORTER_PATH: '/dev/null' });
  assert.ok(!JSON.stringify(f.fake.messages).includes('/dev/null'));
  for (const name of ['receipt', 'result']) {
    const saved = JSON.stringify(await f.read(name));
    assert.ok(!saved.includes('/dev/null'));
    assert.ok(!saved.includes('discard-only'));
    assert.ok(!saved.includes('COPILOT_OTEL_FILE_EXPORTER_PATH'));
  }
});

test('discard-only SDK marker does not bypass consent', async t => {
  const f = await fixture(t, { environment: { COPILOT_OTEL_FILE_EXPORTER_PATH: '/dev/null' } });
  const input = await f.write();
  f.fake.consent = () => undefined;
  assert.equal((await f.companion.run()).status, 'cancelled');
  assert.equal(f.fake.updates.length, 0);
  assert.equal(f.fake.stateUpdates.length, 0);
  assert.deepEqual(await f.read('request'), input);
});

for (const value of ['/private/trace.jsonl', '/dev/null/trace', '/dev/null ', ' /dev/null', '/DEV/NULL', 'file:///dev/null', 'NUL']) {
  test(`file exporter path ${JSON.stringify(value)} is not a discard-only exception`, async t => {
    const f = await fixture(t, { environment: { COPILOT_OTEL_FILE_EXPORTER_PATH: value } });
    const input = await f.write();
    assert.equal((await f.companion.run()).message, MESSAGES.environment);
    assert.equal(f.fake.updates.length, 0);
    assert.deepEqual(await f.read('request'), input);
    assert.match(f.fake.messages.at(-1).options.detail, /COPILOT_OTEL_FILE_EXPORTER_PATH/);
    assert.ok(!JSON.stringify(f.fake.messages).includes(value));
  });
}

for (const key of ['OTEL_EXPORTER_OTLP_ENDPOINT', 'COPILOT_OTEL_EXPORTER_TYPE', 'COPILOT_OTEL_CAPTURE_CONTENT',
  'OTEL_EXPORTER_OTLP_HEADERS', 'copilot_otel_file_exporter_path']) {
  test(`discard-only marker does not exempt ${key}`, async t => {
    const f = await fixture(t, { environment: { COPILOT_OTEL_FILE_EXPORTER_PATH: '/dev/null', [key]: '/dev/null' } });
    await f.write();
    assert.equal((await f.companion.run()).message, MESSAGES.environment);
    assert.equal(f.fake.updates.length, 0);
    assert.ok(f.fake.messages.at(-1).options.detail.split('\n').includes(key));
    assert.ok(!f.fake.messages.at(-1).options.detail.split('\n').includes('COPILOT_OTEL_FILE_EXPORTER_PATH'));
    assert.ok(!JSON.stringify(f.fake.messages).includes('/dev/null'));
  });
}

for (const [key, value, message] of [
  ['telemetry.telemetryLevel', 'off', MESSAGES.telemetry],
  [`${LOCAL}.captureContent`, true, MESSAGES.conflict],
  [`${HOST}.dbSpanExporter.enabled`, true, MESSAGES.conflict],
  [`${LOCAL}.outfile`, '/dev/null', MESSAGES.conflict],
  [`${LOCAL}.otlpEndpoint`, 'https://external.example/collector', MESSAGES.conflict]
]) {
  test(`discard-only marker does not bypass the ${key} settings guard`, async t => {
    const f = await fixture(t, { environment: { COPILOT_OTEL_FILE_EXPORTER_PATH: '/dev/null' } });
    f.fake.defaults[key] ??= '';
    f.fake.globals[key] = value;
    await f.write();
    assert.equal((await f.companion.run()).message, message);
    assert.equal(f.fake.updates.length, 0);
  });
}

test('discard-only marker changing to a file during consent is blocked before writes', async t => {
  const environment = { COPILOT_OTEL_FILE_EXPORTER_PATH: '/dev/null' };
  const f = await fixture(t, { environment });
  const input = await f.write();
  f.fake.consent = () => {
    environment.COPILOT_OTEL_FILE_EXPORTER_PATH = '/private/trace.jsonl';
    return 'Configure';
  };
  assert.equal((await f.companion.run()).message, MESSAGES.environment);
  assert.equal(f.fake.updates.length, 0);
  assert.equal(f.fake.stateUpdates.length, 0);
  assert.deepEqual(await f.read('request'), input);
  assert.ok(!JSON.stringify(f.fake.messages).includes('/private/trace.jsonl'));
});

function copilotMirror(endpoint) {
  return {
    COPILOT_OTEL_ENABLED: 'true',
    OTEL_EXPORTER_OTLP_ENDPOINT: endpoint,
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT: 'false'
  };
}

test('Copilot mirroring Tokenotch-owned settings into the extension host does not block repeat setup', async t => {
  const environment = {};
  const f = await fixture(t, { environment });
  const input = await f.write();
  assert.equal((await f.companion.run()).status, 'configured');
  Object.assign(environment, copilotMirror(input.endpoints.vscodeLocal));
  const diagnostics = await f.companion.check();
  assert.deepEqual(diagnostics.reasons, []);
  for (const source of Object.keys(SOURCES)) {
    assert.equal(diagnostics[source], 'effective configured; reload may be needed; awaiting actual data');
  }
  await f.write(request({ nonce: '2'.repeat(64) }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.deepEqual(environment, copilotMirror(input.endpoints.vscodeLocal));
});

for (const [key, value] of [
  ['COPILOT_OTEL_ENABLED', '1'],
  ['OTEL_EXPORTER_OTLP_ENDPOINT', 'https://external.example/collector'],
  ['OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT', 'true']
]) {
  test(`${key} differing from Copilot settings is still reported after setup`, async t => {
    const environment = {};
    const f = await fixture(t, { environment });
    const input = await f.write();
    assert.equal((await f.companion.run()).status, 'configured');
    Object.assign(environment, copilotMirror(input.endpoints.vscodeLocal), { [key]: value });
    await f.write(request({ nonce: '2'.repeat(64) }));
    assert.equal((await f.companion.run()).message, MESSAGES.environment);
    assert.deepEqual(f.fake.messages.at(-1).options.detail.split('\n').slice(1, 2), [key]);
    assert.ok(!JSON.stringify(f.fake.messages).includes('external.example'));
  });
}

test('Copilot-shaped OTel variables are reported while Copilot OTel is not enabled', async t => {
  const f = await fixture(t, { environment: copilotMirror(request().endpoints.vscodeLocal) });
  await f.write();
  assert.equal((await f.companion.run()).message, MESSAGES.environment);
  assert.deepEqual(f.fake.messages.at(-1).options.detail.split('\n').slice(1, 4),
    ['COPILOT_OTEL_ENABLED', 'OTEL_EXPORTER_OTLP_ENDPOINT', 'OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT']);
  assert.equal(f.fake.updates.length, 0);
});

test('environment diagnostics list sorted names without changing settings or exposing values', async t => {
  const f = await fixture(t, { environment: {
    VSCODE_OTEL_ENDPOINT: 'private-endpoint', COPILOT_OTEL_ENABLED: 'false',
    OTEL_EXPORTER_OTLP_HEADERS: 'private-headers', OTEL_EMPTY: '', UNRELATED: 'private-value'
  } });
  const result = await f.companion.check();
  assert.deepEqual(result, {
    hooks: 'not configured', vscodeLocal: 'blocked', vscodeCopilot: 'blocked', reasons: ['environment']
  });
  const message = f.fake.messages.at(-1);
  assert.equal(message.options.modal, true);
  assert.deepEqual(message.options.detail.split('\n').slice(1, 4),
    ['COPILOT_OTEL_ENABLED', 'OTEL_EXPORTER_OTLP_HEADERS', 'VSCODE_OTEL_ENDPOINT']);
  for (const value of ['private-endpoint', 'private-headers', 'private-value', 'OTEL_EMPTY', 'UNRELATED']) {
    assert.ok(!JSON.stringify(f.fake.messages).includes(value));
  }
  assert.equal(f.fake.updates.length, 0);
  assert.equal(f.fake.stateUpdates.length, 0);
  assert.deepEqual(await fs.readdir(f.root), []);
});

test('environment details hide malformed names and bound the displayed list', async t => {
  const malformed = 'OTEL_BAD\nprivate-name';
  const long = `OTEL_${'X'.repeat(128)}`;
  const environment = Object.fromEntries([
    [malformed, 'private-value'], [long, 'private-value'],
    ...Array.from({ length: 40 }, (_, index) => [`VSCODE_OTEL_TEST_${index}`, 'private-value'])
  ]);
  const f = await fixture(t, { environment });
  await f.write();
  assert.equal((await f.companion.run()).status, 'blocked');
  const detail = f.fake.messages.at(-1).options.detail;
  assert.ok(!detail.includes('private-name'));
  assert.ok(!detail.includes(long));
  assert.ok(!detail.includes('private-value'));
  assert.equal(detail.split('\n').filter(line => line === '[nonstandard variable name hidden]').length, 2);
  assert.match(detail, /10 additional variable names omitted/);
  assert.equal(f.fake.updates.length, 0);
});

test('environment introduced during consent blocks before request consumption or settings writes', async t => {
  const environment = {};
  const f = await fixture(t, { environment });
  const input = await f.write();
  f.fake.consent = () => {
    environment.OTEL_EXPORTER_OTLP_ENDPOINT = 'private-endpoint';
    return 'Configure';
  };
  assert.equal((await f.companion.run()).message, MESSAGES.environment);
  assert.match(f.fake.messages.at(-1).options.detail, /OTEL_EXPORTER_OTLP_ENDPOINT/);
  assert.ok(!JSON.stringify(f.fake.messages).includes('private-endpoint'));
  assert.equal(f.fake.updates.length, 0);
  assert.equal(f.fake.stateUpdates.length, 0);
  assert.deepEqual(await f.read('request'), input);
});

test('owned metrics can still be removed with OTel environment overrides present', async t => {
  const environment = {};
  const f = await fixture(t, { environment });
  await f.write();
  assert.equal((await f.companion.run()).status, 'configured');
  environment.OTEL_EXPORTER_OTLP_ENDPOINT = 'private-endpoint';
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(await f.read('receipt'), { version: 1, settings: {} });
  assert.ok(!JSON.stringify(f.fake.messages).includes('private-endpoint'));
});

test('telemetry off and unavailable source settings block before writes', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.globals['telemetry.telemetryLevel'] = 'off';
  assert.equal((await f.companion.run()).message, MESSAGES.telemetry);
  delete f.fake.globals['telemetry.telemetryLevel'];
  f.fake.unsupported.add(`${HOST}.otlpEndpoint`);
  assert.equal((await f.companion.run()).message, MESSAGES.unsupported);
  assert.equal(f.fake.updates.length, 0);
});

test('workspace/folder overrides and publicly visible policy mismatch block setup', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.workspace[`${HOST}.enabled`] = false;
  assert.equal((await f.companion.run()).message, MESSAGES.conflict);
  delete f.fake.workspace[`${HOST}.enabled`];
  f.fake.effective[`${LOCAL}.enabled`] = 'managed';
  assert.equal((await f.companion.run()).message, MESSAGES.conflict);
  delete f.fake.effective[`${LOCAL}.enabled`];
  const base = f.fake.configuration;
  const folder = {
    get: base.get,
    inspect(key) { return { ...base.inspect(key), ...(key === `${LOCAL}.enabled` ? { workspaceFolderValue: false } : {}) }; }
  };
  f.fake.vscode.workspace.workspaceFolders = [{ uri: 'folder' }];
  f.fake.vscode.workspace.getConfiguration = (_section, resource) => resource ? folder : base;
  assert.equal((await f.companion.run()).message, MESSAGES.conflict);
  assert.equal(f.fake.updates.length, 0);
});

test('effective post-write mismatch is reported, not claimed configured, and remains removable', async t => {
  const f = await fixture(t);
  f.fake.effective[`${HOST}.enabled`] = false;
  await f.write();
  assert.equal((await f.companion.run()).message, MESSAGES.effective);
  assert.equal((await f.read('result')).status, 'blocked');
  await f.write(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: {} });
});

for (const when of ['beforeUpdate', 'afterUpdate']) {
  test(`partial configuration failure ${when} is completely reversible`, async t => {
    const f = await fixture(t);
    const failingKey = `${HOST}.exporterType`;
    f.fake[when] = key => { if (key === failingKey) throw new Error(`raw private error ${TOKEN}`); };
    await f.write();
    assert.equal((await f.companion.run()).status, 'failed');
    assert.ok(!JSON.stringify(f.fake.messages).includes(TOKEN));
    assert.ok((await f.read('receipt')).settings[failingKey]);
    f.fake[when] = undefined;
    await f.write(request({ operation: 'remove', endpoints: undefined }));
    assert.equal((await f.companion.run()).status, 'removed');
    assert.deepEqual(f.fake.globals, {});
    assert.deepEqual(await f.read('receipt'), { version: 1, settings: {} });
  });
}

for (const phase of ['before-update', 'after-update']) {
  test(`receipt persistence failure ${phase} retains recoverable ownership`, async t => {
    const f = await fixture(t);
    const save = f.store.saveReceipt.bind(f.store);
    let writes = 0;
    f.store.saveReceipt = async value => {
      writes += 1;
      if (writes === (phase === 'before-update' ? 3 : 4)) throw new Error('disk failure');
      await save(value);
    };
    await f.write();
    assert.equal((await f.companion.run()).status, 'failed');
    f.store.saveReceipt = save;
    await f.write(request({ operation: 'remove' }));
    assert.equal((await f.companion.run()).status, 'removed');
    assert.deepEqual(f.fake.globals, {});
  });
}

test('token rotation crash before update retains old fingerprint for later removal', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const key = `${LOCAL}.otlpEndpoint`;
  const original = f.fake.globals[key];
  const next = request();
  next.endpoints = Object.fromEntries(Object.entries(next.endpoints).map(([source, value]) => [source, value.replace(TOKEN, 'b'.repeat(64))]));
  f.fake.beforeUpdate = name => { if (name === key) throw new Error('failed'); };
  await f.write(next);
  assert.equal((await f.companion.run()).status, 'failed');
  assert.equal(f.fake.globals[key], original);
  assert.equal((await f.read('receipt')).settings[key].installed.length, 2);
  f.fake.beforeUpdate = undefined;
  await f.write(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: {} });
});

test('removal receipt failure after restoring a field can be resumed', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const save = f.store.saveReceipt.bind(f.store);
  f.store.saveReceipt = async () => { throw new Error('disk failure'); };
  await f.write(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'failed');
  f.store.saveReceipt = save;
  await f.write(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: {} });
});

test('cancel leaves request reusable but changes no settings and stores a safe result', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.consent = () => undefined;
  assert.equal((await f.companion.run({ uri: uri() })).status, 'cancelled');
  assert.equal(f.fake.updates.length, 0);
  assert.equal((await f.read('result')).status, 'cancelled');
  assert.ok(await f.read('request'));
  f.fake.consent = undefined;
  assert.equal((await f.companion.run({ uri: uri() })).status, 'configured');
  const count = f.fake.updates.length;
  assert.equal((await f.companion.run({ uri: uri() })).status, 'blocked');
  assert.equal(f.fake.updates.length, count);
});

test('consented expired or replaced request is not applied', async t => {
  const f = await fixture(t);
  const now = Date.now();
  const value = await f.write(request({ expiresAt: Math.floor(now / 1000) + 10 }));
  f.companion.now = () => now;
  f.fake.consent = (_message, _options, items) => { f.companion.now = () => now + 11000; return items[0]; };
  assert.equal((await f.companion.run()).message, MESSAGES.expired);
  f.companion.now = Date.now;
  f.fake.consent = async (_message, _options, items) => {
    await f.write({ ...value, nonce: '3'.repeat(64) });
    return items[0];
  };
  assert.equal((await f.companion.run()).message, MESSAGES.changed);
  assert.equal(f.fake.updates.length, 0);
});

test('nonce mismatch, wrong command operation, invalid URI and freshness are rejected', async t => {
  const f = await fixture(t);
  await f.write();
  assert.equal((await f.companion.run({ uri: uri('2'.repeat(64)) })).message, MESSAGES.nonce);
  await assert.rejects(fs.access(path.join(f.root, FILES.result)));
  assert.equal((await f.companion.run({ operation: 'remove' })).message, MESSAGES.request);
  for (const change of [
    { scheme: 'vscode-insiders' }, { authority: 'other.extension' }, { path: '/other' },
    { fragment: 'extra' }, { query: `nonce=${NONCE}&endpoint=secret` }, { query: `nonce=${NONCE}&nonce=${NONCE}` }
  ]) assert.throws(() => uriNonce({ ...uri(), ...change }));
  for (const expiresAt of [Math.floor(Date.now() / 1000) - 1, Math.floor(Date.now() / 1000) + 601]) {
    await f.write(request({ expiresAt }));
    assert.equal((await f.companion.run()).message, MESSAGES.expired);
  }
  await f.write();
  await fs.utimes(path.join(f.root, FILES.request), new Date(), new Date(Date.now() - 601000));
  assert.equal((await f.companion.run()).message, MESSAGES.expired);
  assert.equal(f.fake.updates.length, 0);
});

for (const remote of ['ssh-remote', 'wsl', 'dev-container', 'codespaces']) {
  test(`remote ${remote} rejects before touching private storage`, async t => {
    const f = await fixture(t);
    f.fake.vscode.env.remoteName = remote;
    f.store.readRequest = () => assert.fail('must not read storage');
    assert.equal((await f.companion.run({ uri: uri() })).message, MESSAGES.remote);
    assert.equal((await f.companion.check()).message, MESSAGES.remote);
    assert.deepEqual(await fs.readdir(f.root), []);
  });
}

test('non-macOS windows reject before storage or settings access', async t => {
  const f = await fixture(t, { platform: 'win32' });
  f.store.readRequest = () => assert.fail('must not read storage');
  assert.equal((await f.companion.run()).message, MESSAGES.remote);
  assert.equal(f.fake.updates.length, 0);
});

test('exclusive cross-window lock blocks concurrent setup', async t => {
  const f = await fixture(t);
  await f.write();
  const release = await f.store.acquireLock();
  assert.equal((await f.companion.run()).message, MESSAGES.busy);
  assert.equal(f.fake.updates.length, 0);
  await release();
  assert.equal((await f.companion.run()).status, 'configured');
});

test('reload command is only executed after explicit optional selection', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.reload = true;
  assert.equal((await f.companion.run()).status, 'configured');
  assert.deepEqual(f.fake.executions, [['workbench.action.reloadWindow']]);
  f.fake.reload = false;
  await f.write(request({ operation: 'remove' }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.executions, [['workbench.action.reloadWindow']]);
  assert.equal(f.fake.messages.at(-1).options, 'Reload Window');
});

test('source-specific diagnostics report effective configuration, not live telemetry', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const count = f.fake.updates.length;
  let result = await f.companion.check();
  assert.equal(result.hooks, 'effective configured');
  assert.match(result.vscodeLocal, /effective configured.*reload.*awaiting actual data/);
  f.fake.globals[`${HOST}.enabled`] = false;
  result = await f.companion.check();
  assert.match(result.vscodeLocal, /effective configured/);
  assert.equal(result.vscodeCopilot, 'not configured');
  f.fake.defaults[`${LOCAL}.outfile`] = '';
  f.fake.globals[`${LOCAL}.outfile`] = 'private-path';
  result = await f.companion.check();
  assert.equal(result.vscodeLocal, 'blocked');
  assert.equal(result.vscodeCopilot, 'not configured');
  assert.equal(f.fake.updates.length, count);
  assert.ok(!JSON.stringify(f.fake.messages).includes(TOKEN));
});

test('neither source is enabled until its safe destination and capture controls are installed', async t => {
  const f = await fixture(t);
  const value = await f.write();
  f.fake.beforeUpdate = (key, enabled) => {
    if (!key.endsWith('.enabled') || !enabled) return;
    for (const [source, prefix] of Object.entries(SOURCES)) {
      assert.equal(f.fake.globals[`${prefix}.otlpEndpoint`], value.endpoints[source]);
      assert.equal(f.fake.globals[`${prefix}.captureContent`], false);
      assert.equal(f.fake.globals[`${prefix}.exporterType`], 'otlp-http');
    }
    assert.equal(f.fake.globals[`${LOCAL}.protocol`], 'http/json');
  };
  assert.equal((await f.companion.run()).status, 'configured');
});

test('unrelated hooks edited during receipt persistence are preserved by the latest-map merge', async t => {
  const f = await fixture(t);
  await f.write(request({ metrics: false, endpoints: undefined }));
  const save = f.store.saveReceipt.bind(f.store);
  f.store.saveReceipt = async receipt => {
    await save(receipt);
    f.fake.globals[HOOK_KEY] = { ...f.fake.globals[HOOK_KEY], addedDuringSetup: true };
  };
  assert.equal((await f.companion.run()).status, 'configured');
  assert.deepEqual(f.fake.globals[HOOK_KEY], { addedDuringSetup: true, [HOOK_ENTRY]: true });
});

test('endpoint validator rejects non-loopback, wrong source, mismatched token/port and extra URL material', () => {
  for (const endpoint of [
    `http://localhost:43180/${TOKEN}/vscodeLocal`,
    `https://127.0.0.1:43180/${TOKEN}/vscodeLocal`,
    `http://127.0.0.1:65536/${TOKEN}/vscodeLocal`,
    `http://127.0.0.1:0/${TOKEN}/vscodeLocal`,
    `http://127.0.0.1:04318/${TOKEN}/vscodeLocal`,
    `http://127.0.0.1:43180/${TOKEN}/vscodeCopilot`,
    `http://127.0.0.1:43180/${TOKEN.toUpperCase()}/vscodeLocal`,
    `http://127.0.0.1:43180/${TOKEN}/vscodeLocal?anything=1`,
    `http://127.0.0.1:43180/${TOKEN}/vscodeLocal#anything`,
    `http://127.0.0.1:43180/${TOKEN}/vscodeLocal/`,
    `http://127.0.0.1:43180/${TOKEN}/vscodeLocal\n`
  ]) {
    const value = request();
    value.endpoints.vscodeLocal = endpoint;
    assert.throws(() => validateRequest(value));
  }
  for (const substitute of [TOKEN.replace(/^a/, 'b'), '43181']) {
    const value = request();
    value.endpoints.vscodeCopilot = value.endpoints.vscodeCopilot.replace(substitute.length === 64 ? TOKEN : '43180', substitute);
    assert.throws(() => validateRequest(value));
  }
});

test('request and receipt schemas reject arbitrary keys and unsafe previous values', () => {
  for (const value of [
    request({ version: 2 }), request({ nonce: NONCE.toUpperCase() + 'a' }), request({ hooks: 1 }),
    request({ operation: 'anything' }), request({ extra: true }), request({ expiresAt: 1.5 }),
    request({ endpoints: undefined })
  ]) assert.throws(() => validateRequest(value));
  for (const value of [
    { version: 1, settings: { 'arbitrary.key': { previous: { present: false }, installed: [true] } } },
    { version: 1, settings: { [`${LOCAL}.otlpEndpoint`]: { previous: { present: true, value: 'https://external' }, installed: [{ sha256: TOKEN }] } } },
    { version: 1, settings: { [`${LOCAL}.captureContent`]: { previous: { present: true, value: true }, installed: [false] } } },
    { version: 1, settings: {}, hook: { previous: { present: true, value: true }, installed: true } },
    { version: 1, settings: {}, unrelated: 'data' },
    JSON.parse('{"version":1,"settings":{"__proto__":{}}}')
  ]) assert.throws(() => validateReceipt(value));
});

test('only metrics configuration requires endpoints; supplied removal endpoints remain validated', () => {
  const removal = request({ operation: 'remove' });
  delete removal.endpoints;
  assert.equal(validateRequest(removal), removal);
  assert.throws(() => validateRequest({ ...removal, operation: 'configure' }));
  const endpoints = request().endpoints;
  for (const invalid of [
    null, {}, { vscodeLocal: endpoints.vscodeLocal },
    { ...endpoints, vscodeCopilot: endpoints.vscodeCopilot.replace(':43180/', ':0/') },
    { ...endpoints, vscodeLocal: endpoints.vscodeLocal.replace(TOKEN, 'b'.repeat(64)) }
  ]) assert.throws(() => validateRequest({ ...removal, endpoints: invalid }));
});

test('activation only registers public entry points and never reads or writes settings', async () => {
  const fake = fakeVSCode();
  fake.vscode.workspace.getConfiguration = () => assert.fail('activation must be inert');
  const filename = path.join(__dirname, '../src/extension.cjs');
  const code = await fs.readFile(filename, 'utf8');
  const module = { exports: {} };
  const requireLocal = createRequire(filename);
  vm.runInNewContext(code, { module, require: name => name === 'vscode' ? fake.vscode : requireLocal(name) }, { filename });
  const context = { subscriptions: [] };
  module.exports.activate(context);
  assert.equal(context.subscriptions.length, 4);
  assert.ok(fake.uriHandler);
  assert.deepEqual([...fake.registrations.keys()], [
    'tokenotch.configureLocalIntegration', 'tokenotch.removeOwnedConfiguration', 'tokenotch.checkIntegration'
  ]);
  assert.equal(fake.updates.length, 0);
  assert.equal(fake.messages.length, 0);
  const manifest = JSON.parse(await fs.readFile(path.join(__dirname, '../package.json'), 'utf8'));
  assert.equal(`${manifest.publisher}.${manifest.name}`, 'rottathiago.tokenotch-vscode');
  assert.deepEqual(manifest.extensionKind, ['ui']);
  assert.deepEqual(manifest.contributes.commands.map(item => item.command), [...fake.registrations.keys()]);
  assert.equal(manifest.scripts.package, 'vsce package --no-dependencies --out TokenotchVSCode.vsix');
  assert.equal(manifest.license, 'MIT');
});
