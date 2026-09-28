'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { PrivateStore, FILES } = require('../src/private-store.cjs');
const { LIMIT, MESSAGES } = require('../src/contract.cjs');
const { fixture, request, TOKEN } = require('./helpers.cjs');

for (const mode of [0o755, 0o770, 0o1700]) {
  test(`unsafe root mode ${mode.toString(8)} prevents all writes`, async t => {
    const f = await fixture(t);
    await f.write();
    await fs.chmod(f.root, mode);
    assert.equal((await f.companion.run()).message, MESSAGES.unsafe);
    assert.deepEqual(await fs.readdir(f.root), [FILES.request]);
  });
}

test('root symlink and symlinked ancestor are rejected without writing to targets', async t => {
  const f = await fixture(t);
  const target = path.join(f.home, 'actual');
  await fs.rename(f.root, target);
  await fs.symlink(target, f.root);
  assert.equal((await f.companion.run()).message, MESSAGES.unsafe);
  assert.deepEqual(await fs.readdir(target), []);
  const linkedHome = path.join(f.home, 'linked-home');
  await fs.symlink(f.home, linkedHome);
  const store = new PrivateStore(linkedHome);
  await assert.rejects(store.assertRoot());
});

test('wrong root owner is rejected', async t => {
  const f = await fixture(t);
  const store = new PrivateStore(f.home, process.getuid() + 1);
  await assert.rejects(store.assertRoot());
  assert.deepEqual(await fs.readdir(f.root), []);
});

for (const kind of ['symlink', 'hardlink', 'directory', 'readable', 'oversized']) {
  test(`unsafe ${kind} request is never followed or consumed`, async t => {
    const f = await fixture(t);
    const target = path.join(f.root, FILES.request);
    if (kind === 'symlink' || kind === 'hardlink') {
      const original = path.join(f.home, 'original.json');
      await fs.writeFile(original, JSON.stringify(request()), { mode: 0o600 });
      if (kind === 'symlink') await fs.symlink(original, target);
      else await fs.link(original, target);
    } else if (kind === 'directory') await fs.mkdir(target, { mode: 0o700 });
    else if (kind === 'readable') {
      await f.write();
      await fs.chmod(target, 0o644);
    } else await fs.writeFile(target, ' '.repeat(LIMIT + 1), { mode: 0o600 });
    assert.equal((await f.companion.run()).status, 'blocked');
    assert.equal(f.fake.updates.length, 0);
    assert.deepEqual(await fs.readdir(f.root), [FILES.request]);
    assert.ok(await fs.lstat(target));
  });
}

test('unsafe receipt symlink blocks mutations without modifying its target', async t => {
  const f = await fixture(t);
  await f.write();
  const target = path.join(f.home, 'receipt-target');
  await fs.writeFile(target, 'do not touch', { mode: 0o600 });
  await fs.symlink(target, path.join(f.root, FILES.receipt));
  assert.equal((await f.companion.run()).status, 'blocked');
  assert.equal(f.fake.updates.length, 0);
  assert.equal(await fs.readFile(target, 'utf8'), 'do not touch');
});

test('result symlink is not followed; result persistence failure is explicit', async t => {
  const f = await fixture(t);
  await f.write();
  f.fake.consent = () => undefined;
  const target = path.join(f.home, 'result-target');
  await fs.writeFile(target, 'do not touch', { mode: 0o600 });
  await fs.symlink(target, path.join(f.root, FILES.result));
  assert.equal((await f.companion.run()).message, MESSAGES.resultFailed);
  assert.equal(await fs.readFile(target, 'utf8'), 'do not touch');
  assert.equal(f.fake.updates.length, 0);
});

for (const contents of ['{', ' '.repeat(LIMIT + 1), '{"version":1,"settings":{"arbitrary.setting":{}}}']) {
  test(`invalid receipt (${contents.length} bytes) cannot authorize settings edits`, async t => {
    const f = await fixture(t);
    await f.write(request({ operation: 'remove' }));
    await fs.writeFile(path.join(f.root, FILES.receipt), contents, { mode: 0o600 });
    assert.equal((await f.companion.run()).status, 'blocked');
    assert.equal(f.fake.updates.length, 0);
  });
}

test('safe atomic writes replace receipt inode and leave no temporary files', async t => {
  const f = await fixture(t);
  await f.store.saveReceipt({ version: 1, settings: {} });
  const before = await fs.lstat(path.join(f.root, FILES.receipt));
  await f.store.saveReceipt({ version: 1, settings: {} });
  const after = await fs.lstat(path.join(f.root, FILES.receipt));
  assert.notEqual(before.ino, after.ino);
  assert.equal(after.mode & 0o7777, 0o600);
  assert.deepEqual(await fs.readdir(f.root), [FILES.receipt]);
});

test('request inode replacement with identical contents cannot reuse approval', async t => {
  const f = await fixture(t);
  await f.write();
  const original = await f.store.readRequest();
  const replacement = path.join(f.root, 'replacement');
  await fs.writeFile(replacement, original.text, { mode: 0o600 });
  await fs.rename(replacement, path.join(f.root, FILES.request));
  await assert.rejects(f.store.consume(original), error => error.message === MESSAGES.changed);
  assert.ok(await f.read('request'));
});

test('root replacement after initial validation is rejected', async t => {
  const f = await fixture(t);
  await f.store.assertRoot();
  await fs.rename(f.root, path.join(f.home, 'old-root'));
  await fs.mkdir(f.root, { mode: 0o700 });
  await assert.rejects(f.store.saveReceipt({ version: 1, settings: {} }));
  assert.deepEqual(await fs.readdir(f.root), []);
});

test('output schema accepts only fixed safe messages', async t => {
  const f = await fixture(t);
  await assert.rejects(f.store.writeResult(request(), 'failed', `raw error ${TOKEN}`));
  await assert.rejects(f.store.writeResult(request(), 'unexpected', MESSAGES.failed));
  assert.deepEqual(await fs.readdir(f.root), []);
});
