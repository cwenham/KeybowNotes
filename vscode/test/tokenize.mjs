// Tokenises text with the extension's grammars, through the same TextMate
// engine VS Code uses — for the grammar tests, and for looking at a file:
//   node test/tokenize.mjs outline ../docs/examples/showcase.md
//   node test/tokenize.mjs template ../docs/examples/templates/unpaid.md

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const textmate = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

/** VS Code's own Markdown grammar, which templates build on. */
export const markdownGrammar = [
  process.env.MARKDOWN_GRAMMAR,
  '/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/markdown-basics/syntaxes/markdown.tmLanguage.json',
].find((file) => file && fs.existsSync(file));

const grammarFiles = {
  'source.keybownotes': path.join(root, 'syntaxes/keybownotes.tmLanguage.json'),
  'source.keybownotes.tags': path.join(root, 'syntaxes/keybownotes-tags.tmLanguage.json'),
  'text.html.markdown.keybownotes': path.join(root, 'syntaxes/keybownotes-template.tmLanguage.json'),
  'text.html.markdown': markdownGrammar,
};

let registry;
async function load() {
  if (registry) return registry;
  const wasm = fs.readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')).buffer;
  await oniguruma.loadWASM(wasm);
  registry = new textmate.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (text) => new oniguruma.OnigString(text),
    }),
    loadGrammar: async (scopeName) => {
      const file = grammarFiles[scopeName];
      if (!file) return null;
      return textmate.parseRawGrammar(fs.readFileSync(file, 'utf8'), file);
    },
  });
  return registry;
}

/** Each line's tokens: its text and its scopes, outermost first. */
export async function tokenize(scopeName, text) {
  const grammar = await (await load()).loadGrammar(scopeName);
  let stack = textmate.INITIAL;
  return text.split('\n').map((line) => {
    const result = grammar.tokenizeLine(line, stack);
    stack = result.ruleStack;
    return result.tokens.map((token) => ({
      text: line.slice(token.startIndex, token.endIndex),
      scopes: token.scopes,
    }));
  });
}

/** The innermost scope given to each piece of text, as `text → scope`. */
export function scopeOf(lines, text, { line, nth = 0 } = {}) {
  const found = [];
  lines.forEach((tokens, index) => {
    if (line !== undefined && index !== line) return;
    for (const token of tokens) if (token.text === text) found.push(token.scopes);
  });
  return found[nth];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [kind, file] = process.argv.slice(2);
  const scope = kind === 'template' ? 'text.html.markdown.keybownotes' : 'source.keybownotes';
  const lines = await tokenize(scope, fs.readFileSync(file, 'utf8'));
  lines.forEach((tokens, index) => {
    for (const token of tokens) {
      if (!token.text.trim()) continue;
      const scopes = token.scopes.slice(1).filter((s) => !s.startsWith('meta.')).join(' ');
      console.log(`${String(index + 1).padStart(4)}  ${JSON.stringify(token.text).padEnd(42)} ${scopes}`);
    }
  });
}
