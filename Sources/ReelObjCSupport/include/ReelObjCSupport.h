#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C exception guards for AVFoundation calls that can raise (Swift cannot catch NSException).
/// Nothing here starts audio.
@interface ReelObjCSupport : NSObject

/// Sets `audioOutputDeviceUniqueID`. Returns NO with an error (name and reason of the exception in
/// the description) when AVFoundation raises, for example while a Bluetooth device reconnects.
+ (BOOL)setOutputDeviceOn:(AVSampleBufferAudioRenderer *)renderer
                      uid:(nullable NSString *)uid
                    error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(setOutputDevice(on:uid:));

@end

extern NSErrorDomain const ReelObjCSupportErrorDomain;

NS_ASSUME_NONNULL_END
