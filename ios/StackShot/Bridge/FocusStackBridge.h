#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C face of the embedded PetteriAimonen/focus-stack C++ core (MIT) + OpenCV.
/// Only compiled when ENGINE_EMBEDDED is defined — see scripts/fetch_engine.sh.
@interface FocusStackBridge : NSObject

/// Stacks the given image files (consecutive focus order, near→far) into one image.
/// Runs synchronously — call from a background queue. Returns nil and sets `error`
/// on failure. `progress` is called with values in 0…1.
///
/// `depthMapPath` is where the per-pixel source-frame depth map is written; pass a
/// unique path per call (e.g. including a UUID) so concurrent/overlapping runs never
/// read back another run's stale or in-progress depth file. The merged output is
/// written internally to `depthMapPath` with "_merged.png" appended, keeping it
/// unique too without a second parameter.
+ (nullable UIImage *)stackImagesAtPaths:(NSArray<NSString *> *)paths
                             depthMapPath:(NSString *)depthMapPath
                                 progress:(void (^_Nullable)(NSNumber *))progress
                                    error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
