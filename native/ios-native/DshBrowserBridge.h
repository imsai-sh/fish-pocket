// How the browser capability reaches the session's browser, which lives in Swift.
//
// The browser is the workbench's: one WKWebView per conversation, owned by the
// app's SwiftUI side, the same page the user sees under Workbench → Browser.
// Nothing about it is reachable from Objective-C without dragging SwiftUI's
// observation model in, so — like AlarmKit and WeatherKit — the work happens in
// Swift and this file is the seam. caps_browser.m keeps what belongs on this
// side: the operation list, argument checking, and every sentence a caller can
// be refused with.
#ifndef DSH_BROWSER_BRIDGE_H
#define DSH_BROWSER_BRIDGE_H

#import <Foundation/Foundation.h>
#import "dsh_ios_native.h"

NS_ASSUME_NONNULL_BEGIN

/// What the app implements so the browser capability has something to drive.
///
/// **A provider decides nothing.** Arguments arrive already checked: `session`
/// is a non-empty string, `index` a non-negative integer, `url`, `text`,
/// `option` and `script` strings where the operation needs them. It performs
/// the operation on that session's browser and answers with plain dictionaries.
///
/// The completion is called exactly once, on any thread, with exactly one of
/// its two arguments non-nil. It must be called even when the page never
/// answers: every wait inside a provider has a deadline.
@protocol DshBrowserProviding <NSObject>

- (void)performOperation:(NSString *)op
               arguments:(NSDictionary<NSString *, id> *)args
              completion:(void (^)(NSDictionary<NSString *, id> *_Nullable answer,
                                   NSString *_Nullable error))done;

@end

/// Registered once by the app at launch, next to the weather provider.
void DshBrowserSetProvider(id<DshBrowserProviding> _Nullable provider);

void dsh_native_browser(NSString *op, NSDictionary *args, DshNativeReply reply);

NS_ASSUME_NONNULL_END

#endif
