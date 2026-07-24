#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C face of the embedded PetteriAimonen/focus-stack C++ core (MIT) + OpenCV.
/// Only compiled when ENGINE_EMBEDDED is defined — see scripts/fetch_engine.sh.
@interface FocusStackBridge : NSObject

/// Stacks the given image files (consecutive focus order, near→far) into one image.
/// Runs synchronously — call from a background queue. Returns nil and sets `error`
/// on failure. `progress` is called with values in 0…1.
+ (nullable UIImage *)stackImagesAtPaths:(NSArray<NSString *> *)paths
                                progress:(void (^_Nullable)(NSNumber *))progress
                                   error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
