// What the browser capability injects into every page of a session's browser.
//
// It is page-agent's page controller (github.com/alibaba/page-agent, MIT) and a
// thin wrapper. The controller does the hard part — finding what on a page can
// be clicked or typed into, numbering it, and driving it with real pointer and
// input events — and it runs entirely inside the page, which is the only kind of
// browser automation iOS allows: there is no Chromium here, so nothing that
// speaks CDP or WebDriver can work.
//
// It runs in its own content world (BrowserAgent.swift), so the page's scripts
// can neither see `__dshBrowser` nor replace it. The DOM is shared, which is all
// the controller needs.
//
// While the agent works, the page shows page-agent's own effects: its mask (an
// animated glow and a pointer that moves to what is clicked) and its panel (what
// the agent is doing, the steps so far, and a stop button). The app decides when
// (`presence`); the page tells the app when the user takes over or presses stop.
import { PageController } from 'page-controller';
import { cleanUpHighlights } from 'page-controller-dom';
import { Panel } from 'page-agent-ui';

// The controller numbers elements by drawing labelled boxes over them. The
// numbers are what the agent needs; the boxes would stay on the user's page, so
// they come off as soon as the reading is done.
const controller = new PageController({ enableMask: true });

// page-agent's mask blocks the page while its agent works. Here the user may
// take over at any moment, so every touch goes through it to the page.
const through = document.createElement('style');
through.setAttribute('data-page-agent-ignore', 'true');
through.textContent = '#page-agent-runtime_simulator-mask{pointer-events:none!important}';
(document.head || document.documentElement).appendChild(through);

const wait = (seconds) => new Promise((resolve) => setTimeout(resolve, seconds * 1000));

function post(message) {
  try {
    globalThis.webkit.messageHandlers.dshPointer.postMessage(message);
  } catch {
    // An older app: nothing to tell.
  }
}

// ---- The panel, fed by the app rather than by page-agent's own agent ----

/** The names page-agent's panel knows its tools by, for its "clicking [3]…" lines. */
const tools = { click: 'click_element_by_index', type: 'input_text', select: 'select_dropdown_option', scroll: 'scroll' };

class Agent extends EventTarget {
  status = 'idle';
  lastResult = null;
  history = [];
  task = '';
  onAskUser = undefined;
  // Tasks come from the conversation, not from the page.
  execute() { return Promise.resolve(); }
  async stop() { post({ kind: 'stop' }); }
  // ✕ once the agent is done: the panel goes, the page stays.
  dispose() { panel.hide(); }

  set(status) {
    if (this.status === status) return;
    this.status = status;
    this.lastResult = status === 'completed' ? { success: true } : null;
    this.dispatchEvent(new Event('statuschange'));
  }

  activity(detail) { this.dispatchEvent(new CustomEvent('activity', { detail })); }

  step(name, input, output) {
    this.history = [...this.history, { type: 'step', stepIndex: this.history.length, action: { name, input, output } }];
    this.dispatchEvent(new Event('historychange'));
  }
}

const agent = new Agent();
const zh = (navigator.language || '').toLowerCase().startsWith('zh');
const panel = new Panel(agent, { language: zh ? 'zh-CN' : 'en-US', promptForNextTask: false });
let hiding = null;

/**
 * What the app wants shown. `shown` false with `done` is the agent's turn
 * ending: the panel says so for a moment, then everything goes. Without `done`
 * the user took over, and everything goes at once.
 */
async function presence({ shown, action, done }) {
  clearTimeout(hiding);
  if (shown) {
    agent.set('running');
    panel.show();
    await controller.showMask();
    // Clicks, typing, choosing and scrolling say so themselves, with the element (`act`).
    if (!action) agent.activity({ type: 'thinking' });
    else if (!tools[action]) agent.activity({ type: 'executing', tool: action, input: {} });
    return;
  }
  await controller.hideMask();
  if (done && agent.status === 'running') {
    agent.set('completed');
    hiding = setTimeout(() => panel.hide(), 2500);
  } else {
    agent.set('idle');
    panel.hide();
  }
}

// A finger on the page (not on the panel) is the user taking over.
addEventListener('pointerdown', (event) => {
  if (!event.isTrusted || agent.status !== 'running') return;
  if (panel.wrapper.contains(event.target)) return;
  post({ kind: 'takeover' });
}, true);

// ---- Operations ----

/** The page as text, with every interactive element numbered. */
async function read() {
  const state = await controller.getBrowserState();
  cleanUpHighlights();
  return state;
}

/**
 * Run one controller action. A number from an earlier page, or before the first
 * read on this one, comes back as the controller's own explanation.
 */
async function act(name, input, run) {
  agent.activity({ type: 'executing', tool: tools[name] ?? name, input });
  let result;
  try {
    result = await run();
  } catch (error) {
    result = { success: false, message: `${name}: ${error?.message ?? error}` };
  }
  agent.step(tools[name] ?? name, input, result.message ?? '');
  agent.activity({ type: 'executed', tool: tools[name] ?? name, input, output: result.message ?? '', duration: 0 });
  return result;
}

function element(index) {
  const node = controller.selectorMap?.get(index)?.ref;
  return node?.nodeType === 1 ? node : null;
}

/** Move page-agent's pointer to an element, as its clicks do on their own. */
async function point(target, press) {
  const rect = target.getBoundingClientRect();
  const detail = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  dispatchEvent(new CustomEvent('PageAgent::MovePointerTo', { detail }));
  await wait(0.3);
  if (press) dispatchEvent(new CustomEvent('PageAgent::ClickPointer'));
}

async function select(index, option) {
  const menu = element(index);
  if (menu) {
    menu.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    await point(menu, true);
  }
  return act('select', { index, text: option }, () => controller.selectOption(index, option));
}

async function scroll(down, pages, pixels, index) {
  const target = index === undefined ? null : element(index);
  if (target) await point(target, false);
  return act('scroll', { index }, () => controller.scroll({ down, numPages: pages, pixels, index }));
}

globalThis.__dshBrowser = Object.freeze({
  read,
  click: (index) => act('click', { index }, () => controller.clickElement(index)),
  type: (index, text) => act('type', { index, text }, () => controller.inputText(index, text)),
  select,
  scroll,
  presence,
  /** Whether this page has been read since it loaded: numbers mean nothing before that. */
  indexed: () => controller.selectorMap?.size > 0,
});
