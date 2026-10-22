// What to offer where the caret is, in an outline or a template — and what
// to say about a word under the pointer. Plain functions of the text, so the
// tests can run them without VS Code; extension.js turns them into VS Code's
// completion items and hovers.
//
// A completion result is { from, to, items }: the part of the line the
// chosen item replaces, and the items. An item is { label, insert, kind },
// with optional snippet (insert is a snippet), retrigger (offer more once
// it's in), detail, documentation (Markdown) and filter.

const outline = require('./outline');
const { COMMON_FIELDS, SECTIONS, KEYPAD_MODELS, DEFAULTS, ENTRY_FIELDS } = require('./vocabulary');

const NAME = /[\p{L}\p{N}_.@-]/u;

// ---------------------------------------------------------------------------
// {{values}}: in a template, and in an outline's values and conditions
// ---------------------------------------------------------------------------

/** Where the innermost `{{` still open before the caret starts, or -1. */
function openTagStart(before) {
  const open = [];
  for (let index = 0; index < before.length - 1; index += 1) {
    const pair = before.slice(index, index + 2);
    if (pair === '{{') { open.push(index); index += 1; } else if (pair === '}}') { open.pop(); index += 1; }
  }
  return open.length ? open[open.length - 1] : -1;
}

/** The blocks still open at the end of `text`, innermost first. */
function openBlocks(text) {
  const open = [];
  for (const match of text.matchAll(/\{\{\s*([#/])\s*([\p{L}\p{N}_.-]+)/gu)) {
    if (match[1] === '#') {
      open.push(match[2]);
    } else {
      const at = open.lastIndexOf(match[2]);
      if (at >= 0) open.splice(at, 1);
    }
  }
  return open.reverse();
}

/** How a tag is finished off after what's put in: by closing braces already
 *  there — replaced, so the caret ends after them — or ones added. */
function closing(line, to) {
  const after = line.slice(to);
  if (after.startsWith('}}')) return { to: to + 2, add: '}}' };
  const close = after.indexOf('}}');
  const open = after.indexOf('{{');
  if (close >= 0 && (open < 0 || close < open)) return { to, add: '' }; // a tag being changed: it has its own
  return { to, add: '}}' };
}

const escapeSnippet = (text) => text.replace(/[\\$}]/g, '\\$&');

function valueDocumentation(entry) {
  const parts = [`**${entry.title}**`, entry.help];
  const example = entry.example && !entry.help.includes(entry.example) ? `Example: \`${entry.example}\`` : '';
  if (example) parts.push(example);
  if (entry.sample) parts.push(`Gives, for instance: ${entry.sample}`);
  if (entry.formats?.length) {
    parts.push(entry.formats.map((format) => `- \`${format.pattern}\` — ${format.sample}`).join('\n'));
  }
  return parts.join('\n\n');
}

/** The values a `{{` offers: the app's — whole, or as far as a part to fill
 *  in, `contact.` — then those the tree sets. */
function valueItems(vocabulary, extras = []) {
  const items = [];
  const seen = new Set();
  for (const entry of vocabulary.values) {
    if (entry.kind === 'block') continue;
    const hole = entry.name.indexOf('<');
    const name = hole >= 0 ? entry.name.slice(0, hole) : entry.name;
    if (!name || seen.has(name)) continue;
    seen.add(name);
    const family = hole >= 0;
    items.push({
      label: name,
      kind: family ? 'family' : entry.kind === 'call' ? 'call' : 'value',
      detail: family ? `${entry.group}: ${entry.name}` : entry.title,
      documentation: valueDocumentation(entry),
      entry,
      family,
    });
  }
  for (const extra of extras) {
    if (seen.has(extra.name)) continue;
    seen.add(extra.name);
    items.push({ label: extra.name, kind: 'value', detail: extra.detail, documentation: extra.documentation });
  }
  return items;
}

/** A value item, made to finish a tag: `leaf}}`, `quote file='…'}}`. */
function finishValue(item, add) {
  if (item.family) return { ...item, insert: item.label, retrigger: true };
  const required = item.entry?.attributes?.filter((attribute) => attribute.required) ?? [];
  if (!required.length) return { ...item, insert: item.label + add };
  const attributes = required.map((attribute, index) => ` ${attribute.name}='\${${index + 1}}'`).join('');
  return { ...item, insert: `${escapeSnippet(item.label)}${attributes}${escapeSnippet(add)}`, snippet: true };
}

/**
 * Completion inside a `{{…}}` at the caret, or undefined when the caret
 * isn't in one. `before` is the text before the caret that might hold open
 * blocks (the whole template, or just the line); `extras` are names the
 * outline sets.
 */
function tagCompletions(line, caret, { vocabulary, before = line.slice(0, caret), extras = [] }) {
  const lineBefore = line.slice(0, caret);
  const start = openTagStart(lineBefore);
  if (start < 0) return undefined;
  const inner = lineBefore.slice(start + 2);
  let to = caret;
  while (to < line.length && NAME.test(line[to])) to += 1;

  // {{#each …}}: a block's name.
  let match = inner.match(/^#\s*([\p{L}\p{N}_.-]*)$/u);
  if (match) {
    const finish = closing(line, to);
    const whole = finish.add === '}}';
    const items = vocabulary.values.filter((entry) => entry.kind === 'block').map((entry) => {
      const name = entry.name;
      let insert = name;
      if (whole) {
        insert = name === 'each'
          ? `each \${1:clipboard}${escapeSnippet('}}')}$0${escapeSnippet('{{/each}}')}`
          : `${escapeSnippet(`${name}}}`)}$0${escapeSnippet(`{{/${name}}}`)}`;
      }
      return {
        label: name, kind: 'block', detail: entry.title, documentation: valueDocumentation(entry),
        insert: whole ? insert : escapeSnippet(name), snippet: true,
      };
    });
    return { from: caret - match[1].length, to: finish.to, items };
  }

  // {{/…}}: closes the innermost block left open.
  match = inner.match(/^\/\s*([\p{L}\p{N}_.-]*)$/u);
  if (match) {
    const finish = closing(line, to);
    const names = openBlocks(before.slice(0, before.length - (lineBefore.length - start)));
    return {
      from: caret - match[1].length,
      to: finish.to,
      items: names.map((name, index) => ({
        label: name, kind: 'block', detail: index === 0 ? 'Closes the innermost block' : 'Closes an outer block',
        insert: name + finish.add, sort: index,
      })),
    };
  }

  // {{leaf}}: a value's name.
  match = inner.match(/^\s*([\p{L}\p{N}_.@-]*)$/u);
  if (match) {
    const finish = closing(line, to);
    return {
      from: caret - match[1].length,
      to: finish.to,
      items: valueItems(vocabulary, extras).map((item, index) => ({ ...finishValue(item, finish.add), sort: index })),
    };
  }

  // {{date:EEEE d MMMM}}: a format.
  match = inner.match(/^\s*([\p{L}\p{N}_.]+):([^|}]*)$/u);
  if (match) {
    const entry = vocabulary.value(match[1]);
    if (!entry?.formats?.length) return undefined;
    let end = caret;
    while (end < line.length && !'|}'.includes(line[end])) end += 1;
    const finish = closing(line, end);
    return {
      from: caret - match[2].length,
      to: finish.to,
      items: entry.formats.map((format, index) => ({
        label: format.pattern, kind: 'format', detail: format.sample, insert: format.pattern + finish.add, sort: index,
      })),
    };
  }

  // {{quote file=…}}, {{#each clipboard where=…}}: attributes.
  match = inner.match(/^(#?)\s*([\p{L}\p{N}_.@-]+)\s+(.*)$/su);
  if (!match || match[3].includes('|')) return undefined;
  const block = match[1] === '#';
  const entry = vocabulary.value(match[2], block);
  const rest = match[3];

  const valueTyped = rest.match(/(?:^|\s)([\p{L}_][\p{L}\p{N}_-]*)=(['"]?)([^'"\s]*)$/u);
  if (valueTyped) {
    const attribute = entry?.attributes?.find((candidate) => candidate.name === valueTyped[1]);
    if (!attribute?.choices?.length) return undefined;
    return {
      from: caret - valueTyped[3].length,
      to: caret,
      items: attribute.choices.map((choice, index) => ({
        label: choice, kind: 'choice', insert: choice, sort: index,
      })),
    };
  }
  const nameTyped = rest.match(/(?:^|\s)([\p{L}_][\p{L}\p{N}_-]*)?$/u);
  if (!nameTyped) return undefined;
  const partial = nameTyped[1] ?? '';
  const present = new Set([...rest.matchAll(/([\p{L}_][\p{L}\p{N}_-]*)=/gu)].map((found) => found[1]));
  const items = (entry?.attributes ?? []).filter((attribute) => !present.has(attribute.name)).map((attribute, index) => {
    const documentation = [attribute.help, attribute.example ? `Example: \`${attribute.example}\`` : '']
      .filter(Boolean).join('\n\n');
    return attribute.choices?.length
      ? { label: attribute.name, kind: 'attribute', insert: `${attribute.name}=`, retrigger: true, documentation, sort: index }
      : {
        label: attribute.name, kind: 'attribute', insert: `${attribute.name}='\${1}'`, snippet: true, documentation,
        sort: index,
      };
  });
  // What a list goes through comes first: {{#each clipboard}}.
  if (block && match[2] === 'each' && rest.slice(0, rest.length - partial.length).trim() === '') {
    items.push(...valueItems(vocabulary, extras).filter((item) => !item.family && item.kind === 'value')
      .map((item, index) => ({ ...item, insert: item.label, sort: 100 + index })));
  }
  return items.length ? { from: caret - partial.length, to: caret, items } : undefined;
}

// ---------------------------------------------------------------------------
// The outline
// ---------------------------------------------------------------------------

function fieldDocumentation(field, type) {
  const parts = [`**${field.title ?? field.key}**${type ? ` — ${type}` : ''}`];
  if (field.hint) parts.push(`*${field.hint}*`);
  if (field.help) parts.push(field.help);
  if (field.choices?.length) parts.push(`One of: ${field.choices.map((choice) => `\`${choice}\``).join(', ')}`);
  return parts.join('\n\n');
}

function actionDocumentation(action) {
  const parts = [`**${action.title}** — \`${action.type}\``];
  if (action.keywords.length > 1) parts.push(`Also written ${action.keywords.slice(1).map((word) => `\`${word}\``).join(', ')}.`);
  if (action.fields.length) parts.push(`Fields: ${action.fields.map((field) => `\`${field.key}\``).join(', ')}`);
  return parts.join('\n\n');
}

/** Each action type's own keyword first, then the other words it answers to. */
function keywordItems(vocabulary) {
  const first = vocabulary.actions.filter((action) => action.keywords.length)
    .map((action) => ({ word: action.keywords[0], action }));
  const more = vocabulary.actions.flatMap((action) => action.keywords.slice(1).map((word) => ({ word, action })));
  return [...first, ...more].map(({ word, action }) => ({
    label: word, kind: 'keyword', insert: word, detail: action.title, documentation: actionDocumentation(action),
  }));
}

function keyItem(key, documentation, kind = 'field', detail) {
  return { label: key, kind, insert: `${key}: `, retrigger: true, documentation, detail, filter: key };
}

/** The type an annotation names, if it does: a keyword, `type: …`, an app. */
function namedType(annotation, vocabulary, apps) {
  if (annotation.word) return vocabulary.typeForKeyword(annotation.word) ?? (apps.includes(annotation.word) ? 'app.open' : undefined);
  if (annotation.key === 'type') return vocabulary.knownType(annotation.value);
  return undefined;
}

/** In a key's or a step's brackets: an item, or a pair's value. */
function annotationCompletions(lines, index, caret, sources) {
  const { vocabulary, templates = [], apps = [] } = sources;
  const line = lines[index];
  const around = outline.bracketAround(line, caret);
  if (!around) return undefined;
  const others = around.items.filter((item) => item !== around.current)
    .map((item) => outline.parseAnnotation(line.slice(item.start, item.end)));
  const own = others.map((annotation) => namedType(annotation, vocabulary, apps)).find(Boolean);
  const type = own ?? outline.inheritedType(lines, index, vocabulary, apps);
  const action = type && vocabulary.describe(type);
  const fields = action?.fields ?? [];
  const present = new Set(others.filter((annotation) => annotation.key).map((annotation) => annotation.key));
  /** A display's `ok: Copy`: the type held there. */
  const held = new Map(others.filter((annotation) => annotation.key && vocabulary.holders.has(annotation.key))
    .map((annotation) => [annotation.key, vocabulary.knownType(annotation.value)]).filter(([, held]) => held));

  const typed = line.slice(around.current.start, caret);
  const colon = typed.indexOf(':');
  const key = colon > 0 ? typed.slice(0, colon).trim() : '';
  if (colon > 0 && outline.isKey(key) && !typed.slice(colon + 1).startsWith('//')) {
    // A pair's value.
    let start = around.current.start + colon + 1;
    while (start < caret && line[start] === ' ') start += 1;
    if (start < caret && line[start] === '"') start += 1;
    if (line.slice(start, caret).includes('{{')) return undefined;
    let fieldType = type;
    let fieldKey = key;
    const dot = key.indexOf('.');
    if (dot > 0 && held.has(key.slice(0, dot))) {
      fieldType = held.get(key.slice(0, dot));
      fieldKey = key.slice(dot + 1);
    }
    const field = vocabulary.field(fieldKey, fieldType);
    let words = [];
    let kind = 'choice';
    if (field?.kind === 'choice') words = field.choices;
    else if (field?.kind === 'flag') words = ['true', 'false'];
    else if (field?.kind === 'action') {
      words = vocabulary.actions.map((candidate) => candidate.keywords[0]).filter(Boolean);
      kind = 'keyword';
    } else if (key === 'type') {
      words = vocabulary.actions.map((candidate) => candidate.type);
      kind = 'type';
    } else if (key === 'template') {
      words = templates;
      kind = 'file';
    } else if (key === 'app') {
      words = apps;
      kind = 'app';
    }
    if (!words.length) return undefined;
    return {
      from: start,
      to: caret,
      items: words.map((word, order) => {
        const described = kind === 'type' ? vocabulary.describe(word) : kind === 'keyword'
          ? vocabulary.describe(vocabulary.typeForKeyword(word)) : undefined;
        return {
          label: word, kind, insert: word, sort: order, detail: described?.title,
          documentation: described ? actionDocumentation(described) : undefined,
        };
      }),
    };
  }

  // An item: a keyword, a field, a list, a template, an app.
  const lead = typed.length - typed.trimStart().length;
  const from = around.current.start + lead;
  const partial = line.slice(from, caret);
  const items = [];
  if (partial.startsWith('@')) {
    items.push(...outline.listNames(lines).map((name) => ({
      label: `@${name}`, kind: 'list', insert: `@${name}`, detail: `The nodes of # list ${name}`,
    })));
    return { from, to: caret, items };
  }
  if (!own) items.push(...keywordItems(vocabulary));
  for (const field of fields) {
    if (!present.has(field.key)) items.push(keyItem(field.key, fieldDocumentation(field, type), 'field', field.title));
  }
  for (const [holder, heldType] of held) {
    for (const field of vocabulary.describe(heldType)?.fields ?? []) {
      const heldKey = `${holder}.${field.key}`;
      if (!present.has(heldKey)) items.push(keyItem(heldKey, fieldDocumentation(field, heldType), 'field', field.title));
    }
  }
  for (const field of COMMON_FIELDS) {
    if (field.key === 'type' && own) continue;
    if (!present.has(field.key) && !(field.key === 'colour' && present.has('color'))) {
      items.push(keyItem(field.key, fieldDocumentation(field), 'field', field.title));
    }
  }
  for (const name of outline.valueKeys(lines, vocabulary)) {
    if (!present.has(name)) items.push(keyItem(name, 'A value for templates, set elsewhere in this outline.', 'value', 'value'));
  }
  items.push(...outline.listNames(lines).map((name) => ({
    label: `@${name}`, kind: 'list', insert: `@${name}`, detail: `The nodes of # list ${name}`,
  })));
  items.push(...templates.filter((name) => name.toLowerCase().endsWith('.md')).map((name) => ({
    label: name, kind: 'file', insert: name, detail: 'A template',
  })));
  if (!own && partial) items.push(...apps.map((name) => ({ label: name, kind: 'app', insert: name, detail: 'Open in this app' })));
  return { from, to: caret, items: items.map((item, order) => ({ ...item, sort: item.sort ?? order })) };
}

const CONDITION = /^(\s*)(if|else\s+if|otherwise\s+if|elif)\s+/i;

/** Whether the step above, at the same depth, is an If or Else if: what an
 *  Else follows. */
function followsIf(lines, index) {
  const own = outline.classify(lines[index]);
  for (let line = index - 1; line >= 0; line -= 1) {
    const info = outline.classify(lines[line]);
    if (info.kind === 'heading') return false;
    if (info.kind !== 'step' && info.kind !== 'item') continue;
    if (info.indent < own.indent) return false;
    if (info.indent === own.indent) return info.kind === 'step' && CONDITION.test(info.body);
  }
  return false;
}

/** A step's label: If and Else, and what an If tests with. */
function conditionCompletions(lines, index, caret, vocabulary) {
  const line = lines[index];
  const info = outline.classify(line);
  const label = line.slice(info.bodyStart, caret);
  if (outline.bracketAround(line, caret)) return undefined;

  const first = label.match(/^\s*(\p{L}*)$/u);
  if (first) {
    const items = [{
      label: 'If', kind: 'condition', insert: 'If ', retrigger: true,
      documentation: 'A condition: the steps under it run when it holds.\n\n`If {{answer}} is yes`',
    }];
    if (followsIf(lines, index)) {
      items.push(
        { label: 'Else if', kind: 'condition', insert: 'Else if ', retrigger: true, documentation: 'When no If or Else if before it held, and this does.' },
        { label: 'Else', kind: 'condition', insert: 'Else', documentation: 'When none before it held.' },
      );
    }
    return { from: caret - first[1].length, to: caret, items };
  }

  const condition = label.match(CONDITION);
  if (!condition) return undefined;
  const test = label.slice(condition[0].length);
  // The left side: a value, quoted words, or a word.
  const left = test.match(/^(\{\{(?:[^{}]|\{\{[^{}]*\}\})*\}\}|"(?:[^"\\]|\\.)*"|'[^']*'|[^\s"'{]+)/);
  if (!left) {
    if (test.trim()) return undefined;
    const items = vocabulary.values.filter((entry) => entry.kind === 'value' && !entry.name.includes('<'))
      .map((entry, order) => ({
        label: `{{${entry.name}}}`, kind: 'value', insert: `{{${entry.name}}}`, detail: entry.title,
        documentation: valueDocumentation(entry), sort: ['answer', 'displayed', 'selection', 'clipboard'].includes(entry.name) ? order - 1000 : order,
      }));
    return { from: caret, to: caret, items };
  }
  const rest = test.slice(left[0].length);
  if (!/^\s/.test(rest)) return undefined;
  const typedOperator = rest.trimStart();
  const lower = typedOperator.toLowerCase();
  const operators = vocabulary.conditionOperators.filter((word) => !word.includes('’'));
  // Past the operator, the right side is free text: `is yes`. But `is n`
  // may yet be `is not`.
  const matching = operators.filter((word) => word.toLowerCase().startsWith(lower));
  if (!matching.length) return undefined;
  const items = matching.map((word, order) => ({
    label: word, kind: 'operator', insert: `${word} `, filter: word, sort: order,
    detail: /^[a-z]/i.test(word) ? undefined : 'compares numbers as numbers',
  }));
  return items.length ? { from: caret - typedOperator.length, to: caret, items } : undefined;
}

/** A heading: the sections, `[pages]`, a keypad's model. */
function headingCompletions(line, caret, info) {
  const before = line.slice(0, caret);
  const open = before.lastIndexOf('[');
  if (open >= 0 && !before.slice(open).includes(']')) {
    const section = outline.headingSection(line.slice(info.titleStart, open));
    const partial = before.slice(open + 1).split(',').pop().trimStart();
    let items = [];
    if (section?.kind === 'keypad') {
      items = [...KEYPAD_MODELS.map((model) => ({ label: model, kind: 'model', insert: model, detail: 'For every keypad of this model' })),
        { label: 'id', kind: 'field', insert: 'id: ', detail: "One board, by the ID `keybow keypads` lists" }];
    } else if (section?.kind === 'tree' && section.name !== 'bottom' && section.name !== 'bottomup' && !section.name.startsWith('row4')) {
      items = [{ label: 'pages', kind: 'keyword', insert: 'pages', detail: "The tree's first row picks a page of keys" }];
    }
    return items.length ? { from: caret - partial.length, to: caret, items } : undefined;
  }
  const title = before.match(/^\s*#+\s*([\p{L}\p{N} ]*)$/u);
  if (!title) return undefined;
  return {
    from: caret - title[1].length,
    to: caret,
    items: SECTIONS.map((section, order) => ({
      label: section.label, kind: 'section', insert: section.insert, detail: section.detail, sort: order,
      retrigger: section.label === 'keypad' ? false : undefined,
    })),
  };
}

/** `# defaults`: `- key: value`. */
function defaultsCompletions(line, caret, vocabulary) {
  const before = line.slice(0, caret);
  const key = before.match(/^\s*[-*]\s+([\p{L}\p{N}._-]*)$/u);
  if (key) {
    const typed = key[1];
    const from = caret - typed.length;
    const forType = typed.match(/^types\.(.+)\.([\p{L}\p{N}._-]*)$/u);
    if (forType && vocabulary.describe(forType[1])) {
      const action = vocabulary.describe(forType[1]);
      return {
        from, to: caret,
        items: action.fields.map((field) => keyItem(`types.${action.type}.${field.key}`, fieldDocumentation(field, action.type), 'field', field.title)),
      };
    }
    if (typed.startsWith('types.')) {
      return {
        from, to: caret,
        items: vocabulary.actions.map((action) => ({
          label: `types.${action.type}.`, kind: 'family', insert: `types.${action.type}.`, retrigger: true,
          detail: `Defaults for ${action.title}`,
        })),
      };
    }
    return {
      from, to: caret,
      items: [
        ...DEFAULTS.map((entry) => keyItem(entry.key, entry.help, 'field')),
        { label: 'types.', kind: 'family', insert: 'types.', retrigger: true, detail: "An action type's defaults" },
      ],
    };
  }
  const value = before.match(/^\s*[-*]\s+([\p{L}\p{N}._-]+)\s*:\s*(\S*)$/u);
  if (!value) return undefined;
  let words = [];
  if (value[1] === 'action.type') words = vocabulary.actions.map((action) => action.type);
  const forType = value[1].match(/^types\.(.+)\.([^.]+)$/);
  if (forType) {
    const field = vocabulary.describe(forType[1])?.fields.find((candidate) => candidate.key === forType[2]);
    if (field?.kind === 'choice') words = field.choices;
    if (field?.kind === 'flag') words = ['true', 'false'];
  }
  if (!words.length) return undefined;
  return { from: caret - value[2].length, to: caret, items: words.map((word, order) => ({ label: word, kind: 'choice', insert: word, sort: order })) };
}

/** `# contacts` and `# projects`: the fields in an entry's brackets. */
function entryCompletions(lines, index, caret, kind) {
  const line = lines[index];
  const around = outline.bracketAround(line, caret);
  if (!around) return undefined;
  const typed = line.slice(around.current.start, caret);
  if (typed.includes(':')) return undefined;
  const present = new Set(around.items.filter((item) => item !== around.current)
    .map((item) => outline.parseAnnotation(line.slice(item.start, item.end)).key).filter(Boolean));
  const known = ENTRY_FIELDS[kind] ?? [];
  const keys = [...known.map((field) => field.key), ...outline.entryFields(lines, kind)];
  const items = [...new Set(keys)].filter((key) => !present.has(key)).map((key, order) => ({
    ...keyItem(key, known.find((field) => field.key === key)?.help ?? `Also given in # ${kind}.`), sort: order,
  }));
  const lead = typed.length - typed.trimStart().length;
  return { from: around.current.start + lead, to: caret, items };
}

/** Names the outline sets, for `{{`: `when`, a contact's other fields. */
function outlineExtras(lines, vocabulary) {
  const extras = outline.valueKeys(lines, vocabulary).map((name) => ({
    name, detail: 'Set in this outline', documentation: `\`${name}\` is set on keys in this outline, and inherited below them.`,
  }));
  for (const [kind, prefix] of [['contacts', 'contact'], ['projects', 'project']]) {
    for (const key of outline.entryFields(lines, kind)) {
      extras.push({ name: `${prefix}.${key}`, detail: `From # ${kind}`, documentation: `The ${key} given in # ${kind}.` });
    }
  }
  return extras;
}

/** Completion at a place in an outline, or undefined. */
function outlineCompletions(lines, index, caret, sources) {
  const { vocabulary } = sources;
  const line = lines[index];
  const tag = tagCompletions(line, caret, { vocabulary, extras: outlineExtras(lines, vocabulary) });
  if (tag) return tag;
  const info = outline.classify(line);
  if (info.kind === 'heading') return headingCompletions(line, caret, info);
  const section = outline.sectionAt(lines, index);
  if (section.kind === 'defaults') return defaultsCompletions(line, caret, vocabulary);
  if (section.kind === 'contacts' || section.kind === 'projects') return entryCompletions(lines, index, caret, section.kind);
  if (!outline.holdsKeys(section)) return undefined;
  if (info.kind === 'step') {
    const condition = conditionCompletions(lines, index, caret, vocabulary);
    if (condition) return condition;
  }
  if (info.kind === 'item' || info.kind === 'step') return annotationCompletions(lines, index, caret, sources);
  return undefined;
}

/** Completion at a place in a template, or undefined. */
function templateCompletions(lines, index, caret, { vocabulary }) {
  const before = lines.slice(0, index).join('\n') + '\n' + lines[index].slice(0, caret);
  return tagCompletions(lines[index], caret, { vocabulary, before });
}

// ---------------------------------------------------------------------------
// Hovers
// ---------------------------------------------------------------------------

/** The tags on a line, innermost last: each `{{`'s place and its `}}`'s. */
function tagsOn(line) {
  const tags = [];
  const open = [];
  for (let index = 0; index < line.length - 1; index += 1) {
    const pair = line.slice(index, index + 2);
    if (pair === '{{') { open.push(index); index += 1; } else if (pair === '}}' && open.length) {
      tags.push({ start: open.pop(), end: index + 2 });
      index += 1;
    }
  }
  return tags;
}

/** What to say about the word at the caret: { from, to, markdown }. */
function hoverAt(lines, index, caret, { vocabulary, isOutline, apps = [] }) {
  const line = lines[index];
  const tag = tagsOn(line).filter((candidate) => candidate.start <= caret && caret < candidate.end)
    .sort((a, b) => (a.end - a.start) - (b.end - b.start))[0];
  if (tag) {
    const inner = line.slice(tag.start + 2, tag.end - 2);
    const mark = inner.match(/^\s*([#/]?)\s*/);
    const nameStart = tag.start + 2 + mark[0].length;
    let nameEnd = nameStart;
    while (nameEnd < tag.end - 2 && NAME.test(line[nameEnd])) nameEnd += 1;
    if (caret < nameStart || caret > nameEnd) return undefined;
    const name = line.slice(nameStart, nameEnd);
    const entry = vocabulary.value(name, mark[1] !== '');
    if (!entry) return undefined;
    return { from: nameStart, to: nameEnd, markdown: `\`{{${mark[1]}${entry.name}}}\`\n\n${valueDocumentation(entry)}` };
  }
  if (!isOutline) return undefined;
  const around = outline.bracketAround(line, caret);
  if (!around) return undefined;
  const item = around.current;
  const text = line.slice(item.start, item.end);
  const lead = text.length - text.trimStart().length;
  const annotation = outline.parseAnnotation(text);
  if (annotation.word) {
    const from = item.start + lead;
    const to = from + annotation.word.length;
    const type = vocabulary.typeForKeyword(annotation.word);
    if (type) return { from, to, markdown: actionDocumentation(vocabulary.describe(type)) };
    if (annotation.word.startsWith('@')) return { from, to, markdown: `The nodes of \`# list ${annotation.word.slice(1)}\`, as if written here.` };
    if (/\.md$/i.test(annotation.word)) return { from, to, markdown: 'A template, in the `templates` folder beside the outline.' };
    if (apps.includes(annotation.word)) return { from, to, markdown: `Opens the key in **${annotation.word}**.` };
    return undefined;
  }
  const keyStart = item.start + lead;
  const keyEnd = keyStart + annotation.key.length;
  if (caret > keyEnd) return undefined;
  const others = around.items.filter((candidate) => candidate !== item)
    .map((candidate) => outline.parseAnnotation(line.slice(candidate.start, candidate.end)));
  let type = others.map((other) => namedType(other, vocabulary, apps)).find(Boolean)
    ?? outline.inheritedType(lines, index, vocabulary, apps);
  let key = annotation.key;
  const dot = key.indexOf('.');
  if (dot > 0 && vocabulary.holders.has(key.slice(0, dot))) {
    const holder = others.find((other) => other.key === key.slice(0, dot));
    type = holder && vocabulary.knownType(holder.value);
    key = key.slice(dot + 1);
  }
  const field = vocabulary.field(key, type);
  const markdown = field
    ? fieldDocumentation(field, type)
    : `\`${annotation.key}\` is a value for templates: \`{{${annotation.key}}}\`, here and in every key under this one.`;
  return { from: keyStart, to: keyEnd, markdown };
}

module.exports = {
  openTagStart, openBlocks, tagCompletions, outlineCompletions, templateCompletions, hoverAt, conditionCompletions,
};
