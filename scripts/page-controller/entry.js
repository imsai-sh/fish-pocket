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
import { PageController } from 'page-controller';
import { cleanUpHighlights } from 'page-controller-dom';

// The controller numbers elements by drawing labelled boxes over them. The
// numbers are what the agent needs; the boxes would stay on the user's page, so
// they come off as soon as the reading is done.
const controller = new PageController({});

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
async function act(name, run) {
  try {
    return await run();
  } catch (error) {
    return { success: false, message: `${name}: ${error?.message ?? error}` };
  }
}

// The pointer the app draws over the page (BrowserAgentOverlay.swift). The app
// draws it natively, over the web view, and lets every touch through, so the
// user can take over at any moment — unlike page-agent's own mask, which is
// left out (build.mjs). The page only says where: as a fraction of what is on
// screen (the visual viewport), which holds however the page is zoomed.
const wait = (seconds) => new Promise((resolve) => setTimeout(resolve, seconds * 1000));

function post(message) {
  try {
    globalThis.webkit.messageHandlers.dshPointer.postMessage(message);
  } catch {
    // An older app, or a page without the handler: nothing is drawn.
  }
}

function onScreen(x, y) {
  const view = globalThis.visualViewport;
  const left = view?.offsetLeft ?? 0;
  const top = view?.offsetTop ?? 0;
  const width = view?.width ?? innerWidth;
  const height = view?.height ?? innerHeight;
  return { x: (x - left) / width, y: (y - top) / height };
}

function centre(element) {
  const rect = element.getBoundingClientRect();
  return onScreen(rect.left + rect.width / 2, rect.top + rect.height / 2);
}

// The controller's clicks (and so typing, which clicks first) announce where they
// land: it moves its pointer, waits 0.3 s, then presses.
addEventListener('PageAgent::MovePointerTo', (event) => {
  const { x, y } = event.detail ?? {};
  if (Number.isFinite(x) && Number.isFinite(y)) post({ kind: 'move', ...onScreen(x, y) });
});
addEventListener('PageAgent::ClickPointer', () => post({ kind: 'press' }));

function element(index) {
  const node = controller.selectorMap?.get(index)?.ref;
  return node?.nodeType === 1 ? node : null;
}

/** Choosing an option is no click to the controller; show it as one, on the menu. */
async function select(index, option) {
  const menu = element(index);
  if (menu) {
    menu.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    post({ kind: 'move', ...centre(menu) });
    await wait(0.3);
    post({ kind: 'press' });
    await wait(0.1);
  }
  return act('select', () => controller.selectOption(index, option));
}

/** A scroll shows as a swipe where it happens: over the list it moves, or mid-page. */
async function scroll(down, pages, pixels, index) {
  const target = index === undefined ? null : element(index);
  const where = target ? centre(target) : { x: 0.5, y: 0.5 };
  where.x = Math.min(0.9, Math.max(0.1, where.x));
  where.y = Math.min(0.8, Math.max(0.2, where.y));
  post({ kind: 'swipe', down, ...where });
  // The swipe draws for about this long; the page moves as it ends.
  await wait(0.35);
  return act('scroll', () => controller.scroll({ down, numPages: pages, pixels, index }));
}

globalThis.__dshBrowser = Object.freeze({
  read,
  click: (index) => act('click', () => controller.clickElement(index)),
  type: (index, text) => act('type', () => controller.inputText(index, text)),
  select,
  scroll,
  /** Whether this page has been read since it loaded: numbers mean nothing before that. */
  indexed: () => controller.selectorMap?.size > 0,
});
