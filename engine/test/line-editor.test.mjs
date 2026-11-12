// The terminal's line editor, checked against a real emulator: what matters is
// what the screen shows and where the cursor sits after each key.
import test from 'node:test';
import assert from 'node:assert/strict';
import xterm from '@xterm/headless';
import { LineEditor, keys } from '../runtime/line-editor.mjs';

const UP = '\x1b[A', DOWN = '\x1b[B', RIGHT = '\x1b[C', LEFT = '\x1b[D';

/** An editor printing to a `cols`-wide screen; `type` presses keys, `screen` reads rows and cursor. */
function setup(cols = 20, complete = () => []) {
  const term = new xterm.Terminal({ cols, rows: 8, allowProposedApi: true });
  let written = Promise.resolve();
  const lines = [];
  const editor = new LineEditor({
    cols,
    write: (text) => { written = written.then(() => new Promise((done) => term.write(text, done))); },
    prompt: () => '\x1b[32mws\x1b[0m $ ',
    submit: (text) => { lines.push(text); editor.start(); },
    end: () => lines.push(null),
    complete,
  });
  editor.start();
  return {
    lines,
    type: (data) => { for (const key of keys(data)) editor.press(key); },
    async screen() {
      await written;
      const buffer = term.buffer.active;
      const rows = [];
      for (let y = 0; y < 8; y++) rows.push(buffer.getLine(y).translateToString(true).trimEnd());
      while (rows.at(-1) === '') rows.pop();
      return { rows, cursor: [buffer.cursorY, buffer.cursorX] };
    },
  };
}

test('input splits into characters and whole escape sequences', () => {
  assert.deepEqual([...keys(`a${UP}\x1bOB\x1b\x1b[3~中\r`)], ['a', UP, DOWN, '\x1b', '\x1b[3~', '中', '\r']);
});

test('left and right move the cursor, typing inserts there', async () => {
  const t = setup();
  t.type(`echo ac${LEFT}b`);
  assert.deepEqual(await t.screen(), { rows: ['ws $ echo abc'], cursor: [0, 12] });
  t.type(`${RIGHT}${RIGHT}${RIGHT}d\x1b[H`);
  assert.deepEqual(await t.screen(), { rows: ['ws $ echo abcd'], cursor: [0, 5] });
  t.type('\x1b[3~\x1b[Fe\r');
  assert.deepEqual(t.lines, ['cho abcde']);
});

test('up and down walk the history and bring the typed line back', async () => {
  const t = setup();
  t.type('first\rsecond\rdra');
  t.type(`${UP}${UP}${UP}`);
  assert.deepEqual((await t.screen()).rows.at(-1), 'ws $ first');
  t.type(DOWN);
  assert.deepEqual((await t.screen()).rows.at(-1), 'ws $ second');
  t.type(DOWN);
  assert.deepEqual(await t.screen(), { rows: ['ws $ first', 'ws $ second', 'ws $ dra'], cursor: [2, 8] });
  t.type(`${DOWN}ft\r`);
  assert.deepEqual(t.lines, ['first', 'second', 'draft']);
});

test('editing a line that wraps keeps every row and the cursor right', async () => {
  const t = setup(10);
  t.type('0123456789abc');
  assert.deepEqual(await t.screen(), { rows: ['ws $ 01234', '56789abc'], cursor: [1, 8] });
  // Backspace from the second row over the wrap, then insert on the first row.
  t.type(`${LEFT.repeat(8)}\x7f\x7f`);
  assert.deepEqual(await t.screen(), { rows: ['ws $ 01256', '789abc'], cursor: [0, 8] });
  t.type('XY');
  assert.deepEqual(await t.screen(), { rows: ['ws $ 012XY', '56789abc'], cursor: [1, 0] });
  t.type('\x15');
  assert.deepEqual(await t.screen(), { rows: ['ws $ 56789', 'abc'], cursor: [0, 5] });
});

test('a line ending at the margin leaves no blank row behind', async () => {
  const t = setup(10);
  t.type('01234');
  assert.deepEqual(await t.screen(), { rows: ['ws $ 01234'], cursor: [1, 0] });
  t.type('\r');
  assert.deepEqual(await t.screen(), { rows: ['ws $ 01234', 'ws $'], cursor: [1, 5] });
});

test('double-width characters are erased whole', async () => {
  const t = setup(10);
  t.type('中文字\x7f');
  assert.deepEqual(await t.screen(), { rows: ['ws $ 中文'], cursor: [0, 9] });
  t.type(`${LEFT}a`);
  assert.deepEqual(await t.screen(), { rows: ['ws $ 中a文'], cursor: [0, 8] });
});

test('esc clears the line; ctrl-C abandons it; ctrl-D ends only an empty one', async () => {
  const t = setup();
  t.type('typo\x1b');
  assert.deepEqual(await t.screen(), { rows: ['ws $'], cursor: [0, 5] });
  t.type('gone\x03kept\x04\r\x04');
  assert.deepEqual(await t.screen(), { rows: ['ws $ gone^C', 'ws $ kept', 'ws $'], cursor: [2, 5] });
  assert.deepEqual(t.lines, ['kept', null]);
});

test('tab completes as far as the candidates agree, then lists them', async () => {
  const files = ['notes.md', 'node_modules/', 'my file.txt'];
  const t = setup(40, (word, first) => (first ? ['cat', 'cd'] : files).filter((name) => name.startsWith(word)));
  t.type('ca\t');
  assert.deepEqual((await t.screen()).rows, ['ws $ cat']);
  t.type('n\t');
  assert.deepEqual(await t.screen(), { rows: ['ws $ cat no'], cursor: [0, 11] });
  t.type('\t');
  assert.deepEqual(await t.screen(), { rows: ['ws $ cat no', 'notes.md  node_modules/', 'ws $ cat no'], cursor: [2, 11] });
  t.type('d\t\x17m\t\r');
  assert.deepEqual(t.lines, ['cat my\\ file.txt ']);
});
