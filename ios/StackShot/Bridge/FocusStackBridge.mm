#import "FocusStackBridge.h"

#if ENGINE_EMBEDDED

// Vendored by scripts/fetch_engine.sh into Vendor/focus-stack/src.
// NOTE: verify these header names against the vendored checkout — the focus-stack
// library's public entry point is the FocusStack class (focusstack.hh).
#import <opencv2/opencv.hpp>
#include "focusstack.hh"

@implementation FocusStackBridge

+ (nullable UIImage *)stackImagesAtPaths:(NSArray<NSString *> *)paths
                                progress:(void (^)(NSNumber *))progress
                                   error:(NSString **)error {
    @try {
        std::vector<std::string> inputs;
        inputs.reserve(paths.count);
        for (NSString *p in paths) {
            inputs.push_back(std::string(p.UTF8String));
        }

        NSString *outPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"stackshot_merged.png"];

        focusstack::FocusStack stack;
        stack.set_inputs(inputs);
        stack.set_output(std::string(outPath.UTF8String));
        // Per-pixel sharpest-source selection + depth map == Helicon Method-B analog.
        stack.set_depthmap(std::string([NSTemporaryDirectory()
            stringByAppendingPathComponent:@"stackshot_depth.png"].UTF8String));
        stack.set_align_flags(focusstack::FocusStack::ALIGN_DEFAULT);

        if (!stack.run()) {
            if (error) *error = @"focus-stack core returned failure";
            return nil;
        }
        if (progress) progress(@(1.0));

        UIImage *result = [UIImage imageWithContentsOfFile:outPath];
        if (!result && error) *error = @"could not load merged output";
        return result;
    } @catch (NSException *ex) {
        if (error) *error = ex.reason ?: @"unknown exception in stacking core";
        return nil;
    }
}

@end

#else

@implementation FocusStackBridge

+ (nullable UIImage *)stackImagesAtPaths:(NSArray<NSString *> *)paths
                                progress:(void (^)(NSNumber *))progress
                                   error:(NSString **)error {
    if (error) *error = @"Engine not embedded — build with ENGINE_EMBEDDED after running scripts/fetch_engine.sh";
    return nil;
}

@end

#endif
