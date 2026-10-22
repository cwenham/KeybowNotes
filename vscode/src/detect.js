// Telling a KeybowNotes outline or template from other Markdown, by what's
// in it. Both are .md files, so VS Code opens them as Markdown; the extension
// asks this, and switches the ones that are ours.

const outline = require('./outline');

/** How much of a file to read: enough to tell, quickly. */
const MAX_LINES = 3000;

/** Headings other Markdown seldom has. `# Contacts` or `# Defaults` could be
 *  anyone's; `# row 2` and `# list when` are ours. */
function headingWeight(title) {
  const section = outline.headingSection(title);
  if (!section) return 0;
  if (/\[\s*pages\s*\]\s*$/i.test(title)) return 2;
  if (section.kind === 'list' || section.kind === 'keypad') return 2;
  if (section.kind === 'tree') return ['row2', 'row3', 'bottom', 'bottomup', 'row4', 'row4up'].includes(section.name) ? 2 : 1;
  return 1;
}

/** How surely a key's brackets are ours: 2 for a keyword, a field, a list,
 *  a template, an alert; 1 for any `key: value`; 0 for none. */
function bracketWeight(text, vocabulary) {
  const annotations = outline.annotationsOf(text);
  if (!annotations.length) return 0;
  let weight = 0;
  for (const annotation of annotations) {
    if (annotation.word) {
      const word = annotation.word;
      if (vocabulary.typeForKeyword(word) || word.startsWith('@') || /\.md$/i.test(word) || /^\d+\s*(min|mins|minutes?|h|hrs?|hours?)\s+alert$/i.test(word)) {
        return 2;
      }
    } else {
      if (vocabulary.isActionField(annotation.key) || /^colou?r$/i.test(annotation.key)) return 2;
      weight = 1;
    }
  }
  return weight;
}

/**
 * Whether the text reads as an outline. It must be nearly all keys, steps
 * and sections after any preamble — Markdown has prose — and say something
 * only an outline says.
 */
function isOutline(lines, vocabulary) {
  let started = false;
  let structure = 0;
  let prose = 0;
  let evidence = 0;
  for (const line of lines.slice(0, MAX_LINES)) {
    const info = outline.classify(line);
    switch (info.kind) {
      case 'blank':
        break;
      case 'heading': {
        const weight = headingWeight(info.title);
        if (weight) {
          started = true;
          structure += 1;
          evidence += weight;
        } else if (started) {
          prose += 1;
        }
        break;
      }
      case 'item':
        started = true;
        structure += 1;
        evidence += bracketWeight(line, vocabulary);
        break;
      case 'step':
        if (!started) break;
        structure += 1;
        if (/^\s*(if|else\s+if|otherwise\s+if|elif)\s+\S/i.test(info.body) || /^\s*(else|otherwise):?\s*(\[|$)/i.test(info.body)) {
          evidence += 1;
        }
        evidence += bracketWeight(line, vocabulary);
        break;
      default:
        // Fenced code, tables and paragraphs: Markdown, not an outline.
        if (started) prose += /^\s*(```|\|)/.test(line) ? 3 : 1;
    }
  }
  return structure >= 2 && evidence >= 3 && prose <= Math.max(2, structure * 0.1);
}

/** Tags of other template languages: Handlebars' if and partials, Go's dot,
 *  Jinja's statements. Ours have none of these. */
const FOREIGN = /\{\{\s*(#\s*(if|unless|with)\b|else\b|>|!|\.|-|\/\s*(if|unless|with)\b)|\{\{\{|\{%/;

/** Names that say KeybowNotes on their own: `{{leaf}}`, `{{#ai}}`,
 *  `{{contact.phone}}`, a date with a format. Others — `{{date}}`, `{{path}}`
 *  — could be anyone's. */
const COMMON = new Set(['date', 'time', 'path', 'tree', 'file', 'each', 'header', 'footer', 'empty', 'event', 'location', 'quote']);

const FENCED = /^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?^[ \t]*\1[^\n]*$/gm;
/** Inline code, which may run onto the next line but not past a blank one. */
const INLINE_CODE = /`(?:[^`\n]|\n(?![ \t]*\n))+`/g;
/** HTML tags and images' descriptions: `alt` text describes, it isn't filled in. */
const MARKUP = /<[^>\n]*>|!\[[^\]\n]*\]/g;

const tagCount = (text) => (text.match(/\{\{/g) ?? []).length;

/**
 * Whether the text reads as a template: KeybowNotes `{{values}}` and no other
 * template language's. Writing *about* the syntax — this repository's docs —
 * quotes its tags as code, which a template has no use for: Notes would show
 * the backticks. So more tags in code than out of it is documentation.
 */
function isTemplate(text, vocabulary) {
  const sample = text.length > 400_000 ? text.slice(0, 400_000) : text;
  if (FOREIGN.test(sample)) return false;
  const withoutFences = sample.replace(FENCED, '');
  const plain = withoutFences.replace(INLINE_CODE, '').replace(MARKUP, '');
  const inCode = tagCount(sample) - tagCount(withoutFences.replace(INLINE_CODE, ''));
  let known = 0;
  let telling = 0;
  for (const match of plain.matchAll(/\{\{\s*([#/]?)\s*([\p{L}\p{N}_.@-]+)(:)?/gu)) {
    if (match[1] === '/') continue;
    const [, block, name, format] = match;
    const entry = vocabulary.value(name, block === '#');
    if (!entry) continue;
    known += 1;
    if (!COMMON.has(name) || (format && ['date', 'time'].includes(name)) || name.startsWith('@')) telling += 1;
  }
  if (inCode > known) return false;
  return telling >= 1 || known >= 2;
}

/** 'outline', 'template', or undefined for Markdown that isn't ours. */
function classifyText(text, vocabulary, { outlines = true, templates = true } = {}) {
  const lines = text.split(/\r?\n/);
  if (outlines && isOutline(lines, vocabulary)) return 'outline';
  if (templates && isTemplate(text, vocabulary)) return 'template';
  return undefined;
}

module.exports = { classifyText, isOutline, isTemplate };
