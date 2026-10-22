// Telling outlines and templates from other Markdown.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { load } = require('../src/vocabulary');
const { classifyText } = require('../src/detect');

const vocabulary = load();
const repository = path.join(__dirname, '..', '..');
const read = (file) => fs.readFileSync(path.join(repository, file), 'utf8');
const kind = (text, options) => classifyText(text, vocabulary, options);

test('the examples in this repository', () => {
  assert.equal(kind(read('docs/examples/showcase.md')), 'outline');
  assert.equal(kind(read('mac/tree.demo.md')), 'outline');
  assert.equal(kind(read('docs/examples/templates/standup.md')), 'template');
  assert.equal(kind(read('docs/examples/templates/unpaid.md')), 'template');
});

test('writing about the syntax stays Markdown', () => {
  for (const file of ['README.md', 'docs/CONFIG-LANGUAGE.md', 'docs/DESIGN.md', 'docs/TREE-EDITOR.md', 'mac/templates/README.md']) {
    assert.equal(kind(read(file)), undefined, file);
  }
  // A list of quotes is data for {{quote}}, not a template.
  assert.equal(kind(read('docs/examples/templates/quotes.md')), undefined);
});

test('a small outline', () => {
  assert.equal(kind(['1. Work [colour: 0060ff]', '   1. Meeting [Calendar]', '      1. Today'].join('\n')), 'outline');
  assert.equal(kind(['1. Jot [Ask]', '   - If {{answer}} is yes', '      - [Copy]', '   - Else', '      - [Notes]'].join('\n')), 'outline');
});

test('Markdown lists aren\'t outlines', () => {
  const notes = [
    '# Shopping',
    '',
    'Things to get this week, in the order the shop has them.',
    '',
    '1. Milk [urgent]',
    '2. Bread',
    '3. Call the bank [Call]',
    '',
    'And remember the receipts — they go in the blue folder.',
    '',
    '## Later',
    '',
    'Paint for the shed.',
  ].join('\n');
  assert.equal(kind(notes), undefined);
});

test('other template languages aren\'t ours', () => {
  assert.equal(kind('{{#if user}}Hello {{user.name}}{{/if}} — {{date}} {{time}}'), undefined);
  assert.equal(kind('---\ntitle: x\n---\n# {{ .Title }}\n{{ .Content }}'), undefined);
  assert.equal(kind('Hello {% if x %}{{ leaf }}{% endif %}'), undefined);
});

test('one telling value is enough for a template', () => {
  assert.equal(kind('From {{frontApp}}: {{clipboard|nothing}}'), 'template');
  assert.equal(kind('# Log — {{date:EEEE}}\n\n-'), 'template');
  assert.equal(kind('# Log — {{date}}'), undefined, '{{date}} alone could be anyone\'s');
});

test('settings turn either off', () => {
  assert.equal(kind(read('docs/examples/showcase.md'), { outlines: false }), 'template', 'it has values too');
  assert.equal(kind(read('docs/examples/templates/standup.md'), { templates: false }), undefined);
});
