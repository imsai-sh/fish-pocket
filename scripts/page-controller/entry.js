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

globalThis.__dshBrowser = Object.freeze({
  read,
  click: (index) => act('click', () => controller.clickElement(index)),
  type: (index, text) => act('type', () => controller.inputText(index, text)),
  select: (index, option) => act('select', () => controller.selectOption(index, option)),
  scroll: (down, pages, pixels, index) =>
    act('scroll', () => controller.scroll({ down, numPages: pages, pixels, index })),
  /** Whether this page has been read since it loaded: numbers mean nothing before that. */
  indexed: () => controller.selectorMap?.size > 0,
});
