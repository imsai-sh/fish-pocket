---
name: mini-apps
description: Build or fix Fish Pocket Mini Apps in ~/apps, such as launchable utilities, calculators, trackers or games.
---

# Mini apps

The user can keep small web apps in this iOS app: tools, trackers, games. Each one is a folder under `~/apps`. The app lists them under Mini Apps, a row near the top of its Explore tab (a Mini Apps row in the sidebar on an iPad before iOS 18), opens each full screen in a web view of its own, and lets the user put it on the home screen. Opening one does not start you or the engine: it is plain front-end code running in WebKit.

## Where and what

One folder per app: `~/apps/<id>/`. The id is the folder's name and the app's address, `fishapp://<id>/`. Use lower-case letters, digits and hyphens only (`ledger`, `pomodoro-timer`, `2048`). An existing id is an existing app: when making a new one, pick a free id; when changing one, edit its folder.

- `app.json` (required): `{"name": "记账本", "icon": "💰", "color": "#FF9500", "description": "一句话说明"}`. `name` is what the user sees, in the user's language, short (up to about 6 Chinese characters or 12 letters). `icon` is one emoji. `color` is a `#RRGGBB` background for the icon. `description` is one line.
- `icon.png` (optional): a picture of your own for the icon, in place of the emoji. Square, 256 pixels or more a side, drawn to the edges with no transparency and no rounded corners (the app rounds them). Keep `icon` and `color` in `app.json` all the same. Only add one when you can make a good PNG; the emoji is fine otherwise.
- The entry, one of:
  - `App.jsx` (or `App.tsx`): a React component as the default export. The app renders it into `<div id="root">` for you. This is the default choice.
  - `index.html`: a page of your own, for apps that do not use React. `<script type="module" src="./main.js">` and relative paths work.
- Any other files beside them: more `.jsx`/`.tsx`/`.ts`/`.js` modules, `.css`, `.json`, images, audio.

The app ships three examples, `~/apps/days` and `~/apps/pomodoro` (tools) and `~/apps/fruit-flip` (a game), unless the user deleted them. Read one before writing your first app: they show the format, text in the phone's language, and a layout made for a phone.

## Working copy and published copy

Your files are the working copy. The user opens the published copy, which the app makes from them, compiled, when your turn ends (or the first time the app is opened). So the user never sees an app you are halfway through, and your changes reach them once you finish. `.build` and `.build-previous` in the app's folder are those copies: leave them alone, and do not read them for the app's code. The workbench browser at `fishapp://<id>/` shows your working copy as it is now.

## How code runs

- **No build step and no `npm install`.** Do not create `package.json`, Vite or webpack configs. JSX and TypeScript are compiled when the file is loaded. Write ES modules.
- `react`, `react-dom`, `react-dom/client` and `react/jsx-runtime` are React 18.3, built in and offline: `import { useState } from 'react'`.
- Relative imports work: `import { score } from './score.js'`, `import './style.css'` (adds the stylesheet), `import levels from './levels.json'`. Write the extension. No `with { type: 'json' }`.
- Any other package must be a full URL, and then needs the network: `import confetti from 'https://esm.sh/canvas-confetti@1'`. For a package that uses React, add `?external=react,react-dom` so it shares the built-in React. Prefer writing the code yourself: an app with no outside imports always opens, even offline.
- No Tailwind or other CSS frameworks. Write CSS in a `.css` file or inline styles.

## What an app can do

- **Store data** with `localStorage` or IndexedDB. It stays on this phone, private to that app, and survives updates to the app's code. Deleting the app deletes it. Save state as the user goes: they may leave at any moment.
- **Use the network**: `fetch` to public HTTPS APIs works when the server allows cross-origin requests (`Access-Control-Allow-Origin`). The app's origin is `fishapp://<id>`. It has no cookies or sign-ins of the user's, and cannot reach `localhost` or anything on this phone.
- `alert`, `confirm` and `prompt` work. A link to a web page opens in a browser sheet over the app.
- **It cannot** reach the user's files, workspaces or conversations, call you or any model, use the camera or microphone, or send notifications. Do not offer apps that need these. Say what is missing, and build what is possible.

## Make it feel like an app

- It fills the phone screen under a native title bar, which shows `name` and a close button. Do not draw your own title bar or close button.
- From iOS 26 that bar is see-through: the page starts below it and scrolls up beneath it, blurred there by the system. Lay the page out as if the bar were not there: `100dvh` is the height below the bar and `env(safe-area-inset-top)` is 0, so add no top padding for it. Give `html` or `body` a background colour; it shows behind the bar.
- Design for a phone held upright first: 375 to 430 points wide. Touch targets at least 44 points. No hover-only controls.
- Use the system font (`-apple-system, system-ui`). Support dark mode with `@media (prefers-color-scheme: dark)` unless the app has its own fixed look.
- Respect the bottom safe area: `padding-bottom: env(safe-area-inset-bottom)` on fixed bottom bars.
- Avoid `position: fixed` layouts that break when the keyboard opens. Use `100dvh`, not `100vh`.
- Text in the user's language.

## Check before you hand it over

Run the checker, and fix what it reports until it passes:

```
node /opt/dsh/nodejs-project/skills/mini-apps/scripts/check.mjs <id>
```

It reads `app.json`, compiles every module with the same compiler the app uses, and resolves every import. Do not install React, esbuild, Sucrase or a bundler, and do not write a preview page or start a server: the app itself can be opened.

To see it running, load `browser-cli`, run `browser open fishapp://<id>/` and take a screenshot. That is the real app, served the way the user's phone serves it. Run-time errors are in the page's console. Its storage there belongs to the browser, not to the user's copy, so what you click or save while testing does not reach the user.

If the app fails when the user opens it, they see the error with a button that starts a new conversation asking you to fix it, with the error and the app's path.

## Tell the user

When the app is written, end your reply with a link to it **on a line of its own**, which the app shows as a card with an 打开 (Open) button:

```
[记账本](fishapp://ledger)
```

Mention once that it is under Mini Apps at the top of the app's Explore tab and can go on the home screen from the app's ··· menu. Do not explain the folder layout unless asked.

## Changing an app

Edit the files in its folder; the next time it opens, it runs the new code with its stored data kept. If the stored data's shape changes, migrate it in code (read the old shape, write the new) rather than losing what the user saved. To rename it or change its icon, edit `app.json`. End with the same link line.
