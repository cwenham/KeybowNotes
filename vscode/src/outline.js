// Reading the outline as KeybowNotes does — lines, sections, the final
// bracket group, its items — far enough to know where the caret is and what
// a key inherits. The rules are the app's (mac/Sources/KeybowKit/Outline.swift).

/** Indentation, with tabs as four spaces. */
function indentOf(text) {
  let width = 0;
  for (const character of text) {
    if (character === ' ') width += 1;
    else if (character === '\t') width += 4;
    else break;
  }
  return width;
}

/** What a line is: a heading, a numbered item, a bullet, or neither. */
function classify(text) {
  const trimmed = text.trim();
  if (!trimmed) return { kind: 'blank' };
  const lead = text.length - text.trimStart().length;
  if (trimmed.startsWith('#')) {
    const marks = trimmed.match(/^#+/)[0].length;
    const title = trimmed.slice(marks).trim();
    return { kind: 'heading', title, titleStart: text.indexOf(title, lead + marks) };
  }
  const number = trimmed.match(/^(\d+)\./);
  if (number) {
    const after = lead + number[0].length;
    const body = text.slice(after);
    return { kind: 'item', indent: indentOf(text), number: Number(number[1]), body, bodyStart: after };
  }
  if (/^-(\s|$)/.test(trimmed) || /^\*\s/.test(trimmed)) {
    const after = lead + 1;
    return { kind: 'step', indent: indentOf(text), body: text.slice(after), bodyStart: after };
  }
  return { kind: 'other' };
}

const TREE_NAMES = new Set(['main', 'top', 'row1', 'row2', 'row3', 'bottom', 'bottomup', 'row4', 'row4up']);

/** What a heading starts: `# row 2 [pages]`, `# list when`, `# contacts`… */
function headingSection(title) {
  const plain = title.replace(/\[.*\]\s*$/, '').trim();
  const lower = plain.toLowerCase();
  if (['contacts', 'projects', 'defaults'].includes(lower)) return { kind: lower };
  if (lower.startsWith('keypad ')) return { kind: 'keypad', name: plain.slice(7).trim() };
  if (lower.startsWith('list')) {
    const name = plain.slice(4).replace(/^[\s:]+|[\s:]+$/g, '');
    if (name) return { kind: 'list', name };
  }
  const tree = lower.replace(/tree/g, '').replace(/[\s-]/g, '');
  if (TREE_NAMES.has(tree)) return { kind: 'tree', name: tree };
  return undefined;
}

/** The section a line is in, from the nearest heading above that names one:
 *  the main tree when there's none. */
function sectionAt(lines, index) {
  for (let line = index; line >= 0; line -= 1) {
    const info = classify(lines[line]);
    if (info.kind !== 'heading') continue;
    const section = headingSection(info.title);
    if (section) return { ...section, line };
  }
  return { kind: 'tree', name: 'main', line: -1 };
}

/** Sections whose items are keys: trees, lists, a keypad's trees. */
function holdsKeys(section) {
  return section.kind === 'tree' || section.kind === 'list' || section.kind === 'keypad';
}

/** The `[` that opens the final group of `text`, scanning back from the end
 *  as the app does — or -1. Needs the text to end with `]`. */
function finalGroupStart(text) {
  const trimmed = text.trimEnd();
  if (!trimmed.endsWith(']')) return -1;
  let inQuotes = false;
  for (let index = trimmed.length - 2; index >= 0; index -= 1) {
    const character = trimmed[index];
    const escaped = index > 0 && trimmed[index - 1] === '\\';
    if (character === '"' && !escaped) inQuotes = !inQuotes;
    else if (character === '[' && !escaped && !inQuotes) return index;
  }
  return -1;
}

/** The items between `start` and `end`, split on commas outside quotes. */
function splitItems(text, start, end) {
  const items = [];
  let from = start;
  let inQuotes = false;
  for (let index = start; index < end; index += 1) {
    const character = text[index];
    if (character === '\\') { index += 1; continue; }
    if (character === '"') inQuotes = !inQuotes;
    else if (character === ',' && !inQuotes) {
      items.push({ start: from, end: index });
      from = index + 1;
    }
  }
  items.push({ start: from, end });
  return items;
}

/** `key: value` or a word, as the app reads an item. */
function parseAnnotation(text) {
  const trimmed = text.trim();
  const colon = trimmed.indexOf(':');
  if (colon > 0) {
    const key = trimmed.slice(0, colon);
    if (isKey(key) && !trimmed.slice(colon + 1).startsWith('//')) {
      let value = trimmed.slice(colon + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
      return { key, value };
    }
  }
  return { word: trimmed };
}

/** Letters, digits, dots, underscores and hyphens, starting with a letter. */
function isKey(text) {
  return /^\p{L}[\p{L}\p{N}._-]*$/u.test(text);
}

/** A line's annotations: its final bracket group, read. */
function annotationsOf(text) {
  const open = finalGroupStart(text);
  if (open < 0) return [];
  const close = text.trimEnd().length - 1;
  return splitItems(text, open + 1, close).map((item) => parseAnnotation(text.slice(item.start, item.end)))
    .filter((annotation) => annotation.key !== undefined || annotation.word);
}

/**
 * The bracket group the caret is in, as the tree editor finds it while a
 * line is typed — its `]` perhaps not there yet: each item's range, and the
 * one the caret is in. Undefined when the caret isn't in brackets.
 */
function bracketAround(text, caret) {
  let open = -1;
  let start = 0;
  let items = [];
  let inQuotes = false;
  const found = () => {
    if (open < 0 || caret <= open) return undefined;
    const current = items.find((item) => item.start <= caret && caret <= item.end);
    return current && { open, items, current };
  };
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (open < 0) {
      if (character === '\\') { index += 1; continue; }
      if (character === '[') { open = index; start = index + 1; items = []; inQuotes = false; }
    } else if (character === '\\') {
      index += 1;
    } else if (character === '"') {
      inQuotes = !inQuotes;
    } else if (character === ',' && !inQuotes) {
      items.push({ start, end: index });
      start = index + 1;
    } else if (character === ']' && !inQuotes) {
      items.push({ start, end: index });
      const result = found();
      if (result) return result;
      open = -1;
    }
  }
  if (open < 0) return undefined;
  items.push({ start, end: text.length });
  return found();
}

/** The keys and steps above a line that it belongs to, nearest first. */
function ancestors(lines, index) {
  const own = classify(lines[index]);
  let indent = own.kind === 'item' || own.kind === 'step' ? own.indent : indentOf(lines[index]);
  const found = [];
  for (let line = index - 1; line >= 0 && indent > 0; line -= 1) {
    const info = classify(lines[line]);
    if (info.kind === 'heading') break;
    if ((info.kind === 'item' || info.kind === 'step') && info.indent < indent) {
      found.push(line);
      indent = info.indent;
    }
  }
  return found;
}

/** The type a line's own annotations name: a keyword, `type: …`, or an app. */
function ownType(annotations, vocabulary, apps = []) {
  for (const annotation of annotations) {
    if (annotation.word) {
      const type = vocabulary.typeForKeyword(annotation.word);
      if (type) return type;
      if (apps.includes(annotation.word)) return 'app.open';
    } else if (annotation.key === 'type') {
      const type = vocabulary.knownType(annotation.value);
      if (type) return type;
    }
  }
  return undefined;
}

/**
 * The type a line takes from above: the nearest key or condition that names
 * one. In a `# list`, from where the list is used.
 */
function inheritedType(lines, index, vocabulary, apps = [], seen = new Set()) {
  for (const line of ancestors(lines, index)) {
    const type = ownType(annotationsOf(lines[line]), vocabulary, apps);
    if (type) return type;
  }
  const section = sectionAt(lines, index);
  if (section.kind !== 'list' || seen.has(section.name)) return undefined;
  seen.add(section.name);
  for (let line = 0; line < lines.length; line += 1) {
    const annotations = annotationsOf(lines[line]);
    if (!annotations.some((annotation) => annotation.word === `@${section.name}`)) continue;
    const type = ownType(annotations, vocabulary, apps) ?? inheritedType(lines, line, vocabulary, apps, seen);
    if (type) return type;
  }
  return undefined;
}

/** The names of the `# list` sections. */
function listNames(lines) {
  const names = [];
  for (const line of lines) {
    const info = classify(line);
    if (info.kind !== 'heading') continue;
    const section = headingSection(info.title);
    if (section?.kind === 'list' && !names.includes(section.name)) names.push(section.name);
  }
  return names;
}

/** Names keys give values — `when: tomorrow`, `area: work` — not action
 *  fields or colours, in order of first use. */
function valueKeys(lines, vocabulary) {
  const keys = [];
  lines.forEach((line, index) => {
    const info = classify(line);
    if (info.kind !== 'item' && info.kind !== 'step') return;
    if (!holdsKeys(sectionAt(lines, index))) return;
    for (const annotation of annotationsOf(line)) {
      if (annotation.key && !vocabulary.isActionField(annotation.key) && !keys.includes(annotation.key)) {
        keys.push(annotation.key);
      }
    }
  });
  return keys;
}

/** The fields people or projects are given in their section. */
function entryFields(lines, kind) {
  const keys = [];
  lines.forEach((line, index) => {
    if (classify(line).kind !== 'step' || sectionAt(lines, index).kind !== kind) return;
    for (const annotation of annotationsOf(line)) {
      if (annotation.key && !keys.includes(annotation.key)) keys.push(annotation.key);
    }
  });
  return keys;
}

module.exports = {
  indentOf, classify, headingSection, sectionAt, holdsKeys, finalGroupStart, splitItems, parseAnnotation, isKey,
  annotationsOf, bracketAround, ancestors, ownType, inheritedType, listNames, valueKeys, entryFields,
};
