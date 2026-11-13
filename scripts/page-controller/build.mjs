// Bundle entry.js and page-agent's page controller into one script a WKWebView
// can inject. Run by scripts/build-page-controller.sh, which fetches both
// esbuild and the pinned page-agent source.
//
//   node build.mjs <esbuild entry module> <page-controller src dir> <out file>
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [esbuildPath, source, out] = process.argv.slice(2);
const { build } = await import(pathToFileURL(esbuildPath).href);
const here = dirname(fileURLToPath(import.meta.url));

const license = await readFile(join(source, '..', '..', '..', 'LICENSE'), 'utf8');

await build({
  entryPoints: [join(here, 'entry.js')],
  outfile: out,
  bundle: true,
  format: 'iife',
  // WKWebView on the oldest iOS the app supports.
  target: 'safari17',
  minify: true,
  legalComments: 'none',
  // page-agent's own tsconfig targets a newer ES than esbuild knows; the target above is what counts.
  tsconfigRaw: {},
  alias: {
    'page-controller': join(source, 'PageController.ts'),
    'page-controller-dom': join(source, 'dom', 'index.ts'),
  },
  plugins: [{
    // The mask is page-agent's overlay that stops the user touching the page
    // while its own agent works. Here the user watches and may take over at any
    // time, so it is left out — and with it the CSS modules and animation
    // library it pulls in.
    name: 'no-mask',
    setup(b) {
      b.onResolve({ filter: /\/mask\/SimulatorMask$/ }, () => ({ path: 'mask', namespace: 'no-mask' }));
      b.onLoad({ filter: /.*/, namespace: 'no-mask' }, () => ({ contents: 'export class SimulatorMask {}', loader: 'js' }));
    },
  }],
  banner: {
    js: `/*! Built by scripts/build-page-controller.sh — do not edit.\n`
      + ` * Contains @page-agent/page-controller (https://github.com/alibaba/page-agent).\n`
      + ` * ${license.trim().split('\n').join('\n * ')}\n *\n`
      + ` * Its DOM extraction is ported from browser-use (https://github.com/browser-use/browser-use),\n`
      + ` * MIT License, Copyright (c) 2024 Gregor Zunic, under the same terms as above.\n */`,
  },
  // The controller logs every step; the page's console is the user's, not ours.
  drop: ['console', 'debugger'],
});
