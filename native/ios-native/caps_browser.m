// browser: read and drive the web page open in this conversation's browser.
//
// The browser is the one under Workbench → Browser, so whatever the agent does
// there the user can watch and take over. Pages are read with page-agent's page
// controller (app/DshIOS/Browser/PageController.js), which numbers the parts of a
// page that can be clicked or typed into; `click`, `type` and `select` take
// those numbers.
//
// No permission and no write policy: nothing here touches the user's data. The
// browser keeps its own cookies and storage, across launches, apart from
// Safari's and from the engine's web view: it is signed in to what someone
// signed in to in this browser, and to nothing else.
//
// An operation that shows something answers with the picture as base64 JPEG;
// the engine puts it in its attachment store, which is how an image reaches the
// model.
//
// This file is only a shim. The browser lives in Swift (DshBrowserBridge.h says
// why), and so do its operations, their arguments and the checks on them: a new
// one is written there alone.
#import "dsh_ios_native.h"
#import "DshBrowserBridge.h"

static NSString *const kNoProviderMessage =
    @"the app has not registered its browser, so nothing was opened";

static dispatch_queue_t provider_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.browser-provider", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static id<DshBrowserProviding> sProvider;

void DshBrowserSetProvider(id<DshBrowserProviding> provider) {
  dispatch_sync(provider_queue(), ^{ sProvider = provider; });
}

static id<DshBrowserProviding> current_provider(void) {
  __block id<DshBrowserProviding> provider;
  dispatch_sync(provider_queue(), ^{ provider = sProvider; });
  return provider;
}

NSDictionary<NSString *, id> *DshBrowserCatalog(void) {
  id<DshBrowserProviding> provider = current_provider();
  NSDictionary *catalog = provider == nil ? nil : [provider catalog];
  return [catalog isKindOfClass:NSDictionary.class] ? catalog : @{};
}

void dsh_native_browser(NSString *op, NSDictionary *args, DshNativeReply reply) {
  NSString *session = args[@"session"];
  if (![session isKindOfClass:NSString.class] || session.length == 0) {
    // The engine's own tool always sends it; only a direct caller can forget.
    reply(nil, @"browser needs 'session': which conversation's browser to use");
    return;
  }
  id<DshBrowserProviding> provider = current_provider();
  if (provider == nil) {
    reply(nil, kNoProviderMessage);
    return;
  }
  [provider performOperation:op
                   arguments:args
                  completion:^(NSDictionary<NSString *, id> *answer, NSString *error) {
    reply(error == nil ? (answer ?: @{}) : nil, error);
  }];
}
