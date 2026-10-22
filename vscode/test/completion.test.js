// What's offered where the caret is (‸), in outlines and templates.

const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('../src/vocabulary');
const { outlineCompletions, templateCompletions, hoverAt } = require('../src/completion');

const vocabulary = load();

/** Completion at ‸ in the text: { from, to, labels, items, replaced }. */
function at(text, { template = false, templates = [], apps = [] } = {}) {
  const lines = text.split('\n');
  const index = lines.findIndex((line) => line.includes('‸'));
  const caret = lines[index].indexOf('‸');
  lines[index] = lines[index].replace('‸', '');
  const result = template
    ? templateCompletions(lines, index, caret, { vocabulary })
    : outlineCompletions(lines, index, caret, { vocabulary, templates, apps });
  if (!result) return undefined;
  return { ...result, labels: result.items.map((item) => item.label), replaced: lines[index].slice(result.from, result.to) };
}

const item = (result, label) => result.items.find((candidate) => candidate.label === label);

test('keywords and fields in a key\'s brackets', () => {
  const result = at('1. Meeting [‸]');
  assert.ok(result.labels.includes('Calendar'));
  assert.ok(result.labels.includes('Notes'));
  assert.ok(result.labels.includes('colour'));
  assert.equal(item(result, 'colour').insert, 'colour: ');
  assert.ok(item(result, 'colour').retrigger, 'offers its values next');
});

test('a type\'s own fields, and no more keywords, once it has one', () => {
  const result = at('1. Meeting [Calendar, ‸]');
  assert.ok(result.labels.includes('start'));
  assert.ok(result.labels.includes('alertMinutes'));
  assert.ok(!result.labels.includes('Notes'), 'the key already has a type');
  assert.ok(!result.labels.includes('type'));
});

test('fields inherited from the branch above', () => {
  const result = at(['1. Work', '   1. Log [append]', '      1. Today [‸]'].join('\n'));
  assert.ok(result.labels.includes('find.byName'));
  assert.ok(result.labels.includes('createIfMissing'));
});

test('fields already there aren\'t offered again', () => {
  const result = at('1. Log [append, entry: x, ‸]');
  assert.ok(!result.labels.includes('entry'));
  assert.ok(result.labels.includes('template'));
});

test('what replaces what\'s been typed', () => {
  const result = at('1. Meeting [Cal‸]');
  assert.equal(result.replaced, 'Cal');
  assert.ok(result.labels.includes('Calendar'));
});

test('choices, flags and types for a pair\'s value', () => {
  assert.deepEqual(at('1. Copy [Copy, format: ‸]').labels, ['auto', 'rich', 'plain']);
  assert.deepEqual(at('1. Log [append, createIfMissing: ‸]').labels, ['true', 'false']);
  assert.ok(at('1. Open [type: ‸]').labels.includes('app.open'));
  assert.ok(at('1. Idea [Display, ok: ‸]').labels.includes('Copy'));
});

test('a display\'s OK action: its fields as ok.…', () => {
  const result = at('1. Idea [Display, ok: Copy, ‸]');
  assert.ok(result.labels.includes('ok.text'));
  assert.ok(result.labels.includes('ok.format'));
  assert.deepEqual(at('1. Idea [Display, ok: Copy, ok.format: ‸]').labels, ['auto', 'rich', 'plain']);
});

test('lists, templates and apps', () => {
  const lists = at(['1. Mood [@‸]', '# list rating', '1. Great'].join('\n'));
  assert.deepEqual(lists.labels, ['@rating']);
  const files = at('1. Standup [‸]', { templates: ['standup.md', 'quotes.txt'] });
  assert.ok(files.labels.includes('standup.md'));
  assert.ok(!files.labels.includes('quotes.txt'), 'only Markdown is a template word');
  assert.ok(!at('1. Code [‸]', { apps: ['Rider'] }).labels.includes('Rider'), 'apps once something is typed');
  assert.ok(at('1. Code [Ri‸]', { apps: ['Rider'] }).labels.includes('Rider'));
  assert.deepEqual(at('1. Code [type: app.open, template: ‸]', { templates: ['a.md'] }).labels, ['a.md']);
});

test('a list\'s keys take their type from where it\'s used', () => {
  const result = at(['1. Check-in [append]', '   1. Mood [@rating]', '# list rating', '1. Great [‸]'].join('\n'));
  assert.ok(result.labels.includes('find.byName'));
});

test('values set elsewhere in the outline', () => {
  const result = at(['1. Work [area: work]', '2. Home [‸]'].join('\n'));
  assert.ok(result.labels.includes('area'));
});

test('{{values}} in a value', () => {
  const result = at('1. Note [Notes, title: "{{‸"]');
  assert.ok(result.labels.includes('leaf'));
  assert.ok(result.labels.includes('selection'));
  assert.ok(result.labels.includes('contact.'), 'a family, finished later');
  assert.equal(item(result, 'leaf').insert, 'leaf}}');
  assert.equal(item(result, 'contact.').insert, 'contact.');
});

test('{{values}} with the braces already closed', () => {
  const result = at('1. Note [Notes, title: "{{le‸}}"]');
  assert.equal(result.replaced, 'le}}');
  assert.equal(item(result, 'leaf').insert, 'leaf}}');
});

test('the outline\'s own values, and a contact\'s fields', () => {
  const result = at(['1. Work [when: today, text: "{{‸"]', '# contacts', '- Alex [phone: 1, discord: alex]'].join('\n'));
  assert.ok(result.labels.includes('when'));
  assert.ok(result.labels.includes('contact.discord'));
});

test('blocks, and closing the open one', () => {
  const blocks = at('{{#‸', { template: true });
  assert.ok(blocks.labels.includes('each'));
  assert.ok(blocks.labels.includes('ai'));
  assert.match(item(blocks, 'ai').insert, /^ai\\}\\}\$0\{\{\/ai\\}\\}$/);
  const closing = at(['{{#each clipboard}}', '{{#header}}', '| A |', '{{/‸'].join('\n'), { template: true });
  assert.deepEqual(closing.labels, ['header', 'each']);
});

test('a date\'s formats', () => {
  const result = at('# Standup {{date:‸}}', { template: true });
  assert.ok(result.labels.includes('EEEE d MMMM'));
  assert.equal(result.replaced, '}}');
});

test('attributes, and their choices', () => {
  const quote = at('{{quote file=quotes.md ‸}}', { template: true });
  assert.ok(quote.labels.includes('heading'));
  assert.ok(quote.labels.includes('order'));
  assert.ok(!quote.labels.includes('file'), 'already there');
  assert.deepEqual(at('{{quote file=quotes.md order=‸}}', { template: true }).labels, ['random', 'sequential']);
  const each = at('{{#each ‸}}', { template: true });
  assert.ok(each.labels.includes('where'));
  assert.ok(each.labels.includes('clipboard'), 'what it goes through');
});

test('If, Else and the tests', () => {
  const first = at(['1. Jot [Ask]', '   - ‸'].join('\n'));
  assert.deepEqual(first.labels, ['If']);
  const afterIf = at(['1. Jot [Ask]', '   - If {{answer}}', '      - [Copy]', '   - El‸'].join('\n'));
  assert.deepEqual(afterIf.labels, ['If', 'Else if', 'Else']);
  const operand = at(['1. Jot [Ask]', '   - If ‸'].join('\n'));
  assert.ok(operand.labels.includes('{{answer}}'));
  const operators = at(['1. Jot [Ask]', '   - If {{answer}} ‸'].join('\n'));
  assert.ok(operators.labels.includes('contains'));
  assert.ok(operators.labels.includes('is not empty'));
  assert.ok(operators.labels.includes('>='));
  const narrowed = at(['1. Jot [Ask]', '   - If {{answer}} is n‸'].join('\n'));
  assert.deepEqual(narrowed.labels, ['is not empty', 'is not']);
  assert.equal(narrowed.replaced, 'is n');
  assert.equal(at(['1. Jot [Ask]', '   - If {{answer}} is yes‸'].join('\n')), undefined, 'the right side is free text');
});

test('a step\'s brackets take its key\'s fields', () => {
  const result = at(['1. Jot [Ask]', '   - If {{answer}} is yes', '      - [Reminders, ‸]'].join('\n'));
  assert.ok(result.labels.includes('due'));
});

test('headings', () => {
  const sections = at('# ‸');
  assert.ok(sections.labels.includes('row 2'));
  assert.ok(sections.labels.includes('contacts'));
  assert.deepEqual(at('# row 2 [‸]').labels, ['pages']);
  assert.equal(at('# bottom [‸]'), undefined, 'the bottom tree can\'t be pages');
  assert.deepEqual(at('# keypad Desk [‸]').labels, ['Keybow 2040', 'RGB Keypad', 'id']);
});

test('defaults, contacts and projects', () => {
  const defaults = at(['# defaults', '- ‸'].join('\n'));
  assert.ok(defaults.labels.includes('commitDelayMs'));
  assert.ok(defaults.labels.includes('types.'));
  assert.ok(at(['# defaults', '- types.calendar.createEvent.‸'].join('\n')).labels.includes('types.calendar.createEvent.duration'));
  assert.ok(at(['# defaults', '- action.type: ‸'].join('\n')).labels.includes('notes.append'));
  const contact = at(['# contacts', '- Alex [phone: 1, ‸]'].join('\n'));
  assert.deepEqual(contact.labels, ['email']);
  assert.deepEqual(at(['# projects', '- Site [‸]'].join('\n')).labels, ['path']);
});

test('nothing in a label or in a template\'s prose', () => {
  assert.equal(at('1. Meet‸ing'), undefined);
  assert.equal(at('Just some ‸text', { template: true }), undefined);
});

test('hovers', () => {
  const lines = ['1. Meeting [Calendar, alertMinutes: 5, area: work, text: "{{leaf}}"]'];
  const hover = (word) => hoverAt(lines, 0, lines[0].indexOf(word) + 1, { vocabulary, isOutline: true });
  assert.match(hover('Calendar').markdown, /calendar\.createEvent/);
  assert.match(hover('alertMinutes').markdown, /minutes before/);
  assert.match(hover('area').markdown, /value for templates/);
  assert.match(hover('leaf').markdown, /The key's label/);
});
