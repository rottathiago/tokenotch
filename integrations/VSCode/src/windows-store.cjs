'use strict';

const { spawn, execFile } = require('node:child_process');
const { promisify } = require('node:util');
const path = require('node:path');
const { FILES } = require('./private-store.cjs');
const { LIMIT, SafeError, MESSAGES, validateRequest, validateReceipt, hasOwnership } = require('./contract.cjs');
const product = require('./product.cjs');

class WindowsStore {
  constructor(home) {
    this.root = path.join(home, product.storageDirectory);
    this.helper = path.join(this.root, 'TokenotchHook.exe');
  }

  async assertTrustedHelper() {
    // Validate the broker before executing it: Node's POSIX mode bits do not describe Windows ACLs.
    const literal = this.root.replaceAll("'", "''");
    const script = `$ErrorActionPreference='Stop'; $sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User;
      foreach($target in @('${literal}', '${literal}\\TokenotchHook.exe')) {
        $attributes=[IO.File]::GetAttributes($target);
        if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){exit 1}
        $acl=if(($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
          [IO.Directory]::GetAccessControl($target)
        } else { [IO.File]::GetAccessControl($target) };
        if($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $sid.Value){exit 1}
        $rules=$acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier]);
        if($rules.Count -eq 0){exit 1}
        foreach($rule in $rules){
          if($rule.IdentityReference.Value -ne $sid.Value -or $rule.AccessControlType -ne 'Allow'){exit 1}
        }
      }`;
    try {
      await promisify(execFile)(path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
        { windowsHide: true, timeout: 5000, maxBuffer: LIMIT });
    } catch {
      throw new SafeError('unsafe');
    }
  }

  async call(request) {
    await this.assertTrustedHelper();
    return new Promise((resolve, reject) => {
      const child = spawn(this.helper, ['--store'], { windowsHide: true, timeout: 5000, stdio: ['pipe', 'pipe', 'ignore'] });
      const chunks = [];
      let size = 0;
      const fail = () => reject(new SafeError(request.action === 'lock' ? 'busy' : 'unsafe'));
      child.on('error', fail);
      child.stdin.on('error', fail);
      child.stdout.on('data', chunk => {
        size += chunk.length;
        if (size > 4 * LIMIT) { child.kill(); fail(); } else chunks.push(chunk);
      });
      child.on('close', code => {
        if (code !== 0) return fail();
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { fail(); }
      });
      child.stdin.end(JSON.stringify(request));
    });
  }

  async assertRoot() { await this.call({ action: 'check' }); }
  async readRequest() {
    const file = await this.call({ action: 'read', name: FILES.request });
    if (!file) throw new SafeError('request');
    try { return { ...file, value: validateRequest(JSON.parse(file.text)) }; }
    catch (error) { if (error instanceof SafeError) throw error; throw new SafeError('request'); }
  }
  async readReceipt() {
    const file = await this.call({ action: 'read', name: FILES.receipt });
    if (!file) return { version: 1, settings: {} };
    try { return validateReceipt(JSON.parse(file.text)); }
    catch (error) { if (error instanceof SafeError) throw error; throw new SafeError('receipt'); }
  }
  async saveReceipt(receipt) {
    validateReceipt(receipt);
    await this.call({ action: 'write', name: FILES.receipt,
      value: hasOwnership(receipt) ? receipt : { version: 1, settings: {} } });
  }
  async writeResult(request, status, message) {
    if (!['configured', 'removed', 'cancelled', 'blocked', 'failed'].includes(status) ||
      !Object.values(MESSAGES).includes(message)) throw new SafeError('failed', 'failed');
    await this.call({ action: 'write', name: FILES.result,
      value: { version: 1, nonce: request.nonce, operation: request.operation, status, message } });
  }
  async acquireLock() {
    const token = await this.call({ action: 'lock' });
    return () => this.call({ action: 'unlock', token });
  }
  async consume(original) { await this.call({ action: 'consume', digest: original.digest }); }
}

module.exports = { WindowsStore };
