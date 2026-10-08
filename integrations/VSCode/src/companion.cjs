'use strict';

const os = require('node:os');
const { PrivateStore } = require('./private-store.cjs');
const { WindowsStore } = require('./windows-store.cjs');
const { Settings, environmentOverrideNames, hasDiscardOnlyExporter } = require('./settings.cjs');
const { Ownership } = require('./ownership.cjs');
const { MESSAGES, SafeError, assertFresh, uriNonce } = require('./contract.cjs');

const DISCARD_ONLY_NOTE = 'A discard-only SDK exporter setting is present; VS Code can create it internally. Tokenotch leaves it unchanged. Reload VS Code after setup and verify actual usage in Tokenotch. If this setting was inherited from your launcher, it may still suppress delivery.';

function environmentOverrideDetail(environment, configuration, platform) {
  const names = environmentOverrideNames(environment, configuration, platform);
  const displayed = names.slice(0, 32).map(name =>
    /^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(name) ? name : '[nonstandard variable name hidden]');
  if (names.length > displayed.length) displayed.push(`${names.length - displayed.length} additional variable names omitted.`);
  return [
    'Nonempty OTel variables in this VS Code extension host (values hidden):',
    ...displayed,
    '',
    'These variables may override Tokenotch settings. Remove them only if they are not needed, at their source (for example, a shell startup file, launcher, or managed environment). Tokenotch will not change them.',
    `Fully quit all VS Code windows${platform === 'darwin' ? ' with Cmd+Q' : ' with File > Exit'}, reopen VS Code from the corrected environment, then retry setup under Connections > Visual Studio Code in Tokenotch. Reload Window or unsetting a variable in an already-open terminal does not clear the parent environment.`,
    'If these variables are intentional or managed, leave model & token usage off. Activity-only setup can still be used without metrics.'
  ].join('\n');
}

class Companion {
  constructor(vscode, options = {}) {
    this.vscode = vscode;
    this.platform = options.platform ?? process.platform;
    this.environment = options.environment ?? process.env;
    this.now = options.now ?? Date.now;
    this.store = options.store ?? (this.platform === 'win32' ?
      new WindowsStore(options.home ?? os.homedir()) : new PrivateStore(options.home ?? os.homedir()));
    this.ownership = new Ownership(vscode, options.context);
    this.running = false;
  }

  assertLocal() {
    if (this.vscode.env.remoteName || !['darwin', 'win32'].includes(this.platform)) throw new SafeError('remote');
  }

  settings() {
    const configuration = () => this.vscode.workspace.getConfiguration();
    const scopes = () => [configuration(), ...(this.vscode.workspace.workspaceFolders || [])
      .map(folder => this.vscode.workspace.getConfiguration(undefined, folder.uri))];
    return new Settings(configuration, this.vscode.ConfigurationTarget.Global, scopes, this.environment, this.platform);
  }

  async run({ uri, operation } = {}) {
    let request;
    let release;
    let result;
    let environmentDetail;
    let ownsRun = false;
    try {
      this.assertLocal();
      if (this.running) throw new SafeError('busy');
      this.running = ownsRun = true;
      const nonce = uri ? uriNonce(uri, this.vscode.env.uriScheme) : undefined;
      const original = await this.store.readRequest();
      if (nonce !== undefined && nonce !== original.value.nonce) throw new SafeError('nonce');
      request = original.value;
      if (operation && operation !== request.operation) throw new SafeError('request');
      assertFresh(request, original.stat, this.now());
      release = await this.store.acquireLock();
      const receipt = await this.store.readReceipt();
      const identity = this.ownership.verify(receipt);
      const settings = this.settings();
      const plan = () => request.operation === 'configure' ?
        settings.planConfigure(request, receipt) : settings.planRemove(request, receipt);
      plan();
      const action = request.operation === 'configure' ? 'Configure' : 'Remove';
      const features = [request.hooks ? 'native activity hooks' : '', request.metrics ? 'local and Agent Host metrics' : '']
        .filter(Boolean).join(' and ') || 'no integration features';
      let detail = request.operation === 'configure' ?
        `Allow Tokenotch to configure ${features} in this window's user profile settings? Metrics use only the private local receiver, without content capture. Existing external collectors and headers are not replaced. Other settings are preserved.` :
        `Allow Tokenotch to remove ${features} from this window's user profile? Only unchanged fields owned by this installation/profile are restored. Other hook entries, user edits, and unselected features are preserved.`;
      if (request.operation === 'configure' && request.metrics && hasDiscardOnlyExporter(this.environment, this.platform)) {
        detail += `\n\n${DISCARD_ONLY_NOTE}`;
      }
      const approval = await this.vscode.window.showInformationMessage('Tokenotch local integration', { modal: true, detail }, action);
      if (approval !== action) {
        result = { status: 'cancelled', message: MESSAGES.cancelled };
      } else {
        assertFresh(request, original.stat, this.now());
        this.ownership.verify(receipt, identity);
        const operations = plan();
        if (request.operation === 'configure') await this.ownership.bind(receipt, identity);
        const boundIdentity = this.ownership.verify(receipt);
        const assertOwnership = () => this.ownership.verify(receipt, boundIdentity);
        await this.store.consume(original);
        if (request.operation === 'configure') await settings.configure(request, receipt, this.store, operations, assertOwnership);
        else await settings.remove(receipt, this.store, operations, assertOwnership);
        const status = request.operation === 'configure' ? 'configured' : 'removed';
        result = { status, message: MESSAGES[status] };
      }
    } catch (error) {
      result = error instanceof SafeError ?
        { status: error.status, message: error.message } : { status: 'failed', message: MESSAGES.failed };
      if (error instanceof SafeError && error.code === 'environment') {
        environmentDetail = environmentOverrideDetail(this.environment, this.vscode.workspace.getConfiguration(), this.platform);
      }
    } finally {
      if (request && result) {
        try {
          await this.store.writeResult(request, result.status, result.message);
        } catch {
          // Error details may contain private endpoints. Only this fixed boundary message is public.
          result = { status: 'failed', message: MESSAGES.resultFailed };
        }
      }
      if (release) {
        try {
          await release();
        } catch {
          result = { status: 'failed', message: MESSAGES.unsafe };
        }
      }
      if (ownsRun) this.running = false;
    }
    if (result.status === 'failed' || result.status === 'blocked') {
      if (result.message === MESSAGES.environment && environmentDetail) {
        await this.vscode.window.showErrorMessage(result.message, { modal: true, detail: environmentDetail });
      } else {
        await this.vscode.window.showErrorMessage(result.message);
      }
    } else if (['configured', 'removed'].includes(result.status) && request.metrics) {
      const selected = await this.vscode.window.showInformationMessage(result.message, 'Reload Window');
      if (selected === 'Reload Window') await this.vscode.commands.executeCommand('workbench.action.reloadWindow');
    } else {
      await this.vscode.window.showInformationMessage(result.message);
    }
    return result;
  }

  async check() {
    try {
      this.assertLocal();
      await this.store.assertRoot();
      this.ownership.verify(await this.store.readReceipt());
      const diagnostics = this.settings().diagnostics();
      const reasons = diagnostics.reasons.map(code => MESSAGES[code]).join(' ');
      const note = hasDiscardOnlyExporter(this.environment, this.platform) ? ` ${DISCARD_ONLY_NOTE}` : '';
      const text = `Tokenotch public settings: Hooks: ${diagnostics.hooks}. Local: ${diagnostics.vscodeLocal}. Agent Host: ${diagnostics.vscodeCopilot}. ${reasons ? `${reasons} ` : ''}Settings do not verify live telemetry; check delivery in Tokenotch.${note}`;
      if (diagnostics.reasons.includes('environment')) {
        await this.vscode.window.showInformationMessage(text, { modal: true,
          detail: environmentOverrideDetail(this.environment, this.vscode.workspace.getConfiguration(), this.platform) });
      } else {
        await this.vscode.window.showInformationMessage(text);
      }
      return diagnostics;
    } catch (error) {
      const message = error instanceof SafeError ? error.message : MESSAGES.failed;
      await this.vscode.window.showErrorMessage(message);
      return { status: 'blocked', message };
    }
  }
}

module.exports = { Companion };
