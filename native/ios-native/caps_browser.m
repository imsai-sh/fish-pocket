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
// `screenshot` answers with the picture as base64 JPEG; the engine puts it in
// its attachment store, which is how an image reaches the model.
//
// This file is only a shim. The browser lives in Swift (DshBrowserBridge.h says
// why); what stays here is the argument checking and the sentences a caller can
// be refused with.
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

static BOOL has_string(NSDictionary *args, NSString *key) {
  return [args[key] isKindOfClass:NSString.class];
}

static BOOL has_index(NSDictionary *args) {
  id index = args[@"index"];
  // A JSON number that is a whole, non-negative value. 3.0 from a model counts.
  return [index isKindOfClass:NSNumber.class] && [index doubleValue] >= 0 &&
         [index doubleValue] == floor([index doubleValue]);
}

/// The argument this operation cannot do without, or nil when it has it.
static NSString *missing_argument(NSString *op, NSDictionary *args) {
  if ([op isEqualToString:@"open"] && !has_string(args, @"url")) {
    return @"open needs 'url'";
  }
  if (([op isEqualToString:@"click"] || [op isEqualToString:@"type"] ||
       [op isEqualToString:@"select"]) && !has_index(args)) {
    return [NSString stringWithFormat:
        @"%@ needs 'index': the number in brackets in front of an element in the last `read`", op];
  }
  if ([op isEqualToString:@"type"] && !has_string(args, @"text")) return @"type needs 'text'";
  if ([op isEqualToString:@"select"] && !has_string(args, @"option")) {
    return @"select needs 'option': the visible text of the option to choose";
  }
  if (args[@"desktop"] != nil) {
    // A JSON true or false; NSNumber also holds plain numbers, which are not a choice.
    if (!([args[@"desktop"] isKindOfClass:NSNumber.class] &&
          CFGetTypeID((__bridge CFTypeRef)args[@"desktop"]) == CFBooleanGetTypeID())) {
      return @"'desktop' must be true or false";
    }
    if (!([op isEqualToString:@"open"] || [op isEqualToString:@"reload"])) {
      return @"'desktop' goes with open or reload";
    }
  }
  if ([op isEqualToString:@"evaluate"] && !has_string(args, @"script")) {
    return @"evaluate needs 'script'";
  }
  if ([op isEqualToString:@"scroll"]) {
    id pages = args[@"pages"];
    if (pages != nil && !([pages isKindOfClass:NSNumber.class] && [pages doubleValue] > 0)) {
      return @"scroll's 'pages' must be a number above 0";
    }
    if (args[@"index"] != nil && !has_index(args)) return @"scroll's 'index' must be a whole number";
  }
  return nil;
}

void dsh_native_browser(NSString *op, NSDictionary *args, DshNativeReply reply) {
  NSString *session = args[@"session"];
  if (![session isKindOfClass:NSString.class] || session.length == 0) {
    // The engine's own tool always sends it; only a direct caller can forget.
    reply(nil, @"browser needs 'session': which conversation's browser to use");
    return;
  }
  NSString *missing = missing_argument(op, args);
  if (missing != nil) {
    reply(nil, missing);
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
