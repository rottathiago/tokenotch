'use strict';

const { randomBytes } = require('node:crypto');
const { fingerprint, keysExactly, SafeError, validateReceipt } = require('./contract.cjs');

const IDENTITY_KEY = 'tokenotch.receiptIdentity.v1';

class Ownership {
  constructor(vscode, context) {
    this.vscode = vscode;
    this.context = context;
  }

  current() {
    const { uriScheme, appRoot } = this.vscode.env;
    const { globalState, globalStorageUri } = this.context || {};
    if (!['vscode', 'vscode-insiders'].includes(uriScheme) || typeof appRoot !== 'string' || !appRoot ||
        typeof globalState?.get !== 'function' || typeof globalState?.update !== 'function' ||
        !['file', 'vscode-userdata'].includes(globalStorageUri?.scheme) ||
        typeof globalStorageUri.toString !== 'function') {
      throw new SafeError('identity');
    }
    const storage = globalStorageUri.toString();
    if (typeof storage !== 'string' || !storage.startsWith(`${globalStorageUri.scheme}:/`)) {
      throw new SafeError('identity');
    }
    const state = globalState.get(IDENTITY_KEY);
    if (state !== undefined && (!keysExactly(state, ['version', 'id']) || state.version !== 1 ||
        typeof state.id !== 'string' || !/^[0-9a-f]{64}$/.test(state.id))) {
      throw new SafeError('identity');
    }
    return {
      id: state?.id,
      scope: fingerprint(JSON.stringify(['tokenotch-profile-owner-v1', uriScheme, appRoot, storage]))
    };
  }

  verify(receipt, snapshot) {
    validateReceipt(receipt);
    const current = this.current();
    if (receipt.owner && (receipt.owner.id !== current.id || receipt.owner.scope !== current.scope)) {
      throw new SafeError('owner');
    }
    if (snapshot && (snapshot.id !== current.id || snapshot.scope !== current.scope)) {
      throw new SafeError('identity');
    }
    return current;
  }

  async bind(receipt, snapshot) {
    let current = this.verify(receipt, snapshot);
    if (!current.id) {
      const id = randomBytes(32).toString('hex');
      try {
        // This key is intentionally not registered for Settings Sync.
        await this.context.globalState.update(IDENTITY_KEY, { version: 1, id });
      } catch {
        throw new SafeError('identity');
      }
      const persisted = this.current();
      if (persisted.id !== id || persisted.scope !== current.scope) throw new SafeError('identity');
      current = persisted;
    }
    receipt.owner = current;
  }
}

module.exports = { Ownership, IDENTITY_KEY };
