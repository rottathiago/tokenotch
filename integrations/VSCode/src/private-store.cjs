'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const product = require('./product.cjs');
const {
  LIMIT, MESSAGES, SafeError, validateRequest, validateReceipt, fingerprint, hasOwnership
} = require('./contract.cjs');

const FILES = Object.freeze({
  request: 'vscode-setup-request.json',
  receipt: 'vscode-settings.receipt.json',
  result: 'vscode-setup-result.json',
  lock: 'vscode-setup.lock'
});

function sameFile(a, b) {
  return a.dev === b.dev && a.ino === b.ino;
}

class PrivateStore {
  constructor(home, uid = process.getuid?.()) {
    this.root = path.join(home, product.storageDirectory);
    this.uid = uid;
    this.identity = undefined;
  }

  async assertRoot() {
    let stat;
    try {
      stat = await fs.lstat(this.root);
      if (!stat.isDirectory() || stat.uid !== this.uid || (stat.mode & 0o7777) !== 0o700 ||
          await fs.realpath(this.root) !== this.root ||
          this.identity && !sameFile(stat, this.identity)) throw new SafeError('unsafe');
    } catch (error) {
      if (error instanceof SafeError) throw error;
      throw new SafeError('unsafe');
    }
    this.identity = stat;
  }

  assertFile(stat) {
    if (!stat.isFile() || stat.uid !== this.uid || (stat.mode & 0o7777) !== 0o600 ||
        stat.nlink !== 1 || stat.size > LIMIT) throw new SafeError('unsafe');
  }

  async readFile(name, optional = false) {
    await this.assertRoot();
    const target = path.join(this.root, name);
    let handle;
    try {
      let before;
      try {
        before = await fs.lstat(target);
      } catch (error) {
        if (optional && error.code === 'ENOENT') return undefined;
        throw error;
      }
      this.assertFile(before);
      handle = await fs.open(target, constants.O_RDONLY | constants.O_NOFOLLOW);
      const stat = await handle.stat();
      this.assertFile(stat);
      if (!sameFile(before, stat)) throw new SafeError('unsafe');
      const buffer = Buffer.alloc(LIMIT + 1);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      const after = await handle.stat();
      if (bytesRead > LIMIT || bytesRead !== stat.size || after.size !== stat.size ||
          after.mtimeMs !== stat.mtimeMs || after.ctimeMs !== stat.ctimeMs) throw new SafeError('unsafe');
      await this.assertRoot();
      const current = await fs.lstat(target);
      this.assertFile(current);
      if (!sameFile(stat, current)) throw new SafeError('unsafe');
      return { text: buffer.toString('utf8', 0, bytesRead), stat };
    } catch (error) {
      if (error instanceof SafeError) throw error;
      throw new SafeError(error.code === 'ENOENT' && name === FILES.request ? 'request' : 'unsafe');
    } finally {
      if (handle) await handle.close();
    }
  }

  parse(text, code) {
    try {
      return JSON.parse(text);
    } catch (error) {
      if (error instanceof SyntaxError) throw new SafeError(code);
      throw error;
    }
  }

  async readRequest() {
    const file = await this.readFile(FILES.request);
    return { ...file, value: validateRequest(this.parse(file.text, 'request')), digest: fingerprint(file.text) };
  }

  async readReceipt() {
    const file = await this.readFile(FILES.receipt, true);
    return file ? validateReceipt(this.parse(file.text, 'receipt')) : { version: 1, settings: {} };
  }

  async syncRoot() {
    await this.assertRoot();
    const directory = await fs.open(this.root, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try {
      if (!sameFile(await directory.stat(), this.identity)) throw new SafeError('unsafe');
      await directory.sync();
    } finally {
      await directory.close();
    }
  }

  async writeFile(name, value) {
    const data = Buffer.from(`${JSON.stringify(value)}\n`);
    if (data.length > LIMIT) throw new SafeError('failed', 'failed');
    await this.assertRoot();
    await this.readFile(name, true);
    const temp = path.join(this.root, `.vscode-tmp-${randomUUID()}`);
    let handle;
    let created = false;
    let renamed = false;
    try {
      handle = await fs.open(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      created = true;
      await handle.writeFile(data);
      await handle.sync();
      await handle.close();
      handle = undefined;
      await this.assertRoot();
      await this.readFile(name, true);
      await fs.rename(temp, path.join(this.root, name));
      renamed = true;
      await this.syncRoot();
    } finally {
      if (handle) await handle.close();
      if (created && !renamed) {
        await this.assertRoot();
        await fs.unlink(temp);
      }
    }
  }

  async saveReceipt(receipt) {
    validateReceipt(receipt);
    await this.writeFile(FILES.receipt, hasOwnership(receipt) ? receipt : { version: 1, settings: {} });
  }

  async writeResult(request, status, message) {
    if (!['configured', 'removed', 'cancelled', 'blocked', 'failed'].includes(status) ||
        !Object.values(MESSAGES).includes(message)) throw new SafeError('failed', 'failed');
    await this.writeFile(FILES.result, { version: 1, nonce: request.nonce, operation: request.operation, status, message });
  }

  async acquireLock() {
    await this.assertRoot();
    const target = path.join(this.root, FILES.lock);
    let handle;
    try {
      handle = await fs.open(target, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    } catch (error) {
      if (error.code === 'EEXIST') throw new SafeError('busy');
      throw new SafeError('unsafe');
    }
    const identity = await handle.stat();
    try {
      await handle.writeFile(JSON.stringify({ version: 1, pid: process.pid }));
      await handle.sync();
    } finally {
      await handle.close();
    }
    return async () => {
      await this.assertRoot();
      const current = await fs.lstat(target);
      this.assertFile(current);
      if (!sameFile(current, identity)) throw new SafeError('unsafe');
      await fs.unlink(target);
    };
  }

  async consume(original) {
    const current = await this.readRequest();
    if (!sameFile(current.stat, original.stat) || current.digest !== original.digest) throw new SafeError('changed');
    const claimed = `.vscode-consumed-${randomUUID()}`;
    await this.assertRoot();
    await fs.rename(path.join(this.root, FILES.request), path.join(this.root, claimed));
    // The rename is the replay boundary; never act on a request replaced during approval.
    try {
      const file = await this.readFile(claimed);
      if (!sameFile(file.stat, original.stat) || fingerprint(file.text) !== original.digest) throw new SafeError('changed');
    } finally {
      await this.assertRoot();
      await fs.unlink(path.join(this.root, claimed));
      await this.syncRoot();
    }
  }
}

module.exports = { PrivateStore, FILES, sameFile };
