---
name: ios-environment
description: This session runs inside an iOS app, not on a desktop, and many commands do not exist. Load this skill before relying on a shell command you are unsure of, whenever one fails or behaves unexpectedly, and before writing or changing a DSH plugin, because the app's native interface does not run a plugin's browser code.
---

# Working on iOS

You are running inside an iOS app. iOS allows no child processes, so nothing here is a real Unix system: `bash` is an emulator written in JavaScript, and every command below runs inside the app. Your own tools (read, write, edit, search) work normally. This page is about the shell, and what the app can show of a DSH plugin.

Longer topics live in files beside this one, under `references/`. Read one when its section here tells you to: the path is relative to this skill's base directory.

Check here before improvising, and do not retry a command this page says is missing. Installing it will not work either: there is no `apt`, `brew`, or `sudo`, and iOS refuses to run downloaded binaries.

## Commands that exist

Anything not listed here should be assumed missing.

- **Files:** `ls cat cp mv rm mkdir rmdir touch ln chmod stat file du tree find readlink basename dirname mktemp`
- **Text:** `grep egrep fgrep rg sed awk cut sort uniq wc head tail tr tee paste join comm column fold expand unexpand nl rev tac seq printf echo strings od diff split`
- **Data:** `jq yq xan html-to-markdown base64 md5sum sha1sum sha256sum`
- **Archives:** `tar gzip gunzip zcat`
- **Network:** `curl`
- **Development:** `git node pnpm pnpx`
- **Video and audio:** `ffmpeg ffprobe` (see the Video and audio section below)
- **Shell:** `bash sh env printenv which type command date sleep timeout time xargs yes true false expr whoami hostname pwd history alias unalias clear help`

Python and pip also exist: see the Python section below.

## Missing, and what to do instead

| Missing | Use instead |
|---|---|
| `npm`, `npx`, `yarn`, `corepack` | `pnpm`, `pnpx` |
| `bun`, `deno` | `node` |
| `tsc`, `tsx` | `node file.ts` runs TypeScript directly. For a real compile, `pnpm add -D typescript@5` and run `node_modules/.bin/tsc`. TypeScript 7 is native and does not run |
| `ruby`, `perl`, `php`, `lua` | Write the script in Node or Python |
| `gcc`, `clang`, `make`, `cmake`, `cargo`, `go`, `java`, `swift` | Nothing compiles here. Say so, and leave the build to another machine |
| `zip`, `unzip`, `7z`, `xz`, `bzip2` | `tar` and `gzip`, or an npm package such as `fflate` |
| `wget` | `curl` |
| `ssh`, `scp`, `rsync`, `nc`, `ping` | `curl` for HTTP(S). There is no other way to reach a remote machine |
| `uname` | `node -p "process.platform + ' ' + process.arch"` |
| `ps`, `kill`, `killall`, `jobs`, `nohup`, `top`, `lsof`, `df`, `free`, `id` | No equivalent: there is no process table. `timeout <seconds> <command>` bounds a command you are unsure will finish |
| `vim`, `nano`, `less`, `man` | Your file tools for editing; `head` and `sed -n` for reading; `<command> --help` for usage |
| `gh`, `docker` | The GitHub REST API through `curl`. Containers are not possible |
| `sudo`, `su`, `chown`, `apt`, `brew` | Not possible and not needed: you own everything you can write to |
| `sqlite3` | Exists but fails on iOS. Use `node:sqlite` from Node |

## Shell behaviour

Pipes, redirects, `&&`, `||`, variables, arrays, functions, loops, here-documents, `$(...)`, subshells and `[[ ]]` work. Plain bash scripts run. The differences that matter:

- **No live output.** A command's output appears only when it finishes. A single `node`, `pnpm run`, `python3` or `ffmpeg` command is the exception and streams.
- **Nothing is interactive.** There is no TTY. Commands that prompt or open an editor fail or wait forever: pass flags that avoid the prompt.
- **`trap` does nothing.** It is accepted, but no signal arrives and `EXIT` traps do not run. Do not rely on them for cleanup.
- **Heavy shell work blocks the app.** The interpreter shares a thread with the agent. Long `while` loops or a big `sort` or `rg` freeze everything until they finish. Do heavy work in a Node script: it runs on its own thread.
- **`&` does not detach.** The shell returns only after background jobs finish, so `server & curl localhost` still waits for `server`, and nothing survives the command. `wait` works.
- **Run scripts with their interpreter.** `./tool.js` works only as a whole command on its own: in `./tool.js && next`, or in a pipe, the shell tries to parse it as bash and fails. Write `node tool.js`. The same goes for `./tool.py`: write `python3 tool.py`. Scripts in other languages do not run.
- **`xargs` is limited.** `xargs -n 1 cmd` works (with the space); `-n1` and `-I{}` do not. Use a `for` loop when you need placeholders.
- **Reduced file metadata.** `ls -l` may show placeholder owners and dates.
- **`/dev` is only `/dev/null` in the shell.** `> /dev/null` works, but `/dev/urandom` and other devices do not exist there. Use `node:crypto` for random bytes.

## Files

- `$HOME` is `/home/dsh` and `$TMPDIR` is `/tmp`. Both are private to the app and writable, and these paths never change, so they are safe to store.
- The first-use workspace is under `~/Documents`. Workspaces are not visible in the Files app.
- `/` is the app's own tree: `home`, `tmp`, `opt`, plus anything you create. Writing to `/abc` or `/usr/local` works and stays inside the app.
- `/etc`, `/usr/share` and `/System` are the real system and read-only. `/opt/dsh` is the app itself and read-only.
- `/bin` and `/usr/bin` exist only in the shell, for its commands. A Node script does not see them.

## Node

Node 24 runs in jitless mode: pure JavaScript is several times slower than on a desktop, and most work is unaffected.

- `child_process` works, but it reaches this same emulated shell. Only the commands on this page can be spawned.
- `http.createServer` works, and dev servers listen on `127.0.0.1`.
- WebAssembly works but runs interpreted, so wasm tools are slow.
- A plain `node` script can use the filesystem, network, `node:sqlite` and worker threads, and `node file.ts` runs TypeScript.

## Python

Python 3.15 is built into the app: `python`, `python3`, `python3.15`, `pip`, `pip3` and `pip3.15` work, and so do `#!/usr/bin/env python3` scripts run as a whole command. Pure Python runs close to desktop speed. The standard library is complete apart from GUI modules: `sqlite3`, `ssl`, `threading`, `asyncio` and `venv` all work.

- `pip install` works for pure-Python packages. Outside a venv they go to `~/.local`. The first `pip` sets pip itself up, which takes a few seconds.
- `python3 -m venv .venv` works, and so does `source .venv/bin/activate` (for that one command, or for the rest of a terminal session). Its `bin/python`, `bin/pip` and the commands pip installs (`bin/black`, `bin/pytest`…) run anywhere in a command line.
- **Packages with compiled extensions do not work**: `numpy`, `pandas`, `Pillow`, `lxml`, `torch`, `cryptography` and the like. pip fails to build them, or they fail to import. Say so instead of retrying, and look for a pure-Python alternative.
- **`subprocess` runs only Python.** From Python, `subprocess.run([sys.executable, …])` and `python3 …` work; any other program (`git`, `ls`, a shell) raises `FileNotFoundError`. So does `multiprocessing`. Use Python's own modules (`shutil`, `pathlib`, `glob`) instead of shelling out.
- **No interactive Python.** `python3` with no script reads its program from stdin; there is no prompt, and `input()` gets only what was piped in.
- `uv`, `poetry` and `conda` are native programs and do not exist: use `pip` and `venv`.

## Video and audio

FFmpeg 9.0 is built into the app: `ffmpeg` and `ffprobe` work as on a desktop for inspecting, cutting, converting and analysing media files.

- **Reads nearly everything:** MP4 and MOV (iPhone HEVC included), MKV, WebM, AVI, MPEG-TS, FLV, WAV, MP3, FLAC, Ogg, Opus, images and subtitle files. All of FFmpeg's built-in filters work: `scale`, `crop`, `fps`, `select`, `tile`, `volumedetect`, `silencedetect`, `loudnorm` and the rest. `-f null -` works for analysis.
- **H.264 and HEVC come from the phone's hardware encoder:** `-c:v h264_videotoolbox -b:v 4M`, or `hevc_videotoolbox`. H.264 is the default for `.mp4`, `.mov` and `.mkv`. Set a bitrate: `-crf` and `-preset` do not apply. `mjpeg`, `png`, `gif`, `mpeg4`, `prores_ks` and `ffv1` also encode. Audio: `aac`, `flac`, `alac`, `pcm_s16le` (WAV).
- **Not built in:** `libx264`, `libx265`, `libvpx`, `libaom`, `libmp3lame`. So there is no VP8, VP9, AV1 or MP3 encoding, and `.webm` and `.mp3` cannot be written. Write H.264 MP4 and AAC `.m4a` instead. Filters that need outside libraries do not exist either: `subtitles`/`ass` (burning in subtitles) and `drawtext`. Neither does `-f lavfi` as an input.
- **Work with files, by path.** There is no network input: download with `curl` first. Do not pipe media through the shell: in a pipe or a `<` redirect, binary data is corrupted. Writing to stdout (`-f wav -`) works only as a whole command on its own.
- **Pass `-y` to overwrite.** Nothing prompts. Without it ffmpeg stops at an existing file, and still exits 0.
- **One at a time.** A second `ffmpeg` or `ffprobe` waits until the running one finishes. Stopping a command stops `ffmpeg` cleanly; `ffprobe` runs to its end.
- **Only from the shell.** Python's `subprocess` cannot run it, so packages that call `ffmpeg` (`moviepy`, `pydub`) do not work. Run `ffmpeg` in a command instead.
- Decoding runs on the CPU. For long or 4K videos, limit the work with `-ss`, `-t` and `fps=`.

## Packages

- `pnpm add`, `pnpm install`, `pnpm run` and `pnpx` work, and pure JavaScript packages are fine. `pnpm add` creates `package.json` if there is none.
- **Do not run `pnpm init`, and remove a `packageManager` field.** With that field in `package.json` every pnpm command fails with "ships no native binary for ios-arm64". `pnpm init` writes it, and many projects already have it. Delete the field (tell the user you did), and pnpm works again.
- **Packages with native binaries do not work.** Anything shipping a `.node` addon or a platform executable (`esbuild`, `sharp`, `better-sqlite3`, `swc`, Turbopack, TypeScript 7) installs but fails when used, typically with "Unsupported platform: ios arm64". Say so instead of retrying. Next.js needs `next dev --webpack`; `esbuild-wasm` does not work either, because it needs a child process.
- **A DSH plugin's Host code gets a partial `sharp`.** Inside the engine `sharp` is a stand-in over iOS's ImageIO: `metadata()`, `rotate()` with no arguments, `resize({ width, height, fit: 'inside', withoutEnlargement })`, `toColourspace('srgb')`, `jpeg({ quality })`, `raw()`, `clone()` and `toBuffer()`, on Buffer input. Anything else, including WebP and PNG output, throws `sharp: … is not supported on iOS`. It reports `hasAlpha: false` for every image and flattens transparency onto white. A plain `node` script does not get it.
- Install scripts do not run. `pnpm` may print `ERR_PNPM_IGNORED_BUILDS` afterwards: the package is still installed.

## DSH plugins

The app's native interface, built in SwiftUI, does not run a plugin's browser code. Only a plugin's Host half (tools, settings) works there; its pages, panels and sidebar entries appear only in the web interface, under Settings → 网页版. **Before writing, changing or diagnosing a DSH plugin, read `references/plugins.md`**: what reaches which interface, what to tell the user before building, the built-in DS Bot plugin, and why device capabilities are not for plugins.

Services the user has connected under 连接器 in the sidebar (GitHub, Notion and the like) are MCP tools in every session, named `mcp__<id>__*`. If a task needs one you do not have, ask the user to connect it there; you cannot connect one yourself.

## git

`git` is built in, on libgit2. Its output matches real git, so read it as usual.

**Works:** `init clone fetch pull push status add rm mv commit log show diff rev-list shortlog diff-tree branch checkout switch restore reset merge tag stash clean apply remote ls-remote worktree config rev-parse ls-files ls-tree cat-file write-tree check-ignore hash-object merge-base show-ref symbolic-ref check-ref-format whatchanged`

**Not available:**

| Command | Use instead |
|---|---|
| `rebase` | `git merge`, or `git pull --no-rebase` |
| squashing history | `git reset --soft <base>`, then `git commit` |
| `cherry-pick` | `git diff <commit>~1 <commit> \| git apply --index`, then `git commit` |
| `revert` | Undo the change in the files and commit |
| `blame` | `git log -p -- <file>` |
| `git grep` | `rg` |
| `bisect`, `submodule`, `am`, `format-patch`, `reflog`, `describe`, `notes`, `sparse-checkout`, `filter-branch`, `lfs` | Not available |

**Rules:**

- Always pass `-m` or `-F` to `commit` and `tag -a`: there is no editor. `commit --amend` and `--no-edit` reuse the existing message, and concluding a merge reuses `MERGE_MSG`.
- Nothing interactive: no `add -p`, `rebase -i`, or `checkout -p`.
- Remotes are **HTTPS only**. Rewrite `git@github.com:a/b.git` as `https://github.com/a/b.git`. SSH cannot work here.
- Set an identity before the first commit: `git config --global user.name "…"` and `user.email`.
- For private repositories, credentials come from the URL, from `~/.git-credentials` (`https://user:token@host` lines), or from `GH_TOKEN` / `GITHUB_TOKEN` for github.com. Nothing prompts for them.
- `log --graph` draws a single column, and no branch lines. Submodules are not cloned.
- Large clones take a while and print nothing until they finish.

## Device capabilities

You have tools onto the phone itself. They are not shell commands: `device_info`, `notify`, `open_url`, `text_analysis`, `maps`, `image_analysis`, `clipboard`, `location`, `speak`, `calendar`, `reminders`, `transcribe_audio`, `health`, `photos`, `homekit`, `alarm`, `contacts`, `compose`, `files`, `music`, `weather`, `browser`. **Before using one for the first time in a session, read `references/device-capabilities.md`**: which tool fits which request, what each returns, how writes and permissions work, and what is not built.

Three rules hold even before you read it:

- A capability that needs permission starts switched off, and calling it does not turn it on. It comes back refused; tell the user they can switch it on under Device capabilities in the app's sidebar, and stop.
- A write just happens by default, with no confirmation, and the user can see it afterwards. Say which item you are about to delete before you delete it.
- They are for you, not for plugins: do not build a plugin on them, and do not offer to.

## Web browser

The `browser` tool drives this conversation's own browser: a real WebKit page, the one the user sees under Workbench → Browser. JavaScript runs, so use it where `curl` falls short — pages that render with scripts, logins, forms, anything that takes several clicks — and to look at a site you are building: start its server, then `open` it on `localhost:<port>`.

- `open` and every action return the page as text, with each element you can act on numbered like `[3]`. Pass that number as `index`. Numbers change whenever the page does, so use the ones from the latest result.
- `screenshot` shows the visible part of the page as an image (`fullPage: true` for all of it): use it for layout, pictures and charts, not to read text. It needs a model that takes images; on one that does not it is refused, and `evaluate` can measure what you need instead.
- Beyond clicking and typing: `evaluate` runs a script once; `addScript` keeps one running before the site's own scripts on every page load (to intercept requests or prepare the page), listed by `scripts` and removed by `removeScript`. `logs` returns the page's console output, uncaught errors and the requests its scripts made, recorded all the time.
- `request` sends an HTTP request as this browser — its cookies and user agent, no CORS — and can save the body to a file. `cookies`, `setCookie` and `deleteCookie` reach every cookie, HttpOnly ones and other sites' included. What they return can include sign-in tokens: use them for the task, never repeat them to the user.
- Files: a link or response the page cannot show is downloaded into `downloads/` of the working directory (`downloads` lists them); `upload` puts workspace files into a numbered file field without the picker; `pdf` saves the page as a PDF. Relative paths are from the working directory.
- `type` and `click` are script events, which a site that checks `isTrusted` ignores. `keys` types through the system keyboard instead: the page gets trusted `beforeinput` and `input` events (no `keydown`), and a newline presses Return.
- What it cannot do: real taps (find another way in, such as the data the page embeds), several tabs, or keeping `addScript` scripts across an app restart.
- One page, no tabs: a link that would open a new tab opens in the same page.
- Sites see a phone and usually send their mobile version. For the desktop (PC) version, pass `desktop: true` with `open` or `reload`; `desktop: false` goes back. The choice is kept for that site, and the user can switch it from the browser's menu too.
- Sign-ins are kept across app launches and shared by every conversation's browser, but not with Safari. If a site wants a login, ask the user to sign in in the workbench once. Never type a password, card number or other secret yourself.
- The user can watch and take over at any time; when you stop, say what is on the page.

## Not possible at all

Tell the user plainly rather than attempting these: compiling native code, running containers or virtual machines, starting system services, background daemons that outlive the app, controlling other apps, or anything needing root. Work that needs them belongs on another machine.

The device capabilities above are the exception to "controlling other apps": they are system frameworks the app is allowed to use, not other apps being driven.
