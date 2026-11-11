// The workbench terminal's line editor. iOS has no pty and no readline, so the
// terminal (plugins/subprocess-ios) reads keys itself: this keeps the line, the
// cursor and the history, and redraws with cursor movement that stays right
// when the line wraps or holds double-width characters.

/** Split terminal input into keys: one character each, or a whole escape sequence (SS3 arrows read as CSI). */
export function* keys(data) {
  const chars = [...data];
  for (let i = 0; i < chars.length; i++) {
    const introducer = chars[i] === '\x1b' ? chars[i + 1] : undefined;
    if (introducer !== '[' && introducer !== 'O') { yield chars[i]; continue; }
    let end = i + 2;
    if (introducer === '[') while (end < chars.length && !(chars[end] >= '@' && chars[end] <= '~')) end++;
    yield `\x1b[${chars.slice(i + 2, end + 1).join('')}`;
    i = end;
  }
}

/** Columns a character takes: none for combining marks, two for East Asian wide characters and emoji. */
function width(ch) {
  const c = ch.codePointAt(0);
  if (c < 0x300) return 1;
  if (c <= 0x36f || (c >= 0x200b && c <= 0x200f) || (c >= 0xfe00 && c <= 0xfe0f)) return 0;
  const wide = (c >= 0x1100 && c <= 0x115f) || (c >= 0x2e80 && c <= 0xa4cf) || (c >= 0xac00 && c <= 0xd7a3)
    || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xfe30 && c <= 0xfe6f) || (c >= 0xff00 && c <= 0xff60)
    || (c >= 0xffe0 && c <= 0xffe6) || (c >= 0x1f300 && c <= 0x1faff) || (c >= 0x20000 && c <= 0x3fffd);
  return wide ? 2 : 1;
}

/** Where printing `chars` from column 0 leaves the cursor; `col === cols` is the margin, before the wrap. */
function place(chars, cols) {
  let row = 0;
  let col = 0;
  for (const ch of chars) {
    const w = width(ch);
    if (col + w > cols) { row++; col = 0; }
    col += w;
  }
  return { row, col };
}

const SGR = /\x1b\[[0-9;]*m/g;

export class LineEditor {
  line = [];
  cursor = 0;
  history = [];
  /** Which history entry is shown; `history.length` is the line being typed. */
  shown = 0;
  draft = [];
  /** The cursor's screen row, counted from the row the prompt starts on. */
  row = 0;
  /** The line ends exactly at the margin, so the cursor already sits on a fresh row. */
  wrapped = false;

  /**
   * `write` prints to the terminal, `prompt` returns the prompt, `submit` takes an entered
   * line, `end` is ctrl-D on an empty line, and `complete(word, first)` lists what a word
   * can become (`first`: it is the command name).
   */
  constructor({ cols, write, prompt, submit, end, complete }) {
    Object.assign(this, { cols: cols || 80, write, prompt, submit, end, complete });
  }

  /** A new prompt on the current row. */
  start() {
    this.line = [];
    this.cursor = 0;
    this.shown = this.history.length;
    this.row = 0;
    this.redraw();
  }

  redraw() {
    const prompt = this.prompt();
    const head = [...prompt.replace(SGR, '')];
    const end = place([...head, ...this.line], this.cols);
    const at = place([...head, ...this.line.slice(0, this.cursor)], this.cols);
    let out = `${this.row > 0 ? `\x1b[${this.row}A` : ''}\r\x1b[J${prompt}${this.line.join('')}`;
    // At the margin the terminal holds the cursor on the last column until more is printed.
    this.wrapped = end.col === this.cols;
    if (this.wrapped) { out += '\r\n'; end.row++; }
    if (at.col === this.cols) { at.row++; at.col = 0; }
    if (end.row > at.row) out += `\x1b[${end.row - at.row}A`;
    this.row = at.row;
    this.write(`${out}\x1b[${at.col + 1}G`);
  }

  /** Leave the line on screen and move below it. */
  finish(suffix = '') {
    this.cursor = this.line.length;
    this.redraw();
    this.write(`${suffix}${this.wrapped && !suffix ? '' : '\r\n'}`);
  }

  set(line) {
    this.line = line;
    this.cursor = line.length;
    this.redraw();
  }

  edit(from, to, inserted = []) {
    this.line.splice(from, to - from, ...inserted);
    this.cursor = from + inserted.length;
    this.redraw();
  }

  move(to) {
    this.cursor = Math.min(this.line.length, Math.max(0, to));
    this.redraw();
  }

  recall(step) {
    const next = this.shown + step;
    if (next < 0 || next > this.history.length) return;
    if (this.shown === this.history.length) this.draft = this.line;
    this.shown = next;
    this.set(next === this.history.length ? this.draft : [...this.history[next]]);
  }

  /** Complete the word before the cursor as far as its candidates agree; list them when that adds nothing. */
  completeWord() {
    let start = this.cursor;
    while (start > 0 && (this.line[start - 1] !== ' ' || this.line[start - 2] === '\\')) start--;
    const word = this.line.slice(start, this.cursor).join('').replaceAll('\\ ', ' ');
    const found = this.complete(word, this.line.slice(0, start).every((ch) => ch === ' '));
    if (found.length === 0) return;
    const first = [...found[0]];
    let shared = first.length;
    for (const candidate of found) {
      const chars = [...candidate];
      let same = 0;
      while (same < shared && chars[same] === first[same]) same++;
      shared = same;
    }
    let text = first.slice(0, shared).join('');
    if (text.length > word.length || found.length === 1) {
      text = text.replaceAll(' ', '\\ ');
      if (found.length === 1 && !text.endsWith('/')) text += ' ';
      this.edit(start, this.cursor, [...text]);
      return;
    }
    const at = this.cursor;
    this.finish();
    this.write(`${found.map((c) => c.replace(/^.*\/(?=.)/, '')).join('  ')}\r\n`);
    this.row = 0;
    this.move(at);
  }

  press(key) {
    const { line, cursor } = this;
    switch (key) {
      case '\r': case '\n': {
        this.finish();
        const text = line.join('');
        if (text.trim() && text !== this.history.at(-1)) this.history.push(text);
        this.submit(text);
        break;
      }
      case '\x7f': case '\b': if (cursor > 0) this.edit(cursor - 1, cursor); break;
      case '\x1b[3~': if (cursor < line.length) this.edit(cursor, cursor + 1); break;
      case '\x1b[D': case '\x02': this.move(cursor - 1); break;
      case '\x1b[C': case '\x06': this.move(cursor + 1); break;
      case '\x1b[A': case '\x10': this.recall(-1); break;
      case '\x1b[B': case '\x0e': this.recall(1); break;
      case '\x1b[H': case '\x1b[1~': case '\x01': this.move(0); break;
      case '\x1b[F': case '\x1b[4~': case '\x05': this.move(line.length); break;
      case '\x15': this.edit(0, cursor); break;
      case '\x0b': this.edit(cursor, line.length); break;
      case '\x17': {
        let start = cursor;
        while (start > 0 && line[start - 1] === ' ') start--;
        while (start > 0 && line[start - 1] !== ' ') start--;
        this.edit(start, cursor);
        break;
      }
      case '\x0c': this.write('\x1b[H\x1b[2J'); this.row = 0; this.redraw(); break;
      // Esc alone drops what was typed.
      case '\x1b': if (line.length) this.set([]); break;
      case '\t': this.completeWord(); break;
      case '\x03': this.finish('^C'); this.start(); break;
      case '\x04': if (line.length === 0) this.end(); break;
      default: if (key >= ' ' && key[0] !== '\x1b') this.edit(cursor, cursor, [key]);
    }
  }
}
