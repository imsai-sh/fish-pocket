// The ios-environment skill is what the agent believes about this shell, so
// what it lists as available has to exist.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { COMMANDS } from '../runtime/shell.mjs';
import { FFMPEG_COMMANDS } from '../runtime/ffmpeg/index.mjs';
import { OPEN_COMMANDS } from '../runtime/open-url.mjs';

const text = fs.readFileSync(new URL('../skills/ios-environment/SKILL.md', import.meta.url), 'utf8');

test('has the frontmatter the skill catalog needs', () => {
  const [, frontmatter] = /^---\n([\s\S]*?)\n---\n/.exec(text);
  assert.match(frontmatter, /^name: ios-environment$/m);
  // tool-skill caps catalog descriptions at 500 characters.
  assert.ok(/^description: (.+)$/m.exec(frontmatter)[1].length <= 500);
});

test('the catalog description sends plugin work here', () => {
  // The skill only loads when its description matches the task at hand.
  assert.match(/^description: (.+)$/m.exec(text)[1], /\bplugin\b/);
});

test('the skill catalog distinguishes phone notifications from scheduled agent work', () => {
  const description = /^description: (.+)$/m.exec(text)[1];
  assert.match(description, /device notify schedule --after-seconds/);
  assert.match(description, /schedule_create/);
});

test('the loaded skill leaves the notification delay and message to the current request', () => {
  const section = /## Device capabilities\n([\s\S]*?)\n## /.exec(text)[1];
  const examples = [...section.matchAll(/`device notify schedule ([^`]+)`/g)].map(match => match[1]);
  assert.deepEqual(examples, ["--after-seconds SECONDS --body 'MESSAGE'"]);
});

test('every command listed as existing exists', () => {
  const section = /## Commands that exist\n([\s\S]*?)\n## /.exec(text)[1];
  const listed = [...section.matchAll(/`([^`]+)`/g)].flatMap((m) => m[1].split(' '));
  assert.ok(listed.length > 80);
  // Shell builtins are not commands of the world.
  const builtin = new Set(['type', 'command']);
  // FFmpeg and open (the native addon) exist in the app only: a development machine has no binding for them.
  const appOnly = new Set([...FFMPEG_COMMANDS, ...OPEN_COMMANDS, 'browser', 'device']);
  assert.deepEqual(listed.filter((name) => !COMMANDS.has(name) && !builtin.has(name) && !appOnly.has(name)), []);
});

test('every reference the skill points to ships with it, and none is left unmentioned', () => {
  // The skill names its longer topics by relative path; the agent reads them from the bundle.
  const mentioned = [...new Set([...text.matchAll(/`(references\/[\w-]+\.md)`/g)].map((m) => m[1]))].sort();
  const shipped = fs.readdirSync(new URL('../skills/ios-environment/references/', import.meta.url)).map((name) => `references/${name}`).sort();
  assert.ok(mentioned.length > 0);
  assert.deepEqual(mentioned, shipped);
});
