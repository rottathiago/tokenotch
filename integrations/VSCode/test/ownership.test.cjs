'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { Companion } = require('../src/companion.cjs');
const { PrivateStore, FILES } = require('../src/private-store.cjs');
const { Ownership, IDENTITY_KEY } = require('../src/ownership.cjs');
const { HOOK_KEY, HOOK_ENTRY, SOURCES, MESSAGES, validateReceipt, fingerprint } = require('../src/contract.cjs');
const { fixture, fakeVSCode, request, uri, NONCE } = require('./helpers.cjs');

function windowFor(f, fake = fakeVSCode()) {
  return {
    fake,
    companion: new Companion(fake.vscode, {
      store: new PrivateStore(f.home), context: fake.context, platform: 'darwin', environment: {}
    })
  };
}

async function receiptText(f) {
  return fs.readFile(path.join(f.root, FILES.receipt), 'utf8');
}

test('ownership is persisted in profile state after consent and receipt contains only opaque identity', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.consent = (_message, options, items) => {
    assert.equal(f.fake.stateUpdates.length, 0);
    assert.match(options.detail, /this window's user profile/);
    return items[0];
  };
  assert.equal((await f.companion.run()).status, 'configured');
  const { owner } = await f.read('receipt');
  assert.match(owner.id, /^[0-9a-f]{64}$/);
  assert.match(owner.scope, /^[0-9a-f]{64}$/);
  assert.deepEqual(f.fake.stateUpdates, [{ key: IDENTITY_KEY, value: { version: 1, id: owner.id } }]);
  assert.ok(!(await receiptText(f)).includes('/fake/'));
  assert.ok(!JSON.stringify(f.fake.messages).includes(owner.id));
  assert.ok(!JSON.stringify(await f.read('result')).includes(owner.id));
});

test('same installation/profile retains identity across companion restart, repeat setup and removal', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const original = await f.read('receipt');
  const { companion } = windowFor(f, f.fake);
  await f.write();
  assert.equal((await companion.run()).status, 'configured');
  assert.deepEqual(await f.read('receipt'), original);
  assert.equal(f.fake.stateUpdates.length, 1);
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: {} });
  assert.deepEqual(await f.read('receipt'), { version: 1, settings: {} });
});

test('existing file-URI ownership keeps its original scope fingerprint', async t => {
  const f = await fixture(t);
  const storage = 'file:///fake/user/globalStorage/rottathiago.tokenotch-vscode';
  f.fake.context.globalStorageUri = { scheme: 'file', toString: () => storage };
  const owner = {
    id: NONCE,
    scope: fingerprint(JSON.stringify(['tokenotch-profile-owner-v1',
      f.fake.vscode.env.uriScheme, f.fake.vscode.env.appRoot, storage]))
  };
  f.fake.stateValues.set(IDENTITY_KEY, { version: 1, id: owner.id });
  const receipt = { version: 1, settings: {}, owner };
  const ownership = new Ownership(f.fake.vscode, f.fake.context);
  assert.deepEqual(ownership.verify(receipt), owner);
  await f.store.saveReceipt(receipt);
  await f.write(request({ metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.deepEqual((await f.read('receipt')).owner, owner);
  assert.equal(f.fake.stateUpdates.length, 0);
  await f.write(request({ operation: 'remove', metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
});

for (const [scheme, storage] of [
  ['https', 'https://example.invalid/storage'],
  ['vscode-remote', 'vscode-remote://ssh-remote/storage'],
  ['vscode-userdata', 'file:///fake/user/globalStorage'],
  ['file', 'vscode-userdata:/fake/user/globalStorage'],
  ['vscode-userdata', 'vscode-userdata:relative'],
  ['vscode-userdata', undefined]
]) {
  test(`unsupported or mismatched storage URI ${scheme} / ${storage} is rejected`, async t => {
    const f = await fixture(t);
    f.fake.context.globalStorageUri = { scheme, toString: () => storage };
    await f.write();
    assert.equal((await f.companion.run()).message, MESSAGES.identity);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.fake.stateUpdates.length, 0);
    assert.equal(f.fake.messages.some(item => item.options?.modal), false);
    await assert.rejects(fs.access(path.join(f.root, FILES.receipt)));
  });
}

test('changing storage URI scheme cannot reuse an existing owner', async t => {
  const f = await fixture(t);
  await f.write();
  assert.equal((await f.companion.run()).status, 'configured');
  const original = await receiptText(f);
  const writes = f.fake.updates.length;
  f.fake.context.globalStorageUri = {
    scheme: 'file', toString: () => 'file:///fake/user/globalStorage/rottathiago.tokenotch-vscode'
  };
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run()).message, MESSAGES.owner);
  assert.equal(f.fake.updates.length, writes);
  assert.equal(await receiptText(f), original);
});

test('another profile cannot configure, remove or reinterpret receipt despite identical current values', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const original = await receiptText(f);
  const other = windowFor(f);
  Object.assign(other.fake.globals, structuredClone(f.fake.globals));
  const globals = structuredClone(other.fake.globals);
  for (const operation of ['configure', 'remove']) {
    await f.write(request({ operation }));
    assert.equal((await other.companion.run({ uri: uri() })).message, MESSAGES.owner);
    assert.equal((await f.read('result')).status, 'blocked');
    assert.equal(await receiptText(f), original);
    assert.ok(await f.read('request'));
  }
  assert.equal((await other.companion.check()).message, MESSAGES.owner);
  assert.deepEqual(other.fake.globals, globals);
  assert.equal(other.fake.updates.length, 0);
  assert.equal(other.fake.stateUpdates.length, 0);
  assert.equal(other.fake.messages.some(item => item.options?.modal), false);
});

for (const scope of ['installation', 'storage', 'scheme']) {
  test(`copied profile marker cannot authorize a different ${scope}`, async t => {
    const f = await fixture(t);
    await f.write();
    await f.companion.run();
    const original = await receiptText(f);
    const other = windowFor(f);
    other.fake.stateValues.set(IDENTITY_KEY, structuredClone(f.fake.stateValues.get(IDENTITY_KEY)));
    Object.assign(other.fake.globals, structuredClone(f.fake.globals));
    if (scope === 'installation') other.fake.vscode.env.appRoot = '/fake/Other Code.app/Contents/Resources/app';
    if (scope === 'storage') other.fake.context.globalStorageUri.toString = () => 'vscode-userdata:/fake/user/profiles/other/globalStorage/rottathiago.tokenotch-vscode';
    if (scope === 'scheme') other.fake.vscode.env.uriScheme = 'vscode-insiders';
    await f.write(request({ operation: 'remove', endpoints: undefined }));
    assert.equal((await other.companion.run({ uri: uri(NONCE, other.fake.vscode.env.uriScheme) })).message, MESSAGES.owner);
    assert.equal(other.fake.updates.length, 0);
    assert.equal(await receiptText(f), original);
  });
}

test('partial removal keeps profile binding; full removal permits deliberate pairing of another profile', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const owner = (await f.read('receipt')).owner;
  await f.write(request({ operation: 'remove', hooks: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual((await f.read('receipt')).owner, owner);
  const other = windowFor(f);
  await f.write(request({ metrics: false, endpoints: undefined }));
  assert.equal((await other.companion.run()).message, MESSAGES.owner);
  await f.write(request({ operation: 'remove', metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(await f.read('receipt'), { version: 1, settings: {} });
  await f.write(request({ metrics: false, endpoints: undefined }));
  assert.equal((await other.companion.run()).status, 'configured');
  assert.notEqual((await f.read('receipt')).owner.id, owner.id);
  assert.deepEqual(other.fake.globals, { [HOOK_KEY]: { [HOOK_ENTRY]: true } });
});

test('partial installation can only be undone by its owning profile', async t => {
  const f = await fixture(t);
  f.fake.beforeUpdate = key => {
    if (key === `${SOURCES.vscodeLocal}.protocol`) throw new Error('injected failure');
  };
  await f.write();
  assert.equal((await f.companion.run()).status, 'failed');
  const original = await receiptText(f);
  const other = windowFor(f);
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await other.companion.run()).message, MESSAGES.owner);
  assert.equal(await receiptText(f), original);
  assert.equal(other.fake.updates.length, 0);
  f.fake.beforeUpdate = undefined;
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, {});
});

for (const operation of ['configure', 'remove']) {
  test(`legacy nonempty receipt without profile identity blocks ${operation} without adoption`, async t => {
    const f = await fixture(t);
    const legacy = { version: 1, settings: {}, hook: { previous: { present: false }, installed: true } };
    await fs.writeFile(path.join(f.root, FILES.receipt), JSON.stringify(legacy), { mode: 0o600 });
    f.fake.globals[HOOK_KEY] = { [HOOK_ENTRY]: true };
    await f.write(request({ operation, metrics: false, endpoints: undefined }));
    assert.equal((await f.companion.run()).message, MESSAGES.unbound);
    assert.deepEqual(await f.read('receipt'), legacy);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.fake.stateUpdates.length, 0);
  });
}

test('legacy empty receipt can be safely bound after approval because it owns no fields', async t => {
  const f = await fixture(t);
  await f.store.saveReceipt({ version: 1, settings: {} });
  await f.write(request({ metrics: false, endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'configured');
  assert.ok((await f.read('receipt')).owner);
});

test('missing profile marker never silently replaces the owner of an existing receipt', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const original = await receiptText(f);
  const writes = f.fake.updates.length;
  f.fake.stateValues.delete(IDENTITY_KEY);
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run()).message, MESSAGES.owner);
  assert.equal(f.fake.updates.length, writes);
  assert.equal(await receiptText(f), original);
  assert.equal(f.fake.stateUpdates.length, 1);
});

for (const missing of ['appRoot', 'storage', 'globalState', 'uriScheme']) {
  test(`missing public identity component ${missing} fails closed before consent or writes`, async t => {
    const f = await fixture(t);
    if (missing === 'appRoot') delete f.fake.vscode.env.appRoot;
    if (missing === 'uriScheme') delete f.fake.vscode.env.uriScheme;
    if (missing === 'storage') delete f.fake.context.globalStorageUri;
    if (missing === 'globalState') delete f.fake.context.globalState;
    await f.write();
    assert.equal((await f.companion.run()).message, MESSAGES.identity);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.fake.messages.some(item => item.options?.modal), false);
    await assert.rejects(fs.access(path.join(f.root, FILES.receipt)));
  });
}

test('failed profile-state persistence prevents request consumption and all settings changes', async t => {
  const f = await fixture(t);
  f.fake.context.globalState.update = async () => { throw new Error('private state error'); };
  await f.write();
  assert.equal((await f.companion.run()).message, MESSAGES.identity);
  assert.equal(f.fake.updates.length, 0);
  assert.ok(await f.read('request'));
  await assert.rejects(fs.access(path.join(f.root, FILES.receipt)));
  assert.ok(!JSON.stringify(f.fake.messages).includes('private state error'));
});

test('unsuccessful profile-state persistence is not treated as a valid binding', async t => {
  const f = await fixture(t);
  f.fake.context.globalState.update = async () => {};
  await f.write();
  assert.equal((await f.companion.run()).message, MESSAGES.identity);
  assert.equal(f.fake.updates.length, 0);
  assert.ok(await f.read('request'));
});

test('profile identity changes during consent invalidate approval', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.consent = (_message, _options, items) => {
    f.fake.context.globalStorageUri.toString = () => 'vscode-userdata:/fake/switched-profile/globalStorage/rottathiago.tokenotch-vscode';
    return items[0];
  };
  assert.equal((await f.companion.run()).message, MESSAGES.identity);
  assert.equal(f.fake.updates.length, 0);
  assert.equal(f.fake.stateUpdates.length, 0);
  assert.ok(await f.read('request'));
});

test('profile change during receipt persistence blocks the following settings write', async t => {
  const f = await fixture(t);
  await f.write();
  const storage = f.fake.context.globalStorageUri.toString;
  const save = f.store.saveReceipt.bind(f.store);
  f.store.saveReceipt = async receipt => {
    await save(receipt);
    f.fake.context.globalStorageUri.toString = () => 'vscode-userdata:/fake/other-profile/globalStorage/rottathiago.tokenotch-vscode';
  };
  assert.equal((await f.companion.run()).message, MESSAGES.owner);
  assert.equal(f.fake.updates.length, 0);
  assert.ok((await f.read('receipt')).owner);
  f.fake.context.globalStorageUri.toString = storage;
  f.store.saveReceipt = save;
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, {});
});

test('identity change during removal leaves the recovery journal intact and stops subsequent updates', async t => {
  const f = await fixture(t);
  await f.write();
  await f.companion.run();
  const original = await receiptText(f);
  const marker = f.fake.stateValues.get(IDENTITY_KEY);
  const writes = f.fake.updates.length;
  f.fake.afterUpdate = () => {
    f.fake.stateValues.set(IDENTITY_KEY, { version: 1, id: 'f'.repeat(64) });
  };
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run()).message, MESSAGES.owner);
  assert.equal(f.fake.updates.length, writes + 1);
  assert.equal(await receiptText(f), original);
  f.fake.stateValues.set(IDENTITY_KEY, marker);
  f.fake.afterUpdate = undefined;
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run()).status, 'removed');
  assert.deepEqual(f.fake.globals, { [HOOK_KEY]: {} });
});

test('cancellation and diagnostics do not create profile state or adopt a receipt', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.consent = () => undefined;
  assert.equal((await f.companion.run()).status, 'cancelled');
  await f.companion.check();
  assert.equal(f.fake.stateUpdates.length, 0);
  await assert.rejects(fs.access(path.join(f.root, FILES.receipt)));
});

test('malformed owner or stored profile identity is rejected rather than regenerated', async t => {
  const f = await fixture(t);
  for (const owner of [null, {}, { id: NONCE, scope: NONCE, profileName: 'unknown' }, { id: 'bad', scope: NONCE }]) {
    assert.throws(() => validateReceipt({ version: 1, settings: {}, owner }));
  }
  f.fake.stateValues.set(IDENTITY_KEY, { version: 2, id: NONCE });
  await f.write();
  assert.equal((await f.companion.run()).message, MESSAGES.identity);
  assert.equal(f.fake.stateUpdates.length, 0);
  assert.equal(f.fake.updates.length, 0);
});

test('Insiders setup and endpoint-free removal use the selected app scheme', async t => {
  const f = await fixture(t);
  f.fake.vscode.env.uriScheme = 'vscode-insiders';
  f.fake.vscode.env.appRoot = '/fake/Visual Studio Code - Insiders.app/Contents/Resources/app';
  await f.write();
  assert.equal((await f.companion.run({ uri: uri(NONCE, 'vscode-insiders') })).status, 'configured');
  await f.write(request({ operation: 'remove', endpoints: undefined }));
  assert.equal((await f.companion.run({ uri: uri(NONCE, 'vscode-insiders') })).status, 'removed');
});

for (const scheme of ['vscode', 'vscode-insiders']) {
  test(`${scheme} rejects a link for the other installation before reading the private request`, async t => {
    const f = await fixture(t);
    f.fake.vscode.env.uriScheme = scheme;
    f.store.readRequest = () => assert.fail('must not read another application link');
    const otherScheme = scheme === 'vscode' ? 'vscode-insiders' : 'vscode';
    assert.equal((await f.companion.run({ uri: uri(NONCE, otherScheme) })).message, MESSAGES.nonce);
    assert.equal(f.fake.updates.length, 0);
    assert.equal(f.fake.stateUpdates.length, 0);
    assert.deepEqual(await fs.readdir(f.root), []);
  });
}
