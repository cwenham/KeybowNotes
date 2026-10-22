// Writes the TextMate grammars in syntaxes/ from data/vocabulary.json, so
// the keywords, fields and {{values}} they colour are the app's own.
// Run after the vocabulary changes: `npm run grammars` (or `npm run vocabulary`,
// which does both).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const vocabulary = JSON.parse(fs.readFileSync(path.join(root, 'data/vocabulary.json'), 'utf8'));

/** A literal for a regular expression. */
const literal = (text) => text.replace(/[.*+?^${}()|[\]\\/-]/g, '\\$&');
/** Alternatives, longest first, so `Direct Insert` wins over `Insert`. */
const anyOf = (words) => [...new Set(words)].sort((a, b) => b.length - a.length).map(literal).join('|');

// ---------------------------------------------------------------------------
// The words
// ---------------------------------------------------------------------------

const keywords = vocabulary.actions.flatMap((action) => action.keywords);
const types = vocabulary.actions.map((action) => action.type);
const fieldKeys = vocabulary.actions.flatMap((action) => action.fields.map((field) => field.key));
const holders = [...new Set(vocabulary.actions.flatMap((action) =>
  action.fields.filter((field) => field.kind === 'action').map((field) => field.key)))];

// Values whole — `leaf`, `stopwatch.laps` — and families as far as their
// first part to fill in: `contact.`, `home.`, `@sum.`.
const valueNames = vocabulary.values.filter((value) => value.kind !== 'block' && !value.name.includes('<'))
  .map((value) => value.name);
const valueFamilies = [...new Set(vocabulary.values.filter((value) => value.name.includes('<'))
  .map((value) => value.name.slice(0, value.name.indexOf('<'))))];
const blockNames = vocabulary.values.filter((value) => value.kind === 'block').map((value) => value.name);

// ---------------------------------------------------------------------------
// Pieces of patterns
// ---------------------------------------------------------------------------

const KEY = '[\\p{L}][\\p{L}\\p{N}._-]*';
/** The final group of an item: `[` with nothing after its `]` but spaces,
 *  no `[` outside quotes in between — as the outline finds it, from the end. */
const FINAL_GROUP = '(?=(?:[^\\["\\\\]|\\\\.|"(?:[^"\\\\]|\\\\.)*")*\\][ \\t]*$)';
/** Where an annotation ends: a comma, or the group's closing bracket. */
const ITEM_END = '(?=[ \\t]*(?:,|\\][ \\t]*$))';
/** The start of an annotation: right after `[` or a comma. */
const ITEM_START = '(?<=[\\[,])[ \\t]*';
/** A line the outline reads: a heading, a numbered item, or a bullet. */
const STRUCTURE = '[ \\t]*(?:#|\\d+\\.|-(?:[ \\t]|$)|\\*[ \\t])';
const TREE_NAME = '(?:tree[ \\t-]*)?(?:main|top|row[ \\t-]*[123]|row[ \\t-]*4(?:[ \\t-]*up)?|bottom(?:[ \\t-]*up)?)(?:[ \\t-]*tree)?';
const SECTION_END = '(?=^[ \\t]*#)';

const suffix = '.keybownotes';
const KNOWN_NAME = `(?:${anyOf(valueFamilies)})[^\\s}|:='"{]+|(?:${anyOf(valueNames)})`;
const OTHER_NAME = '[^\\s}|:=\'"{]+';

// ---------------------------------------------------------------------------
// {{values}}: shared by the outline and templates
// ---------------------------------------------------------------------------

const tags = {
  $schema: 'https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json',
  name: 'KeybowNotes values',
  scopeName: 'source.keybownotes.tags',
  patterns: [{ include: '#tag' }],
  repository: {
    tag: {
      patterns: [{ include: '#block-closing' }, { include: '#block-opening' }, { include: '#value' }],
    },
    'block-closing': {
      match: '(\\{\\{)(/)[ \\t]*([^\\s}]*)[ \\t]*(\\}\\})',
      name: `meta.tag.block.closing${suffix}`,
      captures: {
        1: { name: `punctuation.definition.tag.begin${suffix}` },
        2: { name: `keyword.control.block${suffix}` },
        3: { name: `entity.name.function.block${suffix}` },
        4: { name: `punctuation.definition.tag.end${suffix}` },
      },
    },
    'block-opening': {
      begin: '(\\{\\{)(#)[ \\t]*([\\p{L}_][\\p{L}\\p{N}_.-]*)',
      beginCaptures: {
        1: { name: `punctuation.definition.tag.begin${suffix}` },
        2: { name: `keyword.control.block${suffix}` },
        3: { name: `entity.name.function.block${suffix}` },
      },
      // A tag stays on its line: a stray `{{` mustn't colour the rest of the file.
      end: '(\\}\\})|$',
      endCaptures: { 1: { name: `punctuation.definition.tag.end${suffix}` } },
      name: `meta.tag.block.opening${suffix}`,
      patterns: [
        // What a list goes through: `clipboard` in {{#each clipboard}}.
        { include: '#list-source' },
        { include: '#attributes' },
      ],
    },
    value: {
      begin: '(\\{\\{)(?![#/])',
      beginCaptures: { 1: { name: `punctuation.definition.tag.begin${suffix}` } },
      end: '(\\}\\})|$',
      endCaptures: { 1: { name: `punctuation.definition.tag.end${suffix}` } },
      name: `meta.tag.value${suffix}`,
      patterns: [
        { include: '#name' },
        // {{date:EEEE d MMMM}}
        {
          match: '(:)([^|}]*)',
          captures: {
            1: { name: `punctuation.separator.format${suffix}` },
            2: { name: `string.unquoted.format${suffix}` },
          },
        },
        // {{contact.phone|none}}
        {
          begin: '\\|',
          beginCaptures: { 0: { name: `punctuation.separator.fallback${suffix}` } },
          end: '(?=\\}\\})|$',
          contentName: `string.unquoted.fallback${suffix}`,
          patterns: [{ include: '#strings' }, { include: '#tag' }],
        },
        { include: '#attributes' },
      ],
    },
    // The value's name, first in the tag: one the app gives, or one the tree
    // sets — `{{when}}` — or a list's column.
    name: {
      patterns: [
        {
          match: `\\G[ \\t]*(${KNOWN_NAME})(?=[\\s}|:]|$)`,
          captures: { 1: { name: `support.variable${suffix}` } },
        },
        {
          match: `\\G[ \\t]*(${OTHER_NAME})`,
          captures: { 1: { name: `variable.other${suffix}` } },
        },
      ],
    },
    // What a list goes through: `clipboard` in {{#each clipboard}}.
    'list-source': {
      patterns: [
        {
          match: `\\G[ \\t]+(${KNOWN_NAME})(?=[\\s}]|$)`,
          captures: { 1: { name: `support.variable${suffix}` } },
        },
        {
          match: `\\G[ \\t]+(${OTHER_NAME})(?![=\\p{L}\\p{N}_.@-])`,
          captures: { 1: { name: `variable.other${suffix}` } },
        },
      ],
    },
    attributes: {
      patterns: [
        {
          match: '([\\p{L}_][\\p{L}\\p{N}_-]*)(=)',
          captures: {
            1: { name: `entity.other.attribute-name${suffix}` },
            2: { name: `punctuation.separator.key-value${suffix}` },
          },
        },
        { include: '#strings' },
        { include: '#tag' },
        { match: '(?<==)[^\\s}\'"|{\\\\]+', name: `string.unquoted.attribute-value${suffix}` },
      ],
    },
    strings: {
      patterns: [
        // Inside an outline's quoted value, quotes are written \".
        { match: '\\\\"(?:[^"\\\\]|\\\\[^"])*?\\\\"', name: `string.quoted.double${suffix}` },
        { match: '"[^"]*"', name: `string.quoted.double${suffix}` },
        { match: '\'[^\']*\'', name: `string.quoted.single${suffix}` },
      ],
    },
  },
};

// ---------------------------------------------------------------------------
// The outline
// ---------------------------------------------------------------------------

/** The value of a pair, up to its comma or the group's `]`. */
const valueRule = (beginKey, keyScope, valuePatterns, contentScope = `string.unquoted.value${suffix}`) => ({
  begin: `${ITEM_START}(${beginKey})(:)(?!//)[ \\t]*`,
  beginCaptures: {
    1: { name: keyScope },
    2: { name: `punctuation.separator.key-value${suffix}` },
  },
  // Each key is one line: whatever's left open ends with it.
  end: '(?=,|\\][ \\t]*$)|$',
  contentName: contentScope,
  patterns: valuePatterns,
});

const scalarEnd = `(?=[ \\t]*(?:,|\\][ \\t]*$))`;

const outline = {
  $schema: 'https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json',
  name: 'KeybowNotes Outline',
  scopeName: 'source.keybownotes',
  patterns: [
    { include: '#preamble' },
    { include: '#section-people' },
    { include: '#section-defaults' },
    { include: '#section-list' },
    { include: '#section-keypad' },
    { include: '#heading-tree' },
    { include: '#heading-other' },
    { include: '#tree' },
  ],
  repository: {
    // Before the first item: a title, kept as written and otherwise ignored.
    preamble: {
      begin: `\\A(?![ \\t]*$)(?!${STRUCTURE})`,
      end: `(?=^${STRUCTURE})`,
      name: `comment.block.preamble${suffix}`,
    },

    // -- Headings ----------------------------------------------------------
    'section-people': {
      begin: '^[ \\t]*(#+)[ \\t]*((?i:contacts|projects))[ \\t]*$',
      beginCaptures: {
        0: { name: `markup.heading${suffix}` },
        1: { name: `punctuation.definition.heading${suffix}` },
        2: { name: `entity.name.section${suffix}` },
      },
      end: SECTION_END,
      patterns: [{ include: '#entry' }, { include: '#ignored' }],
    },
    'section-defaults': {
      begin: '^[ \\t]*(#+)[ \\t]*((?i:defaults))[ \\t]*$',
      beginCaptures: {
        0: { name: `markup.heading${suffix}` },
        1: { name: `punctuation.definition.heading${suffix}` },
        2: { name: `entity.name.section${suffix}` },
      },
      end: SECTION_END,
      patterns: [{ include: '#default' }, { include: '#ignored' }],
    },
    'section-list': {
      begin: '^[ \\t]*(#+)[ \\t]*((?i:list))[ \\t:]*(.+?)[ \\t]*$',
      beginCaptures: {
        0: { name: `markup.heading${suffix}` },
        1: { name: `punctuation.definition.heading${suffix}` },
        2: { name: `entity.name.section${suffix}` },
        3: { name: `entity.name.type.list${suffix}` },
      },
      end: SECTION_END,
      patterns: [{ include: '#tree' }],
    },
    'section-keypad': {
      begin: '^[ \\t]*(#+)[ \\t]*((?i:keypad))[ \\t]+(.*?)[ \\t]*(?:(\\[)(.*)(\\]))?[ \\t]*$',
      beginCaptures: {
        0: { name: `markup.heading${suffix}` },
        1: { name: `punctuation.definition.heading${suffix}` },
        2: { name: `entity.name.section${suffix}` },
        3: { name: `entity.name.type.keypad${suffix}` },
        4: { name: `punctuation.definition.annotations.begin${suffix}` },
        5: {
          patterns: [
            {
              match: '(?i:keybow[ \\t]*2040|rgb[ \\t]*keypad(?:[ \\t]*base)?|pico[ \\t]*rgb[ \\t]*keypad|keybow|pico|rgb)',
              name: `support.type.model${suffix}`,
            },
            {
              match: '(id)[ \\t]*(:)[ \\t]*([^,\\]]*)',
              captures: {
                1: { name: `support.type.property-name${suffix}` },
                2: { name: `punctuation.separator.key-value${suffix}` },
                3: { name: `constant.other.board-id${suffix}` },
              },
            },
            { match: ',', name: `punctuation.separator.annotations${suffix}` },
          ],
        },
        6: { name: `punctuation.definition.annotations.end${suffix}` },
      },
      end: SECTION_END,
      patterns: [{ include: '#tree' }],
    },
    'heading-tree': {
      match: `^[ \\t]*(#+)[ \\t]*((?i:${TREE_NAME}))[ \\t]*(?:(\\[)([^\\]]*)(\\]))?[ \\t]*$`,
      name: `markup.heading${suffix}`,
      captures: {
        1: { name: `punctuation.definition.heading${suffix}` },
        2: { name: `entity.name.section${suffix}` },
        3: { name: `punctuation.definition.annotations.begin${suffix}` },
        4: { patterns: [{ match: '(?i:\\bpages\\b)', name: `keyword.other.pages${suffix}` }] },
        5: { name: `punctuation.definition.annotations.end${suffix}` },
      },
    },
    'heading-other': {
      match: '^[ \\t]*(#+)[ \\t]*(.*)$',
      name: `markup.heading${suffix}`,
      captures: {
        1: { name: `punctuation.definition.heading${suffix}` },
        2: { name: `entity.name.section.title${suffix}` },
      },
    },

    // -- Trees and lists ---------------------------------------------------
    tree: {
      patterns: [{ include: '#item' }, { include: '#step' }, { include: '#ignored' }],
    },
    item: {
      begin: '^([ \\t]*)(\\d+)(\\.)',
      beginCaptures: {
        2: { name: `constant.numeric.key${suffix}` },
        3: { name: `punctuation.separator.key${suffix}` },
      },
      end: '$',
      name: `meta.item${suffix}`,
      patterns: [{ include: '#annotations' }, { include: '#escape' }],
    },
    step: {
      begin: '^([ \\t]*)(-(?=[ \\t]|$)|\\*(?=[ \\t]))',
      beginCaptures: { 2: { name: `punctuation.definition.list.begin.step${suffix}` } },
      end: '$',
      name: `meta.step${suffix}`,
      patterns: [
        { include: '#condition-else' },
        { include: '#condition' },
        { include: '#annotations' },
        { include: '#escape' },
      ],
    },
    // `If {{answer}} is yes`, `Else if …`, `Otherwise if …`, `Elif …`
    condition: {
      begin: '\\G[ \\t]*((?i:else[ \\t]+if|otherwise[ \\t]+if|elif|if))(?=[ \\t]|:|$)',
      beginCaptures: { 1: { name: `keyword.control.conditional${suffix}` } },
      end: `(?=\\[${FINAL_GROUP})|$`,
      name: `meta.condition${suffix}`,
      patterns: [
        { match: `:(?=[ \\t]*(?:\\[${FINAL_GROUP}|$))`, name: `punctuation.separator.condition${suffix}` },
        { match: '"(?:[^"\\\\]|\\\\.)*"', name: `string.quoted.double${suffix}` },
        { match: '\'[^\']*\'', name: `string.quoted.single${suffix}` },
        { include: 'source.keybownotes.tags' },
        {
          match: `(?<=[ \\t])(?i:${anyOf(vocabulary.conditionOperators.filter((word) => /^[a-z]/i.test(word)))})(?=[ \\t]|$)`,
          name: `keyword.operator.wordlike${suffix}`,
        },
        {
          match: anyOf(vocabulary.conditionOperators.filter((word) => !/^[a-z]/i.test(word))),
          name: `keyword.operator.comparison${suffix}`,
        },
      ],
    },
    'condition-else': {
      match: '\\G[ \\t]*((?i:else|otherwise))[ \\t]*(:)?(?=[ \\t]*(?:\\[|$))',
      captures: {
        1: { name: `keyword.control.conditional${suffix}` },
        2: { name: `punctuation.separator.condition${suffix}` },
      },
    },
    escape: {
      match: '\\\\[\\[\\]]',
      name: `constant.character.escape${suffix}`,
    },

    // -- Annotations: [Calendar, 5 min alert, duration: 1h] ------------------
    annotations: {
      begin: `(\\[)${FINAL_GROUP}`,
      beginCaptures: { 1: { name: `punctuation.definition.annotations.begin${suffix}` } },
      end: '(\\])[ \\t]*$|$',
      endCaptures: { 1: { name: `punctuation.definition.annotations.end${suffix}` } },
      name: `meta.annotations${suffix}`,
      patterns: [
        { include: '#pair-colour' },
        { include: '#pair-type' },
        { include: '#pair-holder' },
        { include: '#pair-field' },
        { include: '#pair' },
        { include: '#word-list' },
        { include: '#word-alert' },
        { include: '#word-link' },
        { include: '#word-template' },
        { include: '#word-keyword' },
        { include: '#word-other' },
        { match: ',', name: `punctuation.separator.annotations${suffix}` },
      ],
    },
    'pair-colour': valueRule('(?i:colou?r)', `support.type.property-name.colour${suffix}`, [
      { match: `\\G#?[0-9A-Fa-f]{6}${scalarEnd}`, name: `constant.other.color.rgb-value${suffix}` },
      { include: '#value' },
    ], ''),
    'pair-type': valueRule('type', `support.type.property-name.type${suffix}`, [
      { match: `\\G(?:${anyOf(types)})${scalarEnd}`, name: `support.type.action${suffix}` },
      { include: '#value' },
    ], ''),
    'pair-holder': valueRule(anyOf(holders), `support.type.property-name.field${suffix}`, [
      { match: `\\G(?i:${anyOf(keywords)})${scalarEnd}`, name: `keyword.other.action${suffix}` },
      { match: `\\G(?:${anyOf(types)})${scalarEnd}`, name: `support.type.action${suffix}` },
      { include: '#value' },
    ], ''),
    'pair-field': valueRule(`(?:(?:${anyOf(holders)})\\.)?(?:${anyOf([...fieldKeys, 'instant'])})(?![\\p{L}\\p{N}._-])`,
      `support.type.property-name.field${suffix}`, [{ include: '#scalar' }, { include: '#value' }]),
    pair: valueRule(KEY, `variable.other.property${suffix}`, [{ include: '#scalar' }, { include: '#value' }]),
    scalar: {
      patterns: [
        { match: `\\G(?:true|false)${scalarEnd}`, name: `constant.language.boolean${suffix}` },
        { match: `\\G-?\\d+(?:\\.\\d+)?${scalarEnd}`, name: `constant.numeric${suffix}` },
      ],
    },
    value: {
      patterns: [
        {
          begin: '"',
          beginCaptures: { 0: { name: `punctuation.definition.string.begin${suffix}` } },
          end: '(")|$',
          endCaptures: { 1: { name: `punctuation.definition.string.end${suffix}` } },
          name: `string.quoted.double${suffix}`,
          patterns: [
            { include: 'source.keybownotes.tags' },
            { match: '\\\\.', name: `constant.character.escape${suffix}` },
          ],
        },
        { include: 'source.keybownotes.tags' },
      ],
    },
    'word-list': {
      match: `${ITEM_START}(@)([^,\\]]*?)${ITEM_END}`,
      captures: {
        1: { name: `punctuation.definition.list-reference${suffix}` },
        2: { name: `variable.other.list${suffix}` },
      },
    },
    'word-alert': {
      match: `${ITEM_START}(\\d+)[ \\t]*((?i:minutes|minute|mins|min|hours|hour|hrs|hr|h))[ \\t]+((?i:alert))${ITEM_END}`,
      captures: {
        1: { name: `constant.numeric${suffix}` },
        2: { name: `keyword.other.unit${suffix}` },
        3: { name: `keyword.other.action${suffix}` },
      },
    },
    'word-link': {
      match: `${ITEM_START}([\\p{L}][\\p{L}\\p{N}+.-]*://[^,\\]]*?)${ITEM_END}`,
      captures: { 1: { name: `string.other.link${suffix} markup.underline.link${suffix}` } },
    },
    'word-template': {
      match: `${ITEM_START}([^,\\]"]*?\\.(?i:md))${ITEM_END}`,
      captures: { 1: { name: `string.unquoted.template${suffix}` } },
    },
    'word-keyword': {
      match: `${ITEM_START}((?i:${anyOf(keywords)}))${ITEM_END}`,
      captures: { 1: { name: `keyword.other.action${suffix}` } },
    },
    // An app, or a channel in one.
    'word-other': {
      match: `${ITEM_START}([^,\\]"]+?)${ITEM_END}`,
      captures: { 1: { name: `entity.name.type.app${suffix}` } },
    },

    // -- Contacts, projects, defaults ---------------------------------------
    entry: {
      begin: '^([ \\t]*)(-(?=[ \\t]|$)|\\*(?=[ \\t]))[ \\t]*',
      beginCaptures: { 2: { name: `punctuation.definition.list.begin${suffix}` } },
      end: '$',
      name: `meta.entry${suffix}`,
      patterns: [
        {
          match: `\\G((?:[^\\[\\\\]|\\\\.)+?)(?=[ \\t]*(?:\\[${FINAL_GROUP}|$))`,
          captures: { 1: { name: `entity.name.type.entry${suffix}` } },
        },
        { include: '#annotations' },
      ],
    },
    default: {
      begin: `^([ \\t]*)(-|\\*)[ \\t]+(${KEY})[ \\t]*(:)[ \\t]*`,
      beginCaptures: {
        2: { name: `punctuation.definition.list.begin${suffix}` },
        3: { name: `support.type.property-name.default${suffix}` },
        4: { name: `punctuation.separator.key-value${suffix}` },
      },
      end: '$',
      name: `meta.default${suffix}`,
      patterns: [
        { match: '\\G#?[0-9A-Fa-f]{6}[ \\t]*$', name: `constant.other.color.rgb-value${suffix}` },
        { match: '\\G(?:true|false)[ \\t]*$', name: `constant.language.boolean${suffix}` },
        { match: '\\G-?\\d+(?:\\.\\d+)?[ \\t]*$', name: `constant.numeric${suffix}` },
        { match: `\\G(?:${anyOf(types)})[ \\t]*$`, name: `support.type.action${suffix}` },
        { include: '#value' },
      ],
    },

    // Lines the outline doesn't read: kept out of the tree.
    ignored: {
      match: `^(?!${STRUCTURE})[ \\t]*\\S.*$`,
      name: `comment.line.ignored${suffix}`,
    },
  },
};

// ---------------------------------------------------------------------------
// Templates: Markdown, with {{values}} wherever they are
// ---------------------------------------------------------------------------

const template = {
  $schema: 'https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json',
  name: 'KeybowNotes Template',
  scopeName: 'text.html.markdown.keybownotes',
  patterns: [{ include: 'text.html.markdown' }],
  injections: {
    'L:text.html.markdown.keybownotes -comment': { patterns: [{ include: 'source.keybownotes.tags' }] },
  },
};

const write = (name, grammar) => {
  const file = path.join(root, 'syntaxes', name);
  fs.writeFileSync(file, JSON.stringify(grammar, null, 2) + '\n');
  console.log(`wrote ${path.relative(root, file)}`);
};
write('keybownotes-tags.tmLanguage.json', tags);
write('keybownotes.tmLanguage.json', outline);
write('keybownotes-template.tmLanguage.json', template);
