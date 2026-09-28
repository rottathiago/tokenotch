'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { PrivateStore, FILES } = require('../src/private-store.cjs');
const { Companion } = require('../src/companion.cjs');
const { SETTING_RULES, HOOK_KEY } = require('../src/contract.cjs');

const NONCE = '1'.repeat(64);
const TOKEN = 'a'.repeat(64);

function request(overrides = {}) {
  return {
    version: 1, nonce: NONCE, expiresAt: Math.floor(Date.now() / 1000) + 300,
    operation: 'configure', hooks: true, metrics: true,
    endpoints: {
      vscodeLocal: `http://127.0.0.1:43180/${TOKEN}/vscodeLocal`,
      vscodeCopilot: `http://127.0.0.1:43180/${TOKEN}/vscodeCopilot`
    },
    ...overrides
  };
}

function uri(nonce = NONCE, scheme = 'vscode') {
  return { scheme, authority: 'rottathiago.tokenotch-vscode', path: '/setup', query: `nonce=${nonce}`, fragment: '' };
}

function fakeVSCode() {
  const defaults = { [HOOK_KEY]: {}, 'telemetry.telemetryLevel': 'all' };
  for (const [key, rule] of Object.entries(SETTING_RULES)) {
    defaults[key] = rule.endpoint ? 'http://localhost:4318' :
      key.endsWith('.enabled') ? false : key.endsWith('.exporterType') ? 'console' :
        key.endsWith('.protocol') ? 'grpc' : rule.value;
  }
  const globals = {};
  const workspace = {};
  const effective = {};
  const unsupported = new Set();
  const updates = [];
  const messages = [];
  const executions = [];
  const registrations = new Map();
  const stateValues = new Map();
  const stateUpdates = [];
  const context = {
    globalState: {
      get(key) { return structuredClone(stateValues.get(key)); },
      async update(key, value) {
        stateUpdates.push({ key, value: structuredClone(value) });
        stateValues.set(key, structuredClone(value));
      }
    },
    globalStorageUri: {
      scheme: 'vscode-userdata',
      toString: () => 'vscode-userdata:/fake/user/globalStorage/rottathiago.tokenotch-vscode'
    }
  };
  const configuration = {
    inspect(key) {
      if (unsupported.has(key) || !Object.hasOwn(defaults, key)) return undefined;
      return {
        key, defaultValue: structuredClone(defaults[key]),
        globalValue: structuredClone(globals[key]), workspaceValue: structuredClone(workspace[key])
      };
    },
    get(key) {
      if (Object.hasOwn(effective, key)) return structuredClone(effective[key]);
      if (Object.hasOwn(workspace, key)) {
        if (key === HOOK_KEY) return { ...defaults[key], ...globals[key], ...workspace[key] };
        return structuredClone(workspace[key]);
      }
      return structuredClone(Object.hasOwn(globals, key) ? globals[key] : defaults[key]);
    },
    async update(key, value, target) {
      updates.push({ key, value: structuredClone(value), target });
      if (state.beforeUpdate) await state.beforeUpdate(key, value);
      if (value === undefined) delete globals[key];
      else globals[key] = structuredClone(value);
      if (state.afterUpdate) await state.afterUpdate(key, value);
    }
  };
  const disposable = () => ({ dispose() {} });
  const vscode = {
    env: { uriScheme: 'vscode', appRoot: '/fake/Visual Studio Code.app/Contents/Resources/app' },
    ConfigurationTarget: { Global: 1 },
    workspace: { workspaceFolders: [], getConfiguration: () => configuration },
    window: {
      async showInformationMessage(message, options, ...items) {
        messages.push({ message, options, items });
        if (options?.modal) return state.consent ? state.consent(message, options, items) : items[0];
        return state.reload ? 'Reload Window' : undefined;
      },
      async showErrorMessage(message, options) { messages.push({ message, options }); },
      registerUriHandler(handler) { state.uriHandler = handler; return disposable(); }
    },
    commands: {
      registerCommand(name, callback) { registrations.set(name, callback); return disposable(); },
      async executeCommand(...args) { executions.push(args); }
    }
  };
  const state = {
    vscode, configuration, defaults, globals, workspace, effective, unsupported, updates, messages, executions, registrations,
    context, stateValues, stateUpdates
  };
  return state;
}

async function fixture(t, options = {}) {
  const home = await fs.mkdtemp(path.join(__dirname, '.tmp-'));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  const root = path.join(home, '.tokenotch');
  await fs.mkdir(root, { mode: 0o700 });
  const fake = fakeVSCode();
  const store = new PrivateStore(home);
  const companion = new Companion(fake.vscode, { home, store, context: fake.context, platform: 'darwin', environment: {}, ...options });
  async function write(value = request()) {
    await fs.writeFile(path.join(root, FILES.request), JSON.stringify(value), { mode: 0o600 });
    return value;
  }
  async function read(name) { return JSON.parse(await fs.readFile(path.join(root, FILES[name]), 'utf8')); }
  return { home, root, fake, store, companion, write, read };
}

module.exports = { NONCE, TOKEN, request, uri, fakeVSCode, fixture };
