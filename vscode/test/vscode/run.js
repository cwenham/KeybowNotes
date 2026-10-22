// Runs suite.js inside VS Code, with this extension and nothing else, on a
// throwaway workspace and settings — so it never touches your own VS Code
// setup. A VS Code window opens for a few seconds and closes.
//   npm run test:vscode
// VSCODE_BINARY picks another VS Code; KEYBOW_TEST_DIR, where the scratch goes.

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const code = process.env.VSCODE_BINARY || '/Applications/Visual Studio Code.app/Contents/MacOS/Code';
const extension = path.resolve(__dirname, '..', '..');
const repository = path.resolve(extension, '..');
const scratch = fs.mkdtempSync(path.join(process.env.KEYBOW_TEST_DIR || os.tmpdir(), 'keybownotes-vscode-'));
const workspace = path.join(scratch, 'workspace');
// VS Code's own settings for the run: a short path, since macOS limits the
// length of the socket VS Code makes in it.
fs.mkdirSync(path.join(extension, '.vscode-test'), { recursive: true });
const profile = fs.mkdtempSync(path.join(extension, '.vscode-test', 'run-'));

/** The sample files: some ours, by name or by what's in them; some not. */
const files = {
  'KeybowNotes/tree.md': fs.readFileSync(path.join(repository, 'docs/examples/showcase.md'), 'utf8'),
  'KeybowNotes/templates/plain.md': 'Nothing to fill in here.\n',
  'elsewhere/my keys.md': fs.readFileSync(path.join(repository, 'mac/tree.demo.md'), 'utf8'),
  'elsewhere/unpaid.md': fs.readFileSync(path.join(repository, 'docs/examples/templates/unpaid.md'), 'utf8'),
  'elsewhere/README.md': fs.readFileSync(path.join(repository, 'README.md'), 'utf8'),
  'elsewhere/shopping.md': '# Shopping\n\nFor the week.\n\n1. Milk [urgent]\n2. Bread\n',
  // For reading the colours VS Code gives, through its own tokeniser.
  'capture/tree.kbtree': fs.readFileSync(path.join(repository, 'docs/examples/showcase.md'), 'utf8'),
  'capture/unpaid.kbtemplate': fs.readFileSync(path.join(repository, 'docs/examples/templates/unpaid.md'), 'utf8'),
};
for (const [name, text] of Object.entries(files)) {
  fs.mkdirSync(path.dirname(path.join(workspace, name)), { recursive: true });
  fs.writeFileSync(path.join(workspace, name), text);
}

const child = spawn(code, [
  workspace,
  `--extensionDevelopmentPath=${extension}`,
  `--extensionTestsPath=${path.join(__dirname, 'suite.js')}`,
  `--user-data-dir=${path.join(profile, 'user')}`,
  `--extensions-dir=${path.join(profile, 'extensions')}`,
  '--disable-extensions',
  '--skip-welcome',
  '--skip-release-notes',
  '--disable-workspace-trust',
  '--new-window',
], { stdio: 'inherit', env: { ...process.env, KEYBOW_TEST_WORKSPACE: workspace } });

child.on('exit', (status) => {
  console.log(status === 0 ? 'VS Code tests passed.' : `VS Code tests failed (${status}).`);
  console.log(`Scratch: ${scratch}`);
  fs.rmSync(profile, { recursive: true, force: true });
  process.exit(status ?? 1);
});
