// Bundle entry.js with page-agent's page controller, its mask (the animated
// glow and pointer it draws while an agent works) and its panel into one
// script a WKWebView can inject. Run by scripts/build-page-controller.sh, which
// fetches esbuild, ai-motion and the pinned page-agent source.
//
//   node build.mjs <esbuild entry module> <page-agent packages dir> <node_modules> <out file>
import { readFile, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [esbuildPath, packages, modules, out] = process.argv.slice(2);
const { build } = await import(pathToFileURL(esbuildPath).href);
const here = dirname(fileURLToPath(import.meta.url));

const license = await readFile(join(packages, '..', 'LICENSE'), 'utf8');
const motionLicense = await readFile(join(modules, 'ai-motion', 'LICENSE'), 'utf8').catch(() => 'MIT License');

// The CSS the mask and panel import comes out beside the script; it goes into
// the page as a style element when the script runs.
const scratch = join(dirname(out), '.page-controller-build');
const result = await build({
  entryPoints: [join(here, 'entry.js')],
  outdir: scratch,
  bundle: true,
  write: false,
  format: 'iife',
  // WKWebView on the oldest iOS the app supports.
  target: 'safari17',
  minify: true,
  legalComments: 'none',
  // page-agent's own tsconfig targets a newer ES than esbuild knows; the target above is what counts.
  tsconfigRaw: {},
  nodePaths: [modules],
  loader: { '.module.css': 'local-css', '.css': 'css', '.svg': 'dataurl' },
  alias: {
    'page-controller': join(packages, 'page-controller', 'src', 'PageController.ts'),
    'page-controller-dom': join(packages, 'page-controller', 'src', 'dom', 'index.ts'),
    'page-agent-ui': join(packages, 'ui', 'src', 'index.ts'),
  },
  // The controller logs every step; the page's console is the user's, not ours.
  drop: ['console', 'debugger'],
});
await rm(scratch, { recursive: true, force: true });

const js = result.outputFiles.find((file) => file.path.endsWith('.js')).text;
const css = result.outputFiles.find((file) => file.path.endsWith('.css'))?.text ?? '';
const style = `(()=>{const s=document.createElement("style");s.setAttribute("data-page-agent-ignore","true");`
  + `s.textContent=${JSON.stringify(css)};(document.head||document.documentElement).appendChild(s)})();`;

const banner = `/*! Built by scripts/build-page-controller.sh — do not edit.\n`
  + ` * Contains @page-agent/page-controller and @page-agent/ui (https://github.com/alibaba/page-agent).\n`
  + ` * ${license.trim().split('\n').join('\n * ')}\n *\n`
  + ` * Its DOM extraction is ported from browser-use (https://github.com/browser-use/browser-use),\n`
  + ` * MIT License, Copyright (c) 2024 Gregor Zunic, under the same terms as above.\n *\n`
  + ` * Contains ai-motion (https://www.npmjs.com/package/ai-motion):\n`
  + ` * ${motionLicense.trim().split('\n').join('\n * ')}\n */`;

const { writeFile } = await import('node:fs/promises');
await writeFile(out, `${banner}\n${style}\n${js}`);
