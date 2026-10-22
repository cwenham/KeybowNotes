// KeybowNotes for VS Code: puts outlines and templates opened as Markdown into
// their own modes, and offers completion, hovers and colour swatches there.

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { load } = require('./vocabulary');
const { classifyText } = require('./detect');
const { outlineCompletions, templateCompletions, hoverAt } = require('./completion');

const OUTLINE = 'keybownotes';
const TEMPLATE = 'keybownotes-template';
const OURS = [OUTLINE, TEMPLATE];

/** Schemes whose documents are files someone opened — not notebook cells,
 *  output or settings. */
const SCHEMES = new Set(['file', 'untitled', 'vscode-remote', 'vscode-vfs', 'git']);

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

/** Documents someone moved out of our modes, by URI: left as they chose. */
const leftAlone = new Set();
/** When each document last closed while in one of our modes: VS Code changes
 *  a document's language by closing it and opening it again. */
const closedOurs = new Map();

/** Whether the person's own `files.associations` decides this file — other
 *  than by a bare extension like `*.md`, which is only the default. */
function associatedByUser(document) {
  const associations = vscode.workspace.getConfiguration('files', document).get('associations') ?? {};
  return Object.keys(associations).some((pattern) =>
    !/^(\*\*\/)?\*\.[\w]+$/.test(pattern) && vscode.languages.match({ pattern }, document) > 0);
}

/** A file in a `templates` folder beside a `tree.md`: a template, whatever's in it. */
function besideTree(document) {
  if (document.uri.scheme !== 'file') return false;
  const folder = path.dirname(document.uri.fsPath);
  return path.basename(folder) === 'templates' && fs.existsSync(path.join(path.dirname(folder), 'tree.md'));
}

async function detect(document) {
  if (document.languageId !== 'markdown' || !SCHEMES.has(document.uri.scheme)) return;
  const key = document.uri.toString();
  if (leftAlone.has(key)) return;
  const closed = closedOurs.get(key);
  if (closed !== undefined && Date.now() - closed < 2000) {
    // Moved from our mode to Markdown, by hand: leave it there.
    leftAlone.add(key);
    return;
  }
  if (associatedByUser(document)) return;
  const settings = vscode.workspace.getConfiguration('keybownotes.detect', document);
  const outlines = settings.get('outlines', true);
  const templates = settings.get('templates', true);
  let kind = classifyText(document.getText(), load(), { outlines, templates });
  if (!kind && templates && besideTree(document)) kind = 'template';
  if (!kind) return;
  try {
    await vscode.languages.setTextDocumentLanguage(document, kind === 'outline' ? OUTLINE : TEMPLATE);
  } catch {
    // The document closed meanwhile.
  }
}

// ---------------------------------------------------------------------------
// What's on this Mac and beside the outline
// ---------------------------------------------------------------------------

let appNames;
/** The apps installed, by name: what an outline can open a key in. */
function installedApps() {
  if (appNames) return appNames;
  const names = new Set();
  if (process.platform === 'darwin') {
    const roots = ['/Applications', '/System/Applications', path.join(os.homedir(), 'Applications')];
    for (const root of roots) {
      for (const entry of safeList(root)) {
        if (entry.endsWith('.app')) names.add(entry.slice(0, -4));
        else if (!entry.startsWith('.')) {
          for (const inner of safeList(path.join(root, entry))) if (inner.endsWith('.app')) names.add(inner.slice(0, -4));
        }
      }
    }
  }
  appNames = [...names].sort((a, b) => a.localeCompare(b));
  return appNames;
}

function safeList(folder) {
  try {
    return fs.readdirSync(folder);
  } catch {
    return [];
  }
}

/** The files in the `templates` folder beside an outline. */
function templatesBeside(document) {
  if (document.uri.scheme !== 'file') return [];
  const folder = path.join(path.dirname(document.uri.fsPath), 'templates');
  return safeList(folder).filter((name) => !name.startsWith('.') && !fs.statSync(path.join(folder, name), { throwIfNoEntry: false })?.isDirectory())
    .sort((a, b) => a.localeCompare(b));
}

// ---------------------------------------------------------------------------
// Completion and hovers
// ---------------------------------------------------------------------------

const KINDS = {
  keyword: vscode.CompletionItemKind.Keyword,
  field: vscode.CompletionItemKind.Property,
  value: vscode.CompletionItemKind.Variable,
  call: vscode.CompletionItemKind.Function,
  family: vscode.CompletionItemKind.Module,
  block: vscode.CompletionItemKind.Snippet,
  list: vscode.CompletionItemKind.Reference,
  file: vscode.CompletionItemKind.File,
  app: vscode.CompletionItemKind.Class,
  type: vscode.CompletionItemKind.Class,
  choice: vscode.CompletionItemKind.EnumMember,
  format: vscode.CompletionItemKind.Text,
  attribute: vscode.CompletionItemKind.Property,
  operator: vscode.CompletionItemKind.Operator,
  condition: vscode.CompletionItemKind.Keyword,
  section: vscode.CompletionItemKind.Module,
  model: vscode.CompletionItemKind.EnumMember,
};

function linesOf(document) {
  const lines = [];
  for (let index = 0; index < document.lineCount; index += 1) lines.push(document.lineAt(index).text);
  return lines;
}

function toItems(result, line) {
  const range = new vscode.Range(line, result.from, line, result.to);
  return result.items.map((item) => {
    const completion = new vscode.CompletionItem(item.label, KINDS[item.kind] ?? vscode.CompletionItemKind.Text);
    completion.insertText = item.snippet ? new vscode.SnippetString(item.insert) : item.insert;
    completion.range = range;
    if (item.detail) completion.detail = item.detail;
    if (item.documentation) completion.documentation = new vscode.MarkdownString(item.documentation);
    if (item.filter) completion.filterText = item.filter;
    if (item.sort !== undefined) completion.sortText = String(item.sort + 100000).padStart(7, '0');
    if (item.retrigger) completion.command = { command: 'editor.action.triggerSuggest', title: 'More' };
    return completion;
  });
}

const TRIGGERS = ['[', ',', ' ', ':', '{', '#', '/', '@', '.', '=', '\'', '"'];

function activate(context) {
  const vocabulary = load();

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((document) => detect(document)),
    vscode.workspace.onDidSaveTextDocument((document) => detect(document)),
    vscode.workspace.onDidCloseTextDocument((document) => {
      if (OURS.includes(document.languageId)) closedOurs.set(document.uri.toString(), Date.now());
    }),

    vscode.languages.registerCompletionItemProvider(OUTLINE, {
      provideCompletionItems(document, position) {
        const result = outlineCompletions(linesOf(document), position.line, position.character, {
          vocabulary, templates: templatesBeside(document), apps: installedApps(),
        });
        return result ? toItems(result, position.line) : undefined;
      },
    }, ...TRIGGERS),

    vscode.languages.registerCompletionItemProvider(TEMPLATE, {
      provideCompletionItems(document, position) {
        const result = templateCompletions(linesOf(document), position.line, position.character, { vocabulary });
        return result ? toItems(result, position.line) : undefined;
      },
    }, ...TRIGGERS),

    vscode.languages.registerHoverProvider(OURS, {
      provideHover(document, position) {
        const found = hoverAt(linesOf(document), position.line, position.character, {
          vocabulary, isOutline: document.languageId === OUTLINE, apps: installedApps(),
        });
        if (!found) return undefined;
        return new vscode.Hover(new vscode.MarkdownString(found.markdown),
          new vscode.Range(position.line, found.from, position.line, found.to));
      },
    }),

    // Swatches beside `colour: 0060ff`, with the picker to change them.
    vscode.languages.registerColorProvider(OUTLINE, {
      provideDocumentColors(document) {
        const colours = [];
        for (let line = 0; line < document.lineCount; line += 1) {
          const text = document.lineAt(line).text;
          for (const match of text.matchAll(/(?:^\s*[-*]\s+|[[,]\s*)colou?r\s*:\s*(#?)([0-9a-fA-F]{6})(?=\s*(?:,|\]|$))/g)) {
            const start = match.index + match[0].length - match[2].length - match[1].length;
            const hex = match[2];
            const colour = new vscode.Color(
              parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255, 1);
            colours.push(new vscode.ColorInformation(new vscode.Range(line, start, line, start + match[1].length + 6), colour));
          }
        }
        return colours;
      },
      provideColorPresentations(colour, { document, range }) {
        const hex = [colour.red, colour.green, colour.blue]
          .map((part) => Math.round(part * 255).toString(16).padStart(2, '0')).join('');
        const hash = document.getText(range).startsWith('#') ? '#' : '';
        return [new vscode.ColorPresentation(hash + hex)];
      },
    }),
  );

  for (const document of vscode.workspace.textDocuments) detect(document);
}

function deactivate() {}

module.exports = { activate, deactivate };
