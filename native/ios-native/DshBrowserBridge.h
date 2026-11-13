// How the browser capability reaches the session's browser, which lives in Swift.
//
// The browser is the workbench's: one WKWebView per conversation, owned by the
// app's SwiftUI side, the same page the user sees under Workbench → Browser.
// Nothing about it is reachable from Objective-C without dragging SwiftUI's
// observation model in, so — like AlarmKit and WeatherKit — the work happens in
// Swift and this file is the seam.
//
// Unlike the other capabilities, the browser's operations are listed by the app
// (`catalog`), not by the dispatcher's table: the operations, their arguments and
// the sentences the model reads about them all live in Swift, so a new browser
// ability is written in one place. The dispatcher still refuses any operation the
// catalog does not name, and the engine builds its tool from the same catalog.
#ifndef DSH_BROWSER_BRIDGE_H
#define DSH_BROWSER_BRIDGE_H

#import <Foundation/Foundation.h>
#import "dsh_ios_native.h"

NS_ASSUME_NONNULL_BEGIN

/// What the app implements so the browser capability has something to drive.
///
/// Arguments arrive with `session` checked (a non-empty string) and the
/// operation checked against the catalog; the provider checks the rest itself,
/// against the same catalog, and answers with plain dictionaries.
///
/// The completion is called exactly once, on any thread, with exactly one of
/// its two arguments non-nil. It must be called even when the page never
/// answers: every wait inside a provider has a deadline.
@protocol DshBrowserProviding <NSObject>

/// What the browser can do: `{description, actions: [{name, does, takes, needs,
/// image}], params: [{name, schema}]}`. Plain JSON values, the same every time,
/// safe to read from any thread: the engine reads it once, on its own thread,
/// to build its tool.
- (NSDictionary<NSString *, id> *)catalog;

- (void)performOperation:(NSString *)op
               arguments:(NSDictionary<NSString *, id> *)args
              completion:(void (^)(NSDictionary<NSString *, id> *_Nullable answer,
                                   NSString *_Nullable error))done;

@end

/// Registered once by the app at launch, next to the weather provider.
void DshBrowserSetProvider(id<DshBrowserProviding> _Nullable provider);

/// The registered provider's catalog, or an empty one when there is none yet.
NSDictionary<NSString *, id> *DshBrowserCatalog(void);

void dsh_native_browser(NSString *op, NSDictionary *args, DshNativeReply reply);

NS_ASSUME_NONNULL_END

#endif
