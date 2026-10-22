// The outline language's words, from data/vocabulary.json — which
// `keybow vocabulary` writes from the app's own descriptions.

const fs = require('fs');
const path = require('path');

/** Words every action takes, beside its own fields. */
const COMMON_FIELDS = [
  {
    key: 'colour', title: 'Colour', kind: 'colour',
    help: "The key's light, rrggbb. Inherited by the keys under it.\nExample: 0060ff",
  },
  {
    key: 'instant', title: 'Run at once', kind: 'flag',
    help: 'true: run the moment the key is pressed, with no time to cancel. false: wait, where something would otherwise skip it.',
  },
  {
    key: 'type', title: 'Type', kind: 'type',
    help: 'The action type by its full name, for types without a keyword.\nExample: type: shortcut',
  },
];

/** Section headings, as the tree editor writes them. */
const SECTIONS = [
  { label: 'row 2', detail: 'The tree that starts on row 2', insert: 'row 2' },
  { label: 'row 3', detail: 'The tree that starts on row 3', insert: 'row 3' },
  { label: 'bottom', detail: 'The tree that starts on row 4, upwards', insert: 'bottom' },
  { label: 'main', detail: 'The main tree, on row 1 (also what comes before any heading)', insert: 'main' },
  { label: 'list', detail: 'Nodes to reuse with [@name]', insert: 'list ', retrigger: false },
  { label: 'keypad', detail: "Another keypad's trees: # keypad Name [RGB Keypad]", insert: 'keypad ' },
  { label: 'contacts', detail: 'People: - Name [phone: …, email: …]', insert: 'contacts' },
  { label: 'projects', detail: 'Projects: - Name [path: …]', insert: 'projects' },
  { label: 'defaults', detail: 'Settings: - key: value', insert: 'defaults' },
];

const KEYPAD_MODELS = ['Keybow 2040', 'RGB Keypad'];

/** What `# defaults` takes. */
const DEFAULTS = [
  { key: 'colour', help: 'Keys with no colour of their own, rrggbb.' },
  { key: 'commitDelayMs', help: 'After the last key, before the action runs. Default 1000.' },
  { key: 'idleTimeoutMs', help: 'An unfinished choice clears itself after this long. Default 10000.' },
  { key: 'longPressCancelMs', help: 'Holding a key this long clears the choice. Default 1500.' },
  { key: 'dates.todayOffsetMinutes', help: '"today" means this many minutes from now. Default 30.' },
  { key: 'dates.roundToMinutes', help: '"today" is rounded up to this. Default 5.' },
  { key: 'dates.defaultTime', help: 'The time other days start at. Default 09:00.' },
  { key: 'notes.account', help: 'The Notes account, by name.\nExample: iCloud' },
  { key: 'action.type', help: 'The action for keys whose path names no type. Default notes.create.' },
];

/** What a contact or a project usually holds. */
const ENTRY_FIELDS = {
  contacts: [
    { key: 'phone', help: 'Their phone number: {{contact.phone}}.' },
    { key: 'email', help: 'Their email address: {{contact.email}}.' },
  ],
  projects: [{ key: 'path', help: "The project's folder: {{project.path}}." }],
};

class Vocabulary {
  constructor(data) {
    this.actions = data.actions;
    this.values = data.values;
    this.conditionOperators = data.conditionOperators;
    this.byType = new Map();
    this.byKeyword = new Map();
    for (const action of this.actions) {
      if (!this.byType.has(action.type)) this.byType.set(action.type, action);
      for (const word of action.keywords) {
        if (!this.byKeyword.has(word.toLowerCase())) this.byKeyword.set(word.toLowerCase(), action.type);
      }
    }
    this.fieldKeys = new Set(this.actions.flatMap((action) => action.fields.map((field) => field.key)));
    for (const field of COMMON_FIELDS) this.fieldKeys.add(field.key);
    this.fieldKeys.add('color');
    this.holders = new Set(this.actions.flatMap((action) =>
      action.fields.filter((field) => field.kind === 'action').map((field) => field.key)));
  }

  /** `Copy` → clipboard.copy. */
  typeForKeyword(word) {
    return this.byKeyword.get(word.trim().toLowerCase());
  }

  /** A type from a keyword or its full name; undefined for one nothing runs. */
  knownType(word) {
    const text = word.trim();
    return this.typeForKeyword(text) ?? (this.byType.has(text) ? text : undefined);
  }

  describe(type) {
    return this.byType.get(type);
  }

  /** The keyword a type is written with. */
  keyword(type) {
    return this.byType.get(type)?.keywords[0];
  }

  /** An action's field — every action's `type` and `instant` too — or a held
   *  one: `ok.text`. */
  isActionField(key) {
    if (this.fieldKeys.has(key)) return true;
    const dot = key.indexOf('.');
    return dot > 0 && this.holders.has(key.slice(0, dot));
  }

  /** The field `key` of `type`, or of any action when the type isn't known. */
  field(key, type) {
    const common = COMMON_FIELDS.find((field) => field.key === key);
    if (common) return common;
    const own = type && this.describe(type)?.fields.find((field) => field.key === key);
    if (own) return own;
    for (const action of this.actions) {
      const field = action.fields.find((candidate) => candidate.key === key);
      if (field) return field;
    }
    return undefined;
  }

  /** The value a name in braces refers to — `leaf`, `contact.discord`,
   *  `home.sensor.x.unit` — or a block's, with `block`. */
  value(name, block = false) {
    const own = name.split(/\s/)[0];
    const given = own.split('.');
    let best;
    for (const entry of this.values) {
      if ((entry.kind === 'block') !== block) continue;
      if (entry.name === own) return entry;
      const parts = entry.name.split('.');
      if (!entry.name.includes('<') || parts.length !== given.length) continue;
      const fits = parts.every((part, index) => (part.startsWith('<') && part.endsWith('>') ? given[index] !== '' : part === given[index]));
      if (!fits) continue;
      const holes = parts.filter((part) => part.startsWith('<')).length;
      if (!best || holes < best.holes || (holes === best.holes && entry.name.length > best.entry.name.length)) {
        best = { entry, holes };
      }
    }
    return best?.entry;
  }
}

let shared;
/** The vocabulary that ships with the extension. */
function load() {
  if (!shared) {
    const file = path.join(__dirname, '..', 'data', 'vocabulary.json');
    shared = new Vocabulary(JSON.parse(fs.readFileSync(file, 'utf8')));
  }
  return shared;
}

module.exports = { Vocabulary, load, COMMON_FIELDS, SECTIONS, KEYPAD_MODELS, DEFAULTS, ENTRY_FIELDS };
