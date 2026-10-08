'use strict';

const { isDeepStrictEqual: equal } = require('node:util');
const {
  HOOK_KEY, HOOK_ENTRY, SOURCES, SETTING_RULES, SafeError, object,
  endpointParts, installedValue, matchesInstalled, previous, previousValue, validateReceipt
} = require('./contract.cjs');

const OVERRIDES = ['workspaceValue', 'workspaceFolderValue', 'defaultLanguageValue',
  'globalLanguageValue', 'workspaceLanguageValue', 'workspaceFolderLanguageValue'];
const CAPTURE_SUFFIXES = ['outfile', 'outFile', 'fileExporterPath', 'filePath',
  'dbSpanExporter.enabled', 'dbSpanExporterEnabled', 'captureMessages'];

function hasDiscardOnlyExporter(environment, platform = process.platform) {
  // Copilot sets this SDK opt-out marker in the shared extension host after resolving its own OTel config.
  return environment.COPILOT_OTEL_FILE_EXPORTER_PATH === (platform === 'win32' ? '\\\\.\\nul' : '/dev/null');
}

function normalizedEndpoint(value) {
  if (typeof value !== 'string' || value === '') return undefined;
  try {
    return new URL(value.replace(/^["']|["']$/g, '')).href;
  } catch {
    return undefined;
  }
}

// Once its OTel setting is explicitly enabled, Copilot Chat mirrors these exact values from its own settings into the
// shared extension host. Values that differ from the current settings still come from elsewhere and are reported.
function isCopilotSettingsMirror(key, value, configuration) {
  if (!configuration || configuration.get(`${SOURCES.vscodeLocal}.enabled`) !== true) return false;
  switch (key) {
    case 'COPILOT_OTEL_ENABLED': return value === 'true';
    case 'OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT':
      return value === 'false' && configuration.get(`${SOURCES.vscodeLocal}.captureContent`) !== true;
    case 'OTEL_EXPORTER_OTLP_ENDPOINT': {
      const endpoint = normalizedEndpoint(configuration.get(`${SOURCES.vscodeLocal}.otlpEndpoint`));
      return endpoint !== undefined && value === endpoint;
    }
    default: return false;
  }
}

function environmentOverrideNames(environment, configuration, platform = process.platform) {
  return Object.keys(environment).filter(key => environment[key] !== undefined && environment[key] !== '' &&
    !(key === 'COPILOT_OTEL_FILE_EXPORTER_PATH' && hasDiscardOnlyExporter(environment, platform)) &&
    !isCopilotSettingsMirror(key, environment[key], configuration) &&
    /^(OTEL_|COPILOT_OTEL_|GITHUB_COPILOT_OTEL_|VSCODE_OTEL_|VSCODE_AGENT_HOST_OTEL_)/i.test(key)).sort();
}

function hasEnvironmentOverrides(environment, configuration, platform = process.platform) {
  return environmentOverrideNames(environment, configuration, platform).length > 0;
}

function hookMap(value) {
  if (value === undefined) return {};
  if (!object(value) || !Object.values(value).every(entry => typeof entry === 'boolean')) {
    throw new SafeError('conflict');
  }
  return value;
}

class Settings {
  constructor(configuration, globalTarget, scopes = [configuration], environment = process.env, platform = process.platform) {
    this.configurationSource = configuration;
    this.globalTarget = globalTarget;
    this.scopeSource = scopes;
    this.environment = environment;
    this.platform = platform;
  }

  // WorkspaceConfiguration.get() is a snapshot; inspect() alone does not refresh it.
  get configuration() {
    return typeof this.configurationSource === 'function' ? this.configurationSource() : this.configurationSource;
  }

  get scopes() {
    const sources = typeof this.scopeSource === 'function' ? this.scopeSource() : this.scopeSource;
    return sources.map(source => typeof source === 'function' ? source() : source);
  }

  inspect(key, scope = this.configuration) {
    const inspection = scope.inspect(key);
    if (!inspection) throw new SafeError('unsupported');
    return inspection;
  }

  global(key) {
    return this.inspect(key).globalValue;
  }

  checkMetricsGuards(sources = Object.keys(SOURCES)) {
    if (hasEnvironmentOverrides(this.environment, this.configuration, this.platform)) throw new SafeError('environment');
    for (const scope of this.scopes) {
      if (scope.get('telemetry.telemetryLevel') === 'off') throw new SafeError('telemetry');
      for (const source of sources) {
        const prefix = SOURCES[source];
        for (const suffix of CAPTURE_SUFFIXES) {
          const key = `${prefix}.${suffix}`;
          const inspection = scope.inspect(key);
          if (inspection && [scope.get(key), inspection.globalValue, ...OVERRIDES.map(field => inspection[field])]
            .some(value => value !== undefined && value !== false && value !== '')) {
            throw new SafeError('conflict');
          }
        }
      }
    }
  }

  planConfigure(request, receipt) {
    validateReceipt(receipt);
    const operations = [];
    if (request.metrics) {
      this.checkMetricsGuards();
      for (const [key, rule] of Object.entries(SETTING_RULES)) {
        const desired = rule.endpoint ? request.endpoints[rule.source] : rule.value;
        const current = this.global(key);
        const owned = receipt.settings[key];
        if (owned && !matchesInstalled(key, current, owned.installed) && !equal(current, previousValue(owned.previous))) {
          throw new SafeError('conflict');
        }
        for (const scope of this.scopes) {
          const inspection = this.inspect(key, scope);
          if (inspection.languageIds?.length ||
              OVERRIDES.some(field => inspection[field] !== undefined && !equal(inspection[field], desired))) {
            throw new SafeError('conflict');
          }
          const explicitlySet = inspection.globalValue;
          if (key.endsWith('.captureContent') && (scope.get(key) === true || explicitlySet === true)) {
            throw new SafeError('conflict');
          }
          if (typeof desired === 'string' && explicitlySet !== undefined && explicitlySet !== '' &&
              explicitlySet !== desired && !(owned && matchesInstalled(key, explicitlySet, owned.installed))) {
            throw new SafeError('conflict');
          }
          const effective = scope.get(key);
          const expectedCurrent = inspection.workspaceFolderValue ?? inspection.workspaceValue ??
            inspection.globalValue ?? inspection.defaultValue;
          if (!equal(effective, expectedCurrent) && !equal(effective, desired)) throw new SafeError('conflict');
          if (typeof desired === 'string' && scope.get(`${SOURCES[rule.source]}.enabled`) === true &&
              effective !== undefined && effective !== '' && effective !== desired &&
              !(owned && matchesInstalled(key, effective, owned.installed))) {
            throw new SafeError('conflict');
          }
        }
        operations.push({ key, current, desired });
      }
      // Stage destinations and content controls before enabling either telemetry source.
      operations.sort((a, b) => Number(a.key.endsWith('.enabled')) - Number(b.key.endsWith('.enabled')));
    }
    if (request.hooks) {
      const inspection = this.inspect(HOOK_KEY);
      const current = hookMap(inspection.globalValue)[HOOK_ENTRY];
      if (receipt.hook && current !== true && !equal(current, previousValue(receipt.hook.previous))) {
        throw new SafeError('conflict');
      }
      for (const scope of this.scopes) {
        const scoped = this.inspect(HOOK_KEY, scope);
        if (scoped.languageIds?.length || OVERRIDES.some(field =>
          scoped[field] !== undefined && hookMap(scoped[field])[HOOK_ENTRY] === false)) {
          throw new SafeError('conflict');
        }
      }
      operations.push({ key: HOOK_KEY, current, desired: true });
    }
    return operations;
  }

  planRemove(request, receipt) {
    validateReceipt(receipt);
    const keys = request.metrics ? Object.keys(receipt.settings).sort((a, b) =>
      Number(b.endsWith('.enabled')) - Number(a.endsWith('.enabled'))) : [];
    for (const key of keys) this.inspect(key);
    if (request.hooks && receipt.hook) this.inspect(HOOK_KEY);
    return [...keys, ...request.hooks && receipt.hook ? [HOOK_KEY] : []];
  }

  async configure(request, receipt, store, operations, assertOwnership) {
    for (const { key, current, desired } of operations) {
      assertOwnership();
      const isHook = key === HOOK_KEY;
      const observed = isHook ? hookMap(this.global(key))[HOOK_ENTRY] : this.global(key);
      if (!equal(observed, current)) throw new SafeError('changed');
      if (equal(current, desired)) {
        if (!isHook && receipt.settings[key]) {
          receipt.settings[key].installed = [installedValue(key, desired)];
          await store.saveReceipt(receipt);
        }
        continue;
      }
      if (isHook) {
        receipt.hook = receipt.hook || { previous: previous(current), installed: true };
      } else {
        const entry = receipt.settings[key] || { previous: previous(current), installed: [] };
        const candidates = [];
        if (matchesInstalled(key, current, entry.installed)) candidates.push(installedValue(key, current));
        const next = installedValue(key, desired);
        if (!candidates.some(value => equal(value, next))) candidates.push(next);
        receipt.settings[key] = { previous: entry.previous, installed: candidates };
      }
      // Persist both old/new ownership before the public API write, including endpoint rotations.
      await store.saveReceipt(receipt);
      assertOwnership();
      const latest = this.global(key);
      if (!equal(isHook ? hookMap(latest)[HOOK_ENTRY] : latest, current)) throw new SafeError('changed');
      await this.configuration.update(key, isHook ? { ...hookMap(latest), [HOOK_ENTRY]: true } : desired, this.globalTarget);
      assertOwnership();
      if (!isHook) {
        receipt.settings[key].installed = [installedValue(key, desired)];
        await store.saveReceipt(receipt);
      }
    }
    assertOwnership();
    await store.saveReceipt(receipt);
    assertOwnership();
    for (const { key, desired } of operations) {
      for (const scope of this.scopes) {
        if (!equal(key === HOOK_KEY ? hookMap(scope.get(key))[HOOK_ENTRY] : scope.get(key), desired)) {
          throw new SafeError('effective');
        }
      }
    }
  }

  async remove(receipt, store, keys, assertOwnership) {
    for (const key of keys) {
      assertOwnership();
      if (key === HOOK_KEY) {
        const current = hookMap(this.global(key));
        if (current[HOOK_ENTRY] === receipt.hook.installed) {
          const next = { ...current };
          if (receipt.hook.previous.present) next[HOOK_ENTRY] = receipt.hook.previous.value;
          else delete next[HOOK_ENTRY];
          await this.configuration.update(key, next, this.globalTarget);
          assertOwnership();
          if (!equal(this.global(key), next)) throw new SafeError('effective');
        }
        delete receipt.hook;
      } else {
        const entry = receipt.settings[key];
        if (matchesInstalled(key, this.global(key), entry.installed)) {
          const restored = previousValue(entry.previous);
          await this.configuration.update(key, restored, this.globalTarget);
          assertOwnership();
          if (!equal(this.global(key), restored)) throw new SafeError('effective');
        }
        delete receipt.settings[key];
      }
      assertOwnership();
      await store.saveReceipt(receipt);
      assertOwnership();
    }
    await store.saveReceipt(receipt);
  }

  diagnostics() {
    const sources = {};
    const reasons = new Set();
    for (const source of Object.keys(SOURCES)) {
      let guard;
      try {
        this.checkMetricsGuards([source]);
      } catch (error) {
        if (!(error instanceof SafeError)) throw error;
        guard = error.code;
        reasons.add(guard);
      }
      const rules = Object.entries(SETTING_RULES).filter(([, rule]) => rule.source === source);
      if (this.scopes.some(scope => rules.some(([key]) => !scope.inspect(key)))) {
        sources[source] = 'unsupported';
      } else if (guard) {
        sources[source] = 'blocked';
      } else {
        const configured = this.scopes.every(scope => rules.every(([key, rule]) =>
          rule.endpoint ? !!endpointParts(scope.get(key), source) : equal(scope.get(key), rule.value)));
        sources[source] = configured ? 'effective configured; reload may be needed; awaiting actual data' : 'not configured';
      }
    }
    for (const scope of this.scopes) {
      const local = endpointParts(scope.get(`${SOURCES.vscodeLocal}.otlpEndpoint`), 'vscodeLocal');
      const copilot = endpointParts(scope.get(`${SOURCES.vscodeCopilot}.otlpEndpoint`), 'vscodeCopilot');
      if (local && copilot && (local.port !== copilot.port || local.token !== copilot.token)) {
        sources.vscodeLocal = sources.vscodeCopilot = 'blocked';
        reasons.add('conflict');
      }
    }
    const hooks = this.scopes.every(scope => scope.inspect(HOOK_KEY)) ?
      this.scopes.every(scope => hookMap(scope.get(HOOK_KEY))[HOOK_ENTRY] === true) ? 'effective configured' : 'not configured' :
      'unsupported';
    return { hooks, ...sources, reasons: [...reasons] };
  }
}

module.exports = { Settings, hasEnvironmentOverrides, environmentOverrideNames, hasDiscardOnlyExporter };
