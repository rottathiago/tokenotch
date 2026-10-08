'use strict';

const { createHash } = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const product = require('./product.cjs');

const LIMIT = 16 * 1024;
const HOOK_KEY = 'chat.hookFilesLocations';
const HOOK_ENTRY = `~/${product.storageDirectory}/vscode-hooks`;
const SOURCES = Object.freeze({
  vscodeLocal: 'github.copilot.chat.otel',
  vscodeCopilot: 'chat.agentHost.otel'
});
const SETTING_RULES = Object.freeze(Object.fromEntries(
  Object.entries(SOURCES).flatMap(([source, prefix]) => [
    [`${prefix}.enabled`, { source, value: true }],
    [`${prefix}.exporterType`, { source, value: 'otlp-http' }],
    ...source === 'vscodeLocal' ? [[`${prefix}.protocol`, { source, value: 'http/json' }]] : [],
    [`${prefix}.otlpEndpoint`, { source, endpoint: true }],
    [`${prefix}.captureContent`, { source, value: false }]
  ])
));
const MESSAGES = Object.freeze({
  configured: 'Tokenotch settings are configured. Reload may be needed; actual telemetry delivery must be verified in Tokenotch.',
  removed: 'Requested Tokenotch-owned settings were removed or restored. User-edited settings were preserved; a reload may be needed.',
  cancelled: 'Tokenotch setup was cancelled. No settings were changed.',
  remote: 'Tokenotch setup is local-only. Open a local macOS or Windows VS Code window.',
  request: 'No valid private setup request is available. Create a new request in Tokenotch.',
  expired: 'The Tokenotch setup request expired or is not fresh. Create a new request in Tokenotch.',
  nonce: 'The setup link does not match the private Tokenotch request. Create a new request in Tokenotch.',
  unsafe: 'Tokenotch private storage is unsafe or unavailable. Repair its ownership and permissions in Tokenotch before retrying.',
  receipt: 'The Tokenotch ownership receipt is invalid. Restore a valid receipt before changing settings.',
  unbound: 'The Tokenotch receipt has no verifiable profile owner. Restore a profile-bound receipt or manually resolve the original integration before resetting its receipt.',
  owner: 'This window cannot prove ownership of the Tokenotch receipt. Use the original VS Code installation/profile with its extension state intact to remove it before pairing this one.',
  identity: 'Tokenotch cannot verify this window\'s installation/profile identity. Restore its extension state or use the original supported local VS Code window before retrying.',
  unsupported: 'Required public settings are unavailable. Enable or update the relevant VS Code components and retry.',
  telemetry: 'VS Code telemetry is off. Review your telemetry preference before enabling Tokenotch metrics.',
  environment: 'OTel environment overrides were detected. Remove conflicting overrides at their source, then fully quit and reopen VS Code before retrying.',
  conflict: 'Existing collector, capture, or overriding settings conflict with Tokenotch. Review them manually; they were not replaced.',
  busy: 'Another Tokenotch setup may be running. Finish it before retrying; see the companion documentation for stale-lock recovery.',
  changed: 'The private request or settings changed during approval. Create a new request in Tokenotch and retry.',
  effective: 'Public effective settings do not match the approved setup. Changes remain reversible; resolve overrides before retrying.',
  failed: 'Tokenotch could not finish updating settings. Any partial changes remain recorded for safe removal; retry from Tokenotch.',
  resultFailed: 'Tokenotch could not write the private setup result. Check private storage in Tokenotch before retrying.'
});

class SafeError extends Error {
  constructor(code, status = 'blocked') {
    super(MESSAGES[code]);
    this.code = code;
    this.status = status;
  }
}

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function keysExactly(value, required, optional = []) {
  return object(value) && required.every(key => Object.hasOwn(value, key)) &&
    Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}

function endpointParts(value, source) {
  if (typeof value !== 'string' || !Object.hasOwn(SOURCES, source)) return undefined;
  const match = new RegExp(`^http://127\\.0\\.0\\.1:([1-9][0-9]{0,4})/([0-9a-f]{64})/${source}$`).exec(value);
  if (!match || Number(match[1]) > 65535) return undefined;
  return { port: match[1], token: match[2] };
}

function validateRequest(value) {
  if (!keysExactly(value, ['version', 'nonce', 'expiresAt', 'operation', 'hooks', 'metrics'], ['endpoints']) ||
      value.version !== 1 || typeof value.nonce !== 'string' || !/^[0-9a-f]{64}$/.test(value.nonce) ||
      !Number.isSafeInteger(value.expiresAt) ||
      !['configure', 'remove'].includes(value.operation) ||
      typeof value.hooks !== 'boolean' || typeof value.metrics !== 'boolean') {
    throw new SafeError('request');
  }
  if (value.operation === 'configure' && value.metrics || Object.hasOwn(value, 'endpoints')) {
    if (!keysExactly(value.endpoints, Object.keys(SOURCES))) throw new SafeError('request');
    const local = endpointParts(value.endpoints.vscodeLocal, 'vscodeLocal');
    const copilot = endpointParts(value.endpoints.vscodeCopilot, 'vscodeCopilot');
    if (!local || !copilot || local.port !== copilot.port || local.token !== copilot.token) {
      throw new SafeError('request');
    }
  }
  return value;
}

function assertFresh(request, stat, now = Date.now()) {
  const seconds = now / 1000;
  if (request.expiresAt <= seconds || request.expiresAt > seconds + 600 ||
      stat.mtimeMs < now - 600000 || stat.mtimeMs > now + 5000) {
    throw new SafeError('expired');
  }
}

function fingerprint(value) {
  return createHash('sha256').update(value).digest('hex');
}

function installedValue(key, value) {
  return SETTING_RULES[key].endpoint ? { sha256: fingerprint(value) } : value;
}

function matchesInstalled(key, value, installed) {
  if (SETTING_RULES[key].endpoint) {
    return typeof value === 'string' && installed.some(item => item.sha256 === fingerprint(value));
  }
  return installed.some(item => isDeepStrictEqual(item, value));
}

function previous(value) {
  return value === undefined ? { present: false } : { present: true, value };
}

function previousValue(saved) {
  return saved.present ? saved.value : undefined;
}

function validPrevious(saved, validate) {
  return keysExactly(saved, ['present'], ['value']) && typeof saved.present === 'boolean' &&
    (saved.present ? Object.hasOwn(saved, 'value') && validate(saved.value) : !Object.hasOwn(saved, 'value'));
}

function hasOwnership(receipt) {
  return Object.keys(receipt.settings).length > 0 || Object.hasOwn(receipt, 'hook');
}

function validateReceipt(value) {
  if (!keysExactly(value, ['version', 'settings'], ['hook', 'owner']) || value.version !== 1 || !object(value.settings)) {
    throw new SafeError('receipt');
  }
  for (const [key, entry] of Object.entries(value.settings)) {
    const rule = Object.hasOwn(SETTING_RULES, key) && SETTING_RULES[key];
    if (!rule || !keysExactly(entry, ['previous', 'installed']) ||
        !validPrevious(entry.previous, item => rule.endpoint ? item === '' :
          typeof rule.value === 'boolean' ? item === false : item === rule.value || item === '') ||
        !Array.isArray(entry.installed) || entry.installed.length < 1 || entry.installed.length > 2 ||
        !entry.installed.every(item => rule.endpoint ?
          keysExactly(item, ['sha256']) && typeof item.sha256 === 'string' && /^[0-9a-f]{64}$/.test(item.sha256) :
          item === rule.value)) {
      throw new SafeError('receipt');
    }
  }
  if (Object.hasOwn(value, 'hook') &&
      (!keysExactly(value.hook, ['previous', 'installed']) || value.hook.installed !== true ||
        !validPrevious(value.hook.previous, item => item === false))) {
    throw new SafeError('receipt');
  }
  if (Object.hasOwn(value, 'owner')) {
    if (!keysExactly(value.owner, ['id', 'scope']) ||
        !Object.values(value.owner).every(item => typeof item === 'string' && /^[0-9a-f]{64}$/.test(item))) {
      throw new SafeError('receipt');
    }
  } else if (hasOwnership(value)) {
    throw new SafeError('unbound');
  }
  return value;
}

function uriNonce(uri, scheme = 'vscode') {
  if (!['vscode', 'vscode-insiders'].includes(scheme) || !uri || uri.scheme !== scheme || uri.authority !== `${product.publisher}.${product.companionName}` ||
      uri.path !== '/setup' || uri.fragment) throw new SafeError('nonce');
  const query = new URLSearchParams(uri.query);
  if ([...query].length !== 1 || !/^[0-9a-f]{64}$/.test(query.get('nonce') || '')) {
    throw new SafeError('nonce');
  }
  return query.get('nonce');
}

module.exports = {
  LIMIT, HOOK_KEY, HOOK_ENTRY, SOURCES, SETTING_RULES, MESSAGES, SafeError,
  object, keysExactly, endpointParts, validateRequest, assertFresh, fingerprint,
  installedValue, matchesInstalled, previous, previousValue, hasOwnership, validateReceipt, uriNonce
};
