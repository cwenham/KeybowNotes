// Inside VS Code: the extension as someone would meet it. Run by run.js.

const vscode = require('vscode');
const assert = require('assert');
const path = require('path');

const workspace = process.env.KEYBOW_TEST_WORKSPACE;
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The document open for a file now: a language change replaces it. */
const current = (file) => vscode.workspace.textDocuments.find((document) => document.uri.fsPath === file);

/** Opens a file, and waits for its language to settle. */
async function languageOf(name) {
  const file = path.join(workspace, name);
  await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(file));
  let last;
  for (let tries = 0; tries < 30; tries += 1) {
    await pause(100);
    const language = current(file)?.languageId;
    if (language === last && tries > 5) break;
    last = language;
  }
  return last;
}

async function untitled(language, content) {
  const document = await vscode.workspace.openTextDocument({ language, content });
  await vscode.window.showTextDocument(document);
  return document;
}

async function labelsAt(document, line, character, trigger) {
  const list = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', document.uri,
    new vscode.Position(line, character), trigger);
  return list.items.map((item) => (typeof item.label === 'string' ? item.label : item.label.label));
}

const checks = [
  ['file names alone pick the mode, before anything is read', async () => {
    for (const [name, language] of [['KeybowNotes/tree.md', 'keybownotes'], ['KeybowNotes/templates/plain.md', 'keybownotes-template']]) {
      const document = await vscode.workspace.openTextDocument(path.join(workspace, name));
      assert.equal(document.languageId, language, name);
    }
  }],
  ['tree.md in a KeybowNotes folder is an outline', async () => {
    assert.equal(await languageOf('KeybowNotes/tree.md'), 'keybownotes');
  }],
  ['a template in its folder is a template, whatever is in it', async () => {
    assert.equal(await languageOf('KeybowNotes/templates/plain.md'), 'keybownotes-template');
  }],
  ['an outline elsewhere is found by what is in it', async () => {
    assert.equal(await languageOf('elsewhere/my keys.md'), 'keybownotes');
  }],
  ['a template elsewhere is found by what is in it', async () => {
    assert.equal(await languageOf('elsewhere/unpaid.md'), 'keybownotes-template');
  }],
  ['other Markdown stays Markdown', async () => {
    assert.equal(await languageOf('elsewhere/README.md'), 'markdown');
    assert.equal(await languageOf('elsewhere/shopping.md'), 'markdown');
  }],
  ['a file moved back to Markdown by hand stays there', async () => {
    const file = path.join(workspace, 'elsewhere/unpaid.md');
    await vscode.languages.setTextDocumentLanguage(current(file), 'markdown');
    await pause(1500);
    assert.equal(current(file).languageId, 'markdown');
  }],
  ['keywords and fields in brackets', async () => {
    const document = await untitled('keybownotes', '1. Meeting [Calendar, ]\n2. Other []');
    const fields = await labelsAt(document, 0, 22, ' ');
    assert.ok(fields.includes('start'), fields.join(' '));
    assert.ok(!fields.includes('Notes'));
    const keywords = await labelsAt(document, 1, 10, '[');
    assert.ok(keywords.includes('Calendar'));
  }],
  ['{{values}} and blocks in a template', async () => {
    const document = await untitled('keybownotes-template', '# {{}}\n{{#}}');
    assert.ok((await labelsAt(document, 0, 4, '{')).includes('leaf'));
    const list = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', document.uri,
      new vscode.Position(1, 3), '#');
    const each = list.items.find((item) => item.label === 'each');
    assert.ok(each.insertText instanceof vscode.SnippetString, 'a snippet');
  }],
  ['If and its tests', async () => {
    const document = await untitled('keybownotes', '1. Jot [Ask]\n   - If {{answer}} ');
    assert.ok((await labelsAt(document, 1, 20, ' ')).includes('contains'));
  }],
  ['hovers', async () => {
    const document = await untitled('keybownotes', '1. Meeting [Calendar, text: "{{leaf}}"]');
    const hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', document.uri, new vscode.Position(0, 14));
    const text = hovers.flatMap((hover) => hover.contents.map((part) => part.value ?? String(part))).join('\n');
    assert.match(text, /calendar\.createEvent/);
  }],
  ['colour swatches', async () => {
    const document = await untitled('keybownotes', '1. Work [colour: 0060ff]\n# defaults\n- colour: 202020');
    const colours = await vscode.commands.executeCommand('vscode.executeDocumentColorProvider', document.uri);
    assert.equal(colours.length, 2);
    assert.ok(Math.abs(colours[0].color.blue - 1) < 0.01);
  }],
  ['VS Code colours outlines and templates with these grammars', async () => {
    // Its token capture guesses a file's language from its name, so these
    // copies are given ours in this throwaway profile.
    await vscode.workspace.getConfiguration('files').update('associations',
      { '*.kbtree': 'keybownotes', '*.kbtemplate': 'keybownotes-template' }, vscode.ConfigurationTarget.Global);
    const capture = (name) => vscode.commands.executeCommand('_workbench.captureSyntaxTokens',
      vscode.Uri.file(path.join(workspace, 'capture', name)));
    const tree = await capture('tree.kbtree');
    const calendar = tree.find((token) => token.c === 'Calendar');
    assert.match(calendar.t, /keyword\.other\.action\.keybownotes/);
    assert.notEqual(calendar.r.dark_plus.split(':')[0], 'default', 'Dark+ gives keywords a colour');
    const isoWeek = tree.find((token) => token.c === 'isoWeek');
    assert.match(isoWeek.t, /support\.variable\.keybownotes/);
    const template = await capture('unpaid.kbtemplate');
    const sum = template.find((token) => token.c === '@sum.Amount');
    assert.match(sum.t, /^text\.html\.markdown\.keybownotes .*support\.variable\.keybownotes/);
    const table = template.find((token) => token.c.includes('Invoice') && /markup\.table/.test(token.t));
    assert.ok(table, 'Markdown tables are still Markdown');
  }],
];

exports.run = async function run() {
  const failures = [];
  for (const [name, check] of checks) {
    try {
      await check();
      console.log(`  ✔ ${name}`);
    } catch (error) {
      failures.push(name);
      console.log(`  ✖ ${name}\n      ${error.message.split('\n').join('\n      ')}`);
    }
  }
  if (failures.length) throw new Error(`${failures.length} of ${checks.length} failed`);
};
