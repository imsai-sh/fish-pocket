// photos: read the photo library's metadata, export one picture to a file the
// engine can open, and organise the library — albums, favourites, hiding,
// saving a file into it and deleting from it.
//
// **What reading is for.** The chain this started with is library → file →
// `vision`: find the screenshot, export it, read the text out of it, and never
// leave the phone. So `list` returns no image data at all — a model asking what
// photos exist gets ids, sizes and dates, and pays for pixels only once it asks
// for one picture by id.
//
// **Writing goes through the same two gates as every other capability.** The
// system grant is read-write (iOS has no read-only level: add-only cannot even
// read back what it added), so turning photos on already covers writing. What
// sits between the agent and the user's library after that is the write policy
// the user sets per capability (§4.3): direct, confirm every time, or read-only.
// iOS adds its own sheet for deleting photos and albums and for hiding photos,
// every time, and nothing here can suppress it — so those skip the app's
// confirmation rather than asking twice, and only read-only still stops them
// before iOS is reached.
//
// **Limited access is an answer, not an error.** Since iOS 14 the user can share
// a handful of pictures instead of the library, and PhotoKit then answers every
// fetch from that handful without mentioning it. That silence is the one lie
// this file is in a position to tell — "you have 3 photos" when the truth is
// "you shared 3 photos" — so every reply carries `access`, and a limited one
// carries a sentence the agent can read out.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "DshNativeCapabilities.h"
#import "root.h"
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>

/// A library holds tens of thousands of pictures and a reply crosses into JS as
/// one JSON string. Same bound as `calendar`, for the same reason — and like
/// that one it is about the size of the reply, not about which pictures matter,
/// so `total` and `truncated` always say what was left out (§4.5).
static const NSUInteger kMaxAssets = 200;
static const NSUInteger kMaxAlbums = 200;

/// Where an exported copy lands, as an engine path. A dot directory because the
/// agent did not put it there and should not trip over it while working, and its
/// own subdirectory because anything else the native side has to hand the engine
/// as a file wants a neighbour rather than the home directory.
static NSString *const kExportDirectory = @"/home/dsh/.ios/photos";

static NSString *const kDeniedMessage =
    @"photo access is off for this app. The user can turn it on in Settings > Privacy & Security > "
     "Photos. iOS only asks once, so it cannot be requested again from here";

static NSString *const kNotEnabledMessage =
    @"the user has not switched photo access on for this app yet. Nothing was read. Tell them they "
     "can turn it on themselves under Device capabilities, which is in the app's sidebar — only "
     "they can grant it, and iOS asks once per app, so the app will not ask on its own.";

/// Said out loud on every limited reply. Without it each count in this file
/// reads as a fact about the user's photos when it is a fact about the few they
/// shared, and a model relaying "you only have 3 photos" would be repeating our
/// mistake to the one person who can tell it is wrong.
static NSString *const kLimitedNote =
    @"the user shared a selected set of photos rather than the whole library, so this describes "
     "that selection only: a count here counts shared photos, and a photo they did not share is "
     "not missing but invisible to this app. Say so rather than reporting it as their whole "
     "library. They can change the selection in Settings > Privacy & Security > Photos.";

/// PhotoKit's fetches are synchronous and go to the photo database, and an
/// export decodes and re-encodes a full-resolution image. Neither Node's thread
/// nor the main thread is a place to wait for that.
static dispatch_queue_t photos_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.photos",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

/// ISO 8601 with the device's own offset, so neither the model nor the user has
/// to guess a timezone. Not `eventkit_shared.h`'s `DshISO8601`: that header
/// imports EventKit, and a photo has no business dragging a calendar framework
/// in for a date format.
static NSString *iso8601(NSDate *date) {
  static NSISO8601DateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    formatter.timeZone = NSTimeZone.localTimeZone;
  });
  return date == nil ? @"" : [formatter stringFromDate:date];
}

#pragma mark - Authorisation

/// Check photo authorisation and run `next` with the outcome. Never prompts:
/// `requestAuthorizationForAccessLevel:` *is* the prompt, so calling it here
/// would let whichever plugin reads first decide when the user is asked, and the
/// user gets asked exactly once per install (§5.5).
///
/// `limited` rides along rather than being folded into `granted` because the two
/// answers need different sentences, and collapsing them is precisely how a
/// shared selection ends up presented as a library.
static void require_authorization(void (^next)(BOOL granted, BOOL limited, NSString *error)) {
  switch ([PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite]) {
    case PHAuthorizationStatusAuthorized:
      next(YES, NO, nil);
      return;
    case PHAuthorizationStatusLimited:
      next(YES, YES, nil);
      return;
    case PHAuthorizationStatusDenied:
    case PHAuthorizationStatusRestricted:
      next(NO, NO, kDeniedMessage);
      return;
    case PHAuthorizationStatusNotDetermined:
    default:
      next(NO, NO, kNotEnabledMessage);
      return;
  }
}

void DshPhotosGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
  if (status != PHAuthorizationStatusNotDetermined) {
    // Already answered. iOS will not ask again, so report the standing answer
    // instead of raising a dialog that will not appear.
    BOOL granted = status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited;
    done(granted, granted ? nil : kDeniedMessage);
    return;
  }
  // Read-write, not add-only: add-only cannot read, so a capability built on it
  // would be switched on and still answer nothing. Writes are then held by the
  // write policy, as the note at the top of this file says.
  //
  // Unlike CoreLocation, PhotoKit reports the user's choice through this
  // handler — including the picker behind "Select Photos…" — so the answer is
  // real by the time `done` runs. "Select Photos…" comes back granted, because
  // it is: a limited selection is access, and every call says which kind it is.
  dsh_native_on_main(^{
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                              handler:^(PHAuthorizationStatus chosen) {
      BOOL granted = chosen == PHAuthorizationStatusAuthorized || chosen == PHAuthorizationStatusLimited;
      done(granted, granted ? nil : kDeniedMessage);
    }];
  });
}

#pragma mark - Reading

/// One picture as metadata, and only metadata.
///
/// No pixels, no thumbnail and no GPS. A caller that wants the image asks for
/// that one picture by id and gets a file; a caller that wants to know where it
/// was taken is asking a different question than this one answers.
static NSDictionary *asset_json(PHAsset *asset) {
  return @{
    @"id": asset.localIdentifier ?: @"",
    @"created": iso8601(asset.creationDate),
    @"width": @(asset.pixelWidth),
    @"height": @(asset.pixelHeight),
    // The (BOOL) cast is load-bearing: a C comparison has type int, so without
    // it this boxes an int and the JSON a model reads carries 0/1 beside the
    // neighbouring true/false — the same trap as caps_calendar.m's `default`.
    @"isVideo": @((BOOL)(asset.mediaType == PHAssetMediaTypeVideo)),
    // Zero for a still, which is the truth rather than a missing field.
    @"duration": @(asset.duration),
    @"favorite": @(asset.isFavorite),
  };
}

static void list_assets(NSDictionary *args, DshNativeReply reply) {
  NSNumber *from = args[@"from"], *to = args[@"to"], *limit = args[@"limit"];
  if (from != nil && ![from isKindOfClass:NSNumber.class]) {
    reply(nil, @"'from' must be seconds since 1970");
    return;
  }
  if (to != nil && ![to isKindOfClass:NSNumber.class]) {
    reply(nil, @"'to' must be seconds since 1970");
    return;
  }
  if (from != nil && to != nil && to.doubleValue <= from.doubleValue) {
    reply(nil, @"'to' must be after 'from'");
    return;
  }
  NSUInteger wanted = kMaxAssets;
  if (limit != nil) {
    if (![limit isKindOfClass:NSNumber.class] || limit.integerValue < 1) {
      reply(nil, @"'limit' must be at least 1");
      return;
    }
    wanted = MIN((NSUInteger)limit.integerValue, kMaxAssets);
  }
  NSNumber *newestFirst = args[@"newestFirst"];
  NSString *album = args[@"album"];
  if (album != nil && (![album isKindOfClass:NSString.class] || album.length == 0)) {
    // An id, not a name: two albums can share a name, and picking one of them
    // would be us answering a question the caller has not decided yet (§4.5).
    reply(nil, @"'album' must be an album id, as `albums` returned it");
    return;
  }

  require_authorization(^(BOOL granted, BOOL limited, NSString *accessError) {
    if (!granted) {
      reply(nil, accessError);
      return;
    }
    dispatch_async(photos_queue(), ^{
      PHFetchOptions *options = [PHFetchOptions new];
      NSMutableArray<NSPredicate *> *terms = [NSMutableArray array];
      if (from != nil) {
        [terms addObject:[NSPredicate predicateWithFormat:@"creationDate >= %@",
                          [NSDate dateWithTimeIntervalSince1970:from.doubleValue]]];
      }
      if (to != nil) {
        [terms addObject:[NSPredicate predicateWithFormat:@"creationDate <= %@",
                          [NSDate dateWithTimeIntervalSince1970:to.doubleValue]]];
      }
      if (terms.count > 0) options.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:terms];
      // The default is no sort descriptor at all: the library's own order outside
      // an album, the album's own order inside one. That order is oldest first,
      // which surprises a caller asking about recent pictures — so `newestFirst`
      // exists, and it is the CALLER saying which end it wants, not this file
      // deciding which pictures are worth seeing first (§4.5).
      if ([newestFirst isKindOfClass:NSNumber.class] && newestFirst.boolValue) {
        options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
      }

      PHFetchResult<PHAsset *> *found = nil;
      // PhotoKit reports a fetch option it does not support by raising, not by
      // answering empty — a date range over a smart album is the known case. An
      // exception escaping here would take the whole app down on a call any
      // plugin can make, so it becomes a sentence the agent can read out, with
      // the framework's own reason forwarded rather than guessed at.
      @try {
        if (album != nil) {
          PHAssetCollection *collection =
            [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[album] options:nil].firstObject;
          if (collection == nil) {
            reply(nil, @"no album with that id; `albums` lists the ids this device has");
            return;
          }
          found = [PHAsset fetchAssetsInAssetCollection:collection options:options];
        } else {
          found = [PHAsset fetchAssetsWithOptions:options];
        }
      } @catch (NSException *exception) {
        reply(nil, [NSString stringWithFormat:
                    @"the photo library refused that query: %@. A date range over a smart album is "
                     "the usual cause, and the same request without 'from' and 'to' normally works.",
                    exception.reason ?: @"no reason given"]);
        return;
      }

      NSMutableArray *photos = [NSMutableArray arrayWithCapacity:MIN(found.count, wanted)];
      for (NSUInteger i = 0; i < found.count && photos.count < wanted; i++) {
        [photos addObject:asset_json([found objectAtIndex:i])];
      }
      NSMutableDictionary *result = [@{
        @"photos": photos,
        @"total": @(found.count),
        @"truncated": @((BOOL)(found.count > photos.count)),
        @"access": limited ? @"limited" : @"full",
        // A count and nothing else. The audit list is how the user sees what
        // touched their data; putting dates, places or titles in it would copy
        // their library into a second place to buy nothing.
        @"auditSummary": [NSString stringWithFormat:@"%lu", (unsigned long)found.count],
      } mutableCopy];
      if (limited) result[@"note"] = kLimitedNote;
      reply(result, nil);
    });
  });
}

static NSDictionary *album_json(PHAssetCollection *collection, NSString *kind) {
  // The real count rather than `estimatedAssetCount`, which is NSNotFound for
  // most smart albums — and a count the caller has to treat as maybe-unknown is
  // worse than one database query. A PHFetchResult counts without loading.
  NSUInteger count = [PHAsset fetchAssetsInAssetCollection:collection options:nil].count;
  return @{
    @"id": collection.localIdentifier ?: @"",
    @"title": collection.localizedTitle ?: @"",
    @"count": @(count),
    @"kind": kind,
  };
}

static void list_albums(DshNativeReply reply) {
  require_authorization(^(BOOL granted, BOOL limited, NSString *accessError) {
    if (!granted) {
      reply(nil, accessError);
      return;
    }
    dispatch_async(photos_queue(), ^{
      // Smart albums come along because "my screenshots" and "my favourites" are
      // ordinary requests and Screenshots and Favorites are smart albums. Empty
      // ones are listed too: the Photos app hides them, but hiding is us
      // deciding what is worth seeing, and "Screenshots · 0" is an answer.
      const PHAssetCollectionType types[] = {PHAssetCollectionTypeAlbum, PHAssetCollectionTypeSmartAlbum};
      NSArray<NSString *> *kinds = @[@"album", @"smartAlbum"];

      NSMutableArray *albums = [NSMutableArray array];
      NSUInteger total = 0;
      for (size_t i = 0; i < sizeof types / sizeof *types; i++) {
        PHFetchResult<PHAssetCollection *> *found =
          [PHAssetCollection fetchAssetCollectionsWithType:types[i]
                                                  subtype:PHAssetCollectionSubtypeAny
                                                  options:nil];
        total += found.count;
        for (NSUInteger j = 0; j < found.count && albums.count < kMaxAlbums; j++) {
          [albums addObject:album_json([found objectAtIndex:j], kinds[i])];
        }
      }

      NSMutableDictionary *result = [@{
        @"albums": albums,
        @"total": @(total),
        @"truncated": @((BOOL)(total > albums.count)),
        @"access": limited ? @"limited" : @"full",
        @"auditSummary": [NSString stringWithFormat:@"%lu", (unsigned long)total],
      } mutableCopy];
      // Worth saying twice: under a limited selection PhotoKit reports albums
      // that hold only the shared pictures, so a count of 2 beside the title of
      // an album the user knows holds 400 is not a bug.
      if (limited) result[@"note"] = kLimitedNote;
      reply(result, nil);
    });
  });
}

#pragma mark - Exporting

/// A file name from the picture's own id, so exporting the same one twice lands
/// on the same file instead of filling the directory with copies. The id holds
/// slashes (`UUID/L0/001`) that would otherwise read as directories, and the
/// long edge goes in the name so the same picture asked for at two sizes does
/// not quietly overwrite itself.
static NSString *export_name(NSString *localIdentifier, NSUInteger longEdge) {
  NSCharacterSet *unsafe = [[NSCharacterSet characterSetWithCharactersInString:
    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet];
  NSString *stem = [[localIdentifier componentsSeparatedByCharactersInSet:unsafe]
                    componentsJoinedByString:@"_"];
  return [NSString stringWithFormat:@"%@-%lu.jpg",
          stem.length > 0 ? stem : @"photo", (unsigned long)longEdge];
}

/// The real directory an export writes into, created if missing.
///
/// Derived from the engine path rather than from the app container, because the
/// two are not interchangeable: the file has to be written through the real one,
/// while the caller can only use the engine one — `vision` and `fs` resolve what
/// they are handed through the same view, so a real path given back comes out as
/// "not a path this app can reach".
static BOOL prepare_export_directory(NSString **realDirectory, NSString **error) {
  char real[4096];
  if (dsh_root_real(kExportDirectory.fileSystemRepresentation, real, sizeof real) != 0) {
    *error = @"the engine's workspace is not available, so there is nowhere to put the file";
    return NO;
  }
  NSError *createError = nil;
  if (![NSFileManager.defaultManager createDirectoryAtPath:@(real)
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&createError]) {
    *error = createError.localizedDescription ?: @"the export directory could not be created";
    return NO;
  }
  *realDirectory = @(real);
  return YES;
}

/// The engine path for a file just written — checked, not assumed.
///
/// It is translated back through the engine's own view and then forward again,
/// and only a round trip that lands on the same file is handed to the caller.
/// Appending onto `kExportDirectory` by string would look identical today and
/// break silently the day the view changes shape, and the way it would break is
/// the caller being handed a path `vision` refuses.
static NSString *engine_path(NSString *realFile) {
  char virtual[4096], back[4096];
  const char *real = realFile.fileSystemRepresentation;
  if (dsh_root_virtual(real, virtual, sizeof virtual) != 0) return nil;
  if (dsh_root_real(virtual, back, sizeof back) != 0) return nil;
  if (strcmp(back, real) != 0) return nil;
  return @(virtual);
}

/// Decode `data` oriented, scaled so its longest edge is at most `longEdge`, and
/// write it to `realFile` as JPEG.
///
/// Always re-encoded and always oriented, because this file exists to be opened
/// by something else: `vision` builds its request from a CGImage, and a CGImage
/// carries no EXIF orientation, so a sideways original becomes a sideways page
/// and the text on it goes unread. Choosing an export's output format is picking
/// a parameter Apple makes us pick, not picking an answer on the caller's behalf
/// — and the reply states the dimensions and the format, so nothing has to be
/// inferred from the file.
static BOOL write_jpeg(NSData *data, NSUInteger longEdge, NSString *realFile,
                       NSUInteger *width, NSUInteger *height, NSString **error) {
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (source == NULL) {
    *error = @"that photo could not be decoded on this device";
    return NO;
  }
  NSDictionary *options = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize: @(longEdge),
    (id)kCGImageSourceShouldCacheImmediately: @YES,
  };
  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
  CFRelease(source);
  if (image == NULL) {
    *error = @"that photo could not be decoded on this device";
    return NO;
  }
  *width = CGImageGetWidth(image);
  *height = CGImageGetHeight(image);

  // "public.jpeg" written out rather than imported: the constant for it lives in
  // UniformTypeIdentifiers, and one string does not justify another framework.
  CGImageDestinationRef destination =
    CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:realFile],
                                    (__bridge CFStringRef)@"public.jpeg", 1, NULL);
  if (destination == NULL) {
    CGImageRelease(image);
    *error = @"the exported file could not be created";
    return NO;
  }
  CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{
    (id)kCGImageDestinationLossyCompressionQuality: @0.9,
  });
  BOOL ok = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(image);
  if (!ok) *error = @"the exported file could not be written";
  return ok;
}

static void export_asset(NSDictionary *args, DshNativeReply reply) {
  NSString *identifier = args[@"id"];
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    reply(nil, @"export needs the photo's 'id', as `list` returned it");
    return;
  }
  NSNumber *maxPixels = args[@"maxPixels"];
  if (maxPixels != nil && (![maxPixels isKindOfClass:NSNumber.class] || maxPixels.integerValue < 1)) {
    reply(nil, @"'maxPixels' must be at least 1; it caps the longest edge in pixels");
    return;
  }

  require_authorization(^(BOOL granted, BOOL limited, NSString *accessError) {
    if (!granted) {
      reply(nil, accessError);
      return;
    }
    dispatch_async(photos_queue(), ^{
      PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
      if (asset == nil) {
        // Two different facts, said differently: a stale id, or an id for a
        // picture that exists and is simply outside what the user shared.
        reply(nil, limited
              ? @"no photo with that id among the ones the user shared. Under a limited selection "
                 "only those are visible to this app, so an id from anywhere else will not resolve. "
                 "They can change the selection in Settings > Privacy & Security > Photos."
              : @"no photo with that id; it may have been deleted or the id may be stale");
        return;
      }
      if (asset.mediaType != PHAssetMediaTypeImage) {
        // Not a judgement about the asset, a statement about this operation:
        // what it produces is a still image file. `list` flags videos already.
        reply(nil, @"that asset is not a still image, and this exports still images only "
                    "(`list` marks videos with isVideo)");
        return;
      }

      NSString *realDirectory = nil, *prepareError = nil;
      if (!prepare_export_directory(&realDirectory, &prepareError)) {
        reply(nil, prepareError);
        return;
      }

      // Absent `maxPixels`, the picture's own long edge — ImageIO does not
      // upscale, so this exports at full resolution without a special case.
      NSUInteger longEdge = MAX((NSUInteger)1, MAX(asset.pixelWidth, asset.pixelHeight));
      if (maxPixels != nil) longEdge = MIN(longEdge, (NSUInteger)maxPixels.integerValue);

      PHImageRequestOptions *options = [PHImageRequestOptions new];
      options.version = PHImageRequestOptionsVersionCurrent;
      options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
      // Without this a picture iCloud has offloaded is simply unavailable, which
      // reads exactly like a photo that is not there. It is the user's own
      // library over their own account, and what comes down stays on the phone.
      options.networkAccessAllowed = YES;

      __block BOOL settled = NO;
      [PHImageManager.defaultManager requestImageDataAndOrientationForAsset:asset options:options
        resultHandler:^(NSData *data, NSString *dataUTI,
                        CGImagePropertyOrientation orientation, NSDictionary *info) {
        // Neither is wanted: the output format is settled (JPEG), and ImageIO
        // reads the orientation out of the data itself and applies it.
        (void)dataUTI;
        (void)orientation;
        // High-quality delivery answers once, but the handler is documented as
        // allowed to run again, and a reply must not.
        if (settled) return;
        settled = YES;

        if (data == nil) {
          NSError *failure = info[PHImageErrorKey];
          reply(nil, failure.localizedDescription
                     ?: @"that photo's data could not be read from the library");
          return;
        }
        NSString *realFile =
          [realDirectory stringByAppendingPathComponent:export_name(asset.localIdentifier, longEdge)];
        NSUInteger width = 0, height = 0;
        NSString *writeError = nil;
        if (!write_jpeg(data, longEdge, realFile, &width, &height, &writeError)) {
          reply(nil, writeError);
          return;
        }
        NSString *path = engine_path(realFile);
        if (path == nil) {
          reply(nil, @"the exported file did not land at a path the engine can open, so nothing "
                      "was handed back");
          return;
        }

        NSMutableDictionary *result = [@{
          @"path": path,
          @"id": asset.localIdentifier ?: @"",
          @"width": @(width),
          @"height": @(height),
          @"bytes": @([NSFileManager.defaultManager attributesOfItemAtPath:realFile error:NULL].fileSize),
          @"format": @"jpeg",
          @"access": limited ? @"limited" : @"full",
          // One picture. Which picture is deliberately absent: the audit list is
          // the user's view of what reached their data, not a second copy of it.
          @"auditSummary": @"1",
        } mutableCopy];
        if (limited) result[@"note"] = kLimitedNote;
        reply(result, nil);
      }];
    });
  });
}

#pragma mark - Writing

/// Photos one write may touch: the same bound as one `list` page, so "everything
/// that list just returned" always fits in one call.
static const NSUInteger kMaxChanged = kMaxAssets;

/// How many dates a confirmation names before it says how many more there are.
static const NSUInteger kSummaryDates = 5;

/// Formats PhotoKit can turn into an asset from a file. Chosen by extension
/// because that is what decides how the agent made the file; anything else is
/// refused with the list rather than handed to PhotoKit to fail obscurely.
static NSSet<NSString *> *image_extensions(void) {
  return [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"tif", @"tiff",
                               @"webp", @"bmp", @"dng"]];
}
static NSSet<NSString *> *video_extensions(void) {
  return [NSSet setWithArray:@[@"mov", @"mp4", @"m4v"]];
}

/// Ask before a write, the way the user has set it. `systemAsks` is for the
/// operations iOS confirms on its own (deleting photos or an album, hiding):
/// under `Confirm` they go straight to iOS's sheet instead of stacking ours on
/// top of it, and under read-only they are refused here like any other write.
static void gate(NSString *op, NSString *summary, BOOL destructive, BOOL systemAsks,
                 void (^next)(BOOL ok, NSString *refusal)) {
  if (systemAsks && DshNativeWritePolicyFor(@"photos") != DshWritePolicyBlocked) {
    next(YES, nil);
    return;
  }
  DshNativeConfirmWrite(@"photos", op, summary, destructive, next);
}

/// Run one change block and reply on the photos queue. A user who taps
/// "Don't Allow" on iOS's own sheet is an answer, not a failure: it comes back
/// as `cancelled`, without an audit summary, so nothing is recorded as done.
static void perform(void (^changes)(void), NSDictionary *(^done)(void), DshNativeReply reply) {
  [PHPhotoLibrary.sharedPhotoLibrary performChanges:changes completionHandler:^(BOOL success, NSError *error) {
    dispatch_async(photos_queue(), ^{
      if (success) {
        reply(done(), nil);
        return;
      }
      if ([error.domain isEqualToString:PHPhotosErrorDomain] && error.code == PHPhotosErrorUserCancelled) {
        reply(@{@"action": DshNativeActionCancelled}, nil);
        return;
      }
      reply(nil, error.localizedDescription ?: @"the photo library did not accept that change");
    });
  }];
}

/// The `ids` argument, checked: a non-empty list of strings, at most one page.
static NSArray<NSString *> *ids_arg(NSDictionary *args, NSString *op, NSString **error) {
  NSArray *ids = args[@"ids"];
  if (![ids isKindOfClass:NSArray.class] || ids.count == 0) {
    *error = [NSString stringWithFormat:@"%@ needs 'ids', a list of photo ids as `list` returned them", op];
    return nil;
  }
  if (ids.count > kMaxChanged) {
    *error = [NSString stringWithFormat:@"at most %lu photos per call; split the list",
              (unsigned long)kMaxChanged];
    return nil;
  }
  for (id one in ids) {
    if (![one isKindOfClass:NSString.class] || [one length] == 0) {
      *error = @"every entry in 'ids' must be a photo id string";
      return nil;
    }
  }
  return [[NSOrderedSet orderedSetWithArray:ids] array];
}

/// Every id resolved, or none acted on. Changing the photos that happened to
/// resolve and staying quiet about the rest would leave the user's library half
/// organised with nothing saying which half.
static NSArray<PHAsset *> *fetch_assets(NSArray<NSString *> *ids, BOOL limited, NSString **error) {
  PHFetchResult<PHAsset *> *found = [PHAsset fetchAssetsWithLocalIdentifiers:ids options:nil];
  NSMutableArray<PHAsset *> *assets = [NSMutableArray arrayWithCapacity:found.count];
  NSMutableSet<NSString *> *missing = [NSMutableSet setWithArray:ids];
  for (NSUInteger i = 0; i < found.count; i++) {
    PHAsset *asset = [found objectAtIndex:i];
    [assets addObject:asset];
    [missing removeObject:asset.localIdentifier];
  }
  if (missing.count > 0) {
    *error = [NSString stringWithFormat:
              @"%lu of these ids did not resolve, so nothing was changed: %@. %@",
              (unsigned long)missing.count, [missing.allObjects componentsJoinedByString:@", "],
              limited ? @"Under a limited selection only the photos the user shared are visible to this app."
                      : @"They may have been deleted, or the ids may be stale; `list` again."];
    return nil;
  }
  return assets;
}

/// A user album that can take this edit. Smart albums (Screenshots, Favorites…)
/// are iOS's own and cannot be edited; favouriting is how a photo gets into
/// Favorites, and the error says so rather than leaving the agent to guess.
static PHAssetCollection *fetch_album(NSDictionary *args, PHCollectionEditOperation operation, NSString **error) {
  NSString *identifier = args[@"album"];
  if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
    *error = @"this needs 'album', an album id as `albums` returned it";
    return nil;
  }
  PHAssetCollection *album =
    [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
  if (album == nil) {
    *error = @"no album with that id; `albums` lists the ids this device has";
    return nil;
  }
  if (![album canPerformEditOperation:operation]) {
    *error = album.assetCollectionType == PHAssetCollectionTypeSmartAlbum
      ? @"that is a smart album, which iOS maintains itself and does not let apps edit. To put a photo "
         "in Favorites use `favorite`; to hide one use `hide`."
      : @"iOS does not allow that change to this album (it may be shared or synced from elsewhere)";
    return nil;
  }
  return album;
}

/// What the confirmation shows for a set of photos: their dates, the first few
/// and then how many more. Language-free on purpose — the sheet's title is the
/// app's and is translated; this part is shown as is.
static NSString *assets_summary(NSArray<PHAsset *> *assets) {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (PHAsset *asset in assets) {
    if (lines.count == kSummaryDates) break;
    NSString *date = [iso8601(asset.creationDate) stringByReplacingOccurrencesOfString:@"T" withString:@" "];
    if (date.length >= 16) date = [date substringToIndex:16];
    [lines addObject:[NSString stringWithFormat:@"%@%@", asset.mediaType == PHAssetMediaTypeVideo ? @"▶ " : @"",
                      date.length > 0 ? date : @"—"]];
  }
  if (assets.count > kSummaryDates) {
    [lines addObject:[NSString stringWithFormat:@"… +%lu", (unsigned long)(assets.count - kSummaryDates)]];
  }
  return [lines componentsJoinedByString:@"\n"];
}

/// For the audit list a count is enough, plus the album when there is one — the
/// same restraint as the reads: the list says what reached the library, it is
/// not a second copy of it.
static NSString *count_summary(NSUInteger count, PHAssetCollection *album) {
  return album == nil ? [NSString stringWithFormat:@"%lu", (unsigned long)count]
                      : [NSString stringWithFormat:@"%lu → %@", (unsigned long)count, album.localizedTitle ?: @""];
}

/// Shared shape of every write: check access, then do the rest on the photos queue.
static void with_access(DshNativeReply reply, void (^body)(BOOL limited)) {
  require_authorization(^(BOOL granted, BOOL limited, NSString *accessError) {
    if (!granted) {
      reply(nil, accessError);
      return;
    }
    dispatch_async(photos_queue(), ^{ body(limited); });
  });
}

static void save_file(NSDictionary *args, DshNativeReply reply) {
  NSString *path = args[@"path"];
  if (![path isKindOfClass:NSString.class] || path.length == 0) {
    reply(nil, @"save needs 'path', an image or video file in the workspace");
    return;
  }
  NSString *extension = path.pathExtension.lowercaseString;
  BOOL video = [video_extensions() containsObject:extension];
  if (!video && ![image_extensions() containsObject:extension]) {
    reply(nil, [NSString stringWithFormat:@"'%@' is not a format the photo library takes. Images: %@. Videos: %@",
                path.lastPathComponent,
                [[image_extensions().allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "],
                [[video_extensions().allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]);
    return;
  }
  // The engine's own view of the filesystem, the same one `vision` reads
  // through — so this reaches no file the agent could not already open.
  char real[4096];
  if (dsh_root_real(path.fileSystemRepresentation, real, sizeof(real)) != 0) {
    reply(nil, [NSString stringWithFormat:@"'%@' is not a path this app can reach", path]);
    return;
  }
  NSURL *url = [NSURL fileURLWithPath:@(real)];
  BOOL directory = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory] || directory) {
    reply(nil, [NSString stringWithFormat:@"there is no file at '%@'", path]);
    return;
  }

  with_access(reply, ^(BOOL limited) {
    (void)limited;
    PHAssetCollection *album = nil;
    if (args[@"album"] != nil) {
      NSString *albumError = nil;
      album = fetch_album(args, PHCollectionEditOperationAddContent, &albumError);
      if (album == nil) { reply(nil, albumError); return; }
    }
    NSString *summary = album == nil ? path.lastPathComponent
      : [NSString stringWithFormat:@"%@\n→ %@", path.lastPathComponent, album.localizedTitle ?: @""];
    gate(@"save", summary, NO, NO, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      __block NSString *created = nil;
      perform(^{
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        [request addResourceWithType:video ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto
                             fileURL:url options:nil];
        PHObjectPlaceholder *placeholder = request.placeholderForCreatedAsset;
        created = placeholder.localIdentifier;
        if (album != nil) {
          [[PHAssetCollectionChangeRequest changeRequestForAssetCollection:album] addAssets:@[placeholder]];
        }
      }, ^NSDictionary *{
        return @{@"action": DshNativeActionSaved, @"id": created ?: @"", @"isVideo": @(video),
                 @"auditSummary": summary};
      }, reply);
    });
  });
}

static void delete_assets(NSDictionary *args, DshNativeReply reply) {
  NSString *argError = nil;
  NSArray<NSString *> *ids = ids_arg(args, @"delete", &argError);
  if (ids == nil) { reply(nil, argError); return; }
  with_access(reply, ^(BOOL limited) {
    NSString *fetchError = nil;
    NSArray<PHAsset *> *assets = fetch_assets(ids, limited, &fetchError);
    if (assets == nil) { reply(nil, fetchError); return; }
    gate(@"delete", assets_summary(assets), YES, YES, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      perform(^{
        [PHAssetChangeRequest deleteAssets:assets];
      }, ^NSDictionary *{
        // "Recently Deleted" keeps them for 30 days; the reply says so because the
        // user's next question is often "can I get it back".
        return @{@"action": DshNativeActionDeleted, @"count": @(assets.count), @"recoverable": @YES,
                 @"auditSummary": count_summary(assets.count, nil)};
      }, reply);
    });
  });
}

/// `favorite` and `hide`: one flag, set to `value` (true when absent) on every
/// photo listed. The confirmation is asked under the direction's own name, so
/// "unfavourite these?" is not shown as "favourite these?".
///
/// Hiding goes one way only. Since iOS 16 a hidden photo is invisible to every
/// app but Photos — no fetch returns it and the Hidden album counts 0 (checked
/// on iOS 27) — so there is no id to unhide by, and the refusal says where the
/// user can do it instead of pretending to try.
static void set_flag(NSString *op, NSDictionary *args, DshNativeReply reply) {
  BOOL favorite = [op isEqualToString:@"favorite"];
  NSNumber *value = args[@"value"];
  if (value != nil && ![value isKindOfClass:NSNumber.class]) {
    reply(nil, @"'value' must be true or false");
    return;
  }
  BOOL on = value == nil ? YES : value.boolValue;
  if (!favorite && !on) {
    reply(nil, @"iOS does not let apps see hidden photos, so they cannot be unhidden from here. The "
                "user can unhide them in the Photos app, under Hidden.");
    return;
  }
  NSString *argError = nil;
  NSArray<NSString *> *ids = ids_arg(args, op, &argError);
  if (ids == nil) { reply(nil, argError); return; }
  with_access(reply, ^(BOOL limited) {
    NSString *fetchError = nil;
    NSArray<PHAsset *> *assets = fetch_assets(ids, limited, &fetchError);
    if (assets == nil) { reply(nil, fetchError); return; }
    NSString *asked = favorite ? (on ? @"favorite" : @"unfavorite") : @"hide";
    // iOS raises its own sheet before hiding a photo, not before favouriting.
    gate(asked, assets_summary(assets), NO, !favorite, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      perform(^{
        for (PHAsset *asset in assets) {
          PHAssetChangeRequest *change = [PHAssetChangeRequest changeRequestForAsset:asset];
          if (favorite) change.favorite = on; else change.hidden = on;
        }
      }, ^NSDictionary *{
        return @{@"action": DshNativeActionSaved, @"count": @(assets.count), @"value": @(on),
                 @"auditSummary": [NSString stringWithFormat:@"%@ %@", asked, count_summary(assets.count, nil)]};
      }, reply);
    });
  });
}

/// `addToAlbum` and `removeFromAlbum`. Removing takes a photo out of one album;
/// the photo itself stays in the library, which the reply says.
static void change_membership(NSString *op, NSDictionary *args, DshNativeReply reply) {
  BOOL adding = [op isEqualToString:@"addToAlbum"];
  NSString *argError = nil;
  NSArray<NSString *> *ids = ids_arg(args, op, &argError);
  if (ids == nil) { reply(nil, argError); return; }
  with_access(reply, ^(BOOL limited) {
    NSString *albumError = nil;
    PHAssetCollection *album = fetch_album(args, adding ? PHCollectionEditOperationAddContent
                                                        : PHCollectionEditOperationRemoveContent, &albumError);
    if (album == nil) { reply(nil, albumError); return; }
    NSString *fetchError = nil;
    NSArray<PHAsset *> *assets = fetch_assets(ids, limited, &fetchError);
    if (assets == nil) { reply(nil, fetchError); return; }
    NSString *summary = [NSString stringWithFormat:@"%@\n%@ %@", assets_summary(assets),
                         adding ? @"→" : @"←", album.localizedTitle ?: @""];
    gate(op, summary, NO, NO, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      perform(^{
        PHAssetCollectionChangeRequest *change = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
        if (adding) [change addAssets:assets]; else [change removeAssets:assets];
      }, ^NSDictionary *{
        return @{@"action": DshNativeActionSaved, @"count": @(assets.count), @"album": album.localIdentifier ?: @"",
                 @"auditSummary": count_summary(assets.count, album)};
      }, reply);
    });
  });
}

static NSString *title_arg(NSDictionary *args, NSString **error) {
  NSString *title = [args[@"title"] isKindOfClass:NSString.class]
    ? [args[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
  if (title.length == 0) *error = @"this needs a non-empty 'title' for the album";
  return title.length == 0 ? nil : title;
}

static void create_album(NSDictionary *args, DshNativeReply reply) {
  NSString *argError = nil;
  NSString *title = title_arg(args, &argError);
  if (title == nil) { reply(nil, argError); return; }
  with_access(reply, ^(BOOL limited) {
    (void)limited;
    gate(@"createAlbum", title, NO, NO, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      __block NSString *created = nil;
      perform(^{
        created = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:title]
                    .placeholderForCreatedAssetCollection.localIdentifier;
      }, ^NSDictionary *{
        return @{@"action": DshNativeActionSaved, @"id": created ?: @"", @"title": title, @"auditSummary": title};
      }, reply);
    });
  });
}

static void rename_album(NSDictionary *args, DshNativeReply reply) {
  NSString *argError = nil;
  NSString *title = title_arg(args, &argError);
  if (title == nil) { reply(nil, argError); return; }
  with_access(reply, ^(BOOL limited) {
    (void)limited;
    NSString *albumError = nil;
    PHAssetCollection *album = fetch_album(args, PHCollectionEditOperationRename, &albumError);
    if (album == nil) { reply(nil, albumError); return; }
    NSString *summary = [NSString stringWithFormat:@"%@\n→\n%@", album.localizedTitle ?: @"", title];
    gate(@"renameAlbum", summary, NO, NO, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      perform(^{
        [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album].title = title;
      }, ^NSDictionary *{
        return @{@"action": DshNativeActionSaved, @"id": album.localIdentifier ?: @"", @"title": title,
                 @"auditSummary": summary};
      }, reply);
    });
  });
}

/// Deletes the album, not the photos in it — they stay in the library.
static void delete_album(NSDictionary *args, DshNativeReply reply) {
  with_access(reply, ^(BOOL limited) {
    (void)limited;
    NSString *albumError = nil;
    PHAssetCollection *album = fetch_album(args, PHCollectionEditOperationDelete, &albumError);
    if (album == nil) { reply(nil, albumError); return; }
    NSString *title = album.localizedTitle ?: @"";
    gate(@"deleteAlbum", title, YES, YES, ^(BOOL ok, NSString *refusal) {
      if (refusal != nil) { reply(nil, refusal); return; }
      if (!ok) { reply(@{@"action": DshNativeActionCancelled}, nil); return; }
      perform(^{
        [PHAssetCollectionChangeRequest deleteAssetCollections:@[album]];
      }, ^NSDictionary *{
        return @{@"action": DshNativeActionDeleted, @"title": title, @"auditSummary": title};
      }, reply);
    });
  });
}

void dsh_native_photos(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"list"]) { list_assets(args, reply); return; }
  if ([op isEqualToString:@"albums"]) { list_albums(reply); return; }
  if ([op isEqualToString:@"export"]) { export_asset(args, reply); return; }
  if ([op isEqualToString:@"save"]) { save_file(args, reply); return; }
  if ([op isEqualToString:@"delete"]) { delete_assets(args, reply); return; }
  if ([op isEqualToString:@"favorite"] || [op isEqualToString:@"hide"]) { set_flag(op, args, reply); return; }
  if ([op isEqualToString:@"addToAlbum"] || [op isEqualToString:@"removeFromAlbum"]) {
    change_membership(op, args, reply);
    return;
  }
  if ([op isEqualToString:@"createAlbum"]) { create_album(args, reply); return; }
  if ([op isEqualToString:@"renameAlbum"]) { rename_album(args, reply); return; }
  if ([op isEqualToString:@"deleteAlbum"]) { delete_album(args, reply); return; }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"photos has no operation '%@'", op]);
}
