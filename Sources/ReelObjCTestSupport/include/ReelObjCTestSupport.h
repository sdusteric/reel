#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test double: a renderer whose output device setter raises. Used only by tests; plays nothing.
@interface ReelThrowingAudioRenderer : AVSampleBufferAudioRenderer
@end

NS_ASSUME_NONNULL_END
