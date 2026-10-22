// The grammars, through VS Code's own TextMate engine: the scopes each piece
// of an outline or a template is given.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { tokenize, markdownGrammar } from './tokenize.mjs';

/** The innermost scope of `text` on line `line` (its nth appearance). */
async function scopes(scope, source) {
  const lines = await tokenize(scope, source);
  return (text, line, nth = 0) => {
    const found = lines[line].filter((token) => token.text === text)[nth];
    assert.ok(found, `“${text}” on line ${line + 1}`);
    return found.scopes[found.scopes.length - 1];
  };
}

const outline = [
  'My keys — a title, kept as written',
  '',
  '1. Work [colour: 0060ff, Calendar, 10 min alert, @when]',
  '   2. Log [append, find.byName: "Week {{isoWeek}}", createIfMissing: true, area: work]',
  '   3. Docs [https://example.com/docs, standup.md, Rider]',
  'An ignored line',
  '4. Jot [Ask, text: "What\'s up?"]',
  '   - If {{answer}} contains soon:',
  '      - [Reminders, title: "{{answer|Untitled}}"]',
  '   - Else',
  '5. A \\[draft\\] [type: shortcut, name: x]',
  '# row 2 [pages]',
  '# list when',
  '1. Today',
  '# keypad Desk [RGB Keypad, id: E66000000000AAAA]',
  '# contacts',
  '- Alex Example [phone: +15550100]',
  '# defaults',
  '- commitDelayMs: 800',
].join('\n');

test('an outline', async () => {
  const at = await scopes('source.keybownotes', outline);
  assert.equal(at('My keys — a title, kept as written', 0), 'comment.block.preamble.keybownotes');
  assert.equal(at('1', 2), 'constant.numeric.key.keybownotes');
  assert.equal(at('colour', 2), 'support.type.property-name.colour.keybownotes');
  assert.equal(at('0060ff', 2), 'constant.other.color.rgb-value.keybownotes');
  assert.equal(at('Calendar', 2), 'keyword.other.action.keybownotes');
  assert.equal(at('alert', 2), 'keyword.other.action.keybownotes');
  assert.equal(at('when', 2), 'variable.other.list.keybownotes');
  assert.equal(at('find.byName', 3), 'support.type.property-name.field.keybownotes');
  assert.equal(at('isoWeek', 3), 'support.variable.keybownotes');
  assert.equal(at('true', 3), 'constant.language.boolean.keybownotes');
  assert.equal(at('area', 3), 'variable.other.property.keybownotes');
  assert.equal(at('https://example.com/docs', 4), 'markup.underline.link.keybownotes');
  assert.equal(at('standup.md', 4), 'string.unquoted.template.keybownotes');
  assert.equal(at('Rider', 4), 'entity.name.type.app.keybownotes');
  assert.equal(at('An ignored line', 5), 'comment.line.ignored.keybownotes');
  assert.equal(at('If', 7), 'keyword.control.conditional.keybownotes');
  assert.equal(at('answer', 7), 'support.variable.keybownotes');
  assert.equal(at('contains', 7), 'keyword.operator.wordlike.keybownotes');
  assert.equal(at('Untitled', 8), 'string.unquoted.fallback.keybownotes');
  assert.equal(at('Else', 9), 'keyword.control.conditional.keybownotes');
  assert.equal(at('\\[', 10), 'constant.character.escape.keybownotes');
  assert.equal(at('shortcut', 10), 'support.type.action.keybownotes');
  assert.equal(at('row 2', 11), 'entity.name.section.keybownotes');
  assert.equal(at('pages', 11), 'keyword.other.pages.keybownotes');
  assert.equal(at('when', 12), 'entity.name.type.list.keybownotes');
  assert.equal(at('RGB Keypad', 14), 'support.type.model.keybownotes');
  assert.equal(at('E66000000000AAAA', 14), 'constant.other.board-id.keybownotes');
  assert.equal(at('Alex Example', 16), 'entity.name.type.entry.keybownotes');
  assert.equal(at('commitDelayMs', 18), 'support.type.property-name.default.keybownotes');
  assert.equal(at('800', 18), 'constant.numeric.keybownotes');
});

test('only the last bracket group is annotations', async () => {
  const at = await scopes('source.keybownotes', '1. A [x] middle [Notes]\n2. Unfinished [Notes');
  assert.ok(!at(' A [x] middle ', 0).includes('annotations'));
  assert.equal(at('Notes', 0), 'keyword.other.action.keybownotes');
  assert.equal(at(' Unfinished [Notes', 1), 'meta.item.keybownotes');
});

test('a stray {{ doesn\'t colour the lines after it', async () => {
  const at = await scopes('source.keybownotes', '1. A [text: "{{oops"]\n2. B [Notes]');
  assert.equal(at('Notes', 1), 'keyword.other.action.keybownotes');
});

test('a template', { skip: !markdownGrammar && 'VS Code’s Markdown grammar isn’t here' }, async () => {
  const at = await scopes('text.html.markdown.keybownotes', fs.readFileSync(new URL('../../docs/examples/templates/unpaid.md', import.meta.url), 'utf8')
    + '\n# Standup {{date:EEE d MMM}}\n{{quote file=\'quotes.md\' order=sequential}}');
  assert.equal(at('each', 0), 'entity.name.function.block.keybownotes');
  assert.equal(at('clipboard', 0), 'support.variable.keybownotes');
  assert.equal(at('where', 0), 'entity.other.attribute-name.keybownotes');
  assert.equal(at('Invoice', 5), 'variable.other.keybownotes', 'a column, in a table');
  assert.equal(at('@sum.Amount', 8), 'support.variable.keybownotes');
  assert.equal(at('#', 15), 'punctuation.definition.heading.markdown', 'Markdown is still Markdown');
  assert.equal(at('EEE d MMM', 15), 'string.unquoted.format.keybownotes');
  assert.equal(at('sequential', 16), 'string.unquoted.attribute-value.keybownotes');
});
