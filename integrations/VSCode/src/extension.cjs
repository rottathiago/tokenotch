'use strict';

const vscode = require('vscode');
const { Companion } = require('./companion.cjs');

function activate(context) {
  const companion = new Companion(vscode, { context });
  context.subscriptions.push(
    vscode.window.registerUriHandler({ handleUri: uri => companion.run({ uri }) }),
    vscode.commands.registerCommand('tokenotch.configureLocalIntegration', () => companion.run({ operation: 'configure' })),
    vscode.commands.registerCommand('tokenotch.removeOwnedConfiguration', () => companion.run({ operation: 'remove' })),
    vscode.commands.registerCommand('tokenotch.checkIntegration', () => companion.check())
  );
}

module.exports = { activate };
