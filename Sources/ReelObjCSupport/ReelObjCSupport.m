#import "ReelObjCSupport.h"

NSErrorDomain const ReelObjCSupportErrorDomain = @"ReelObjCSupport";

@implementation ReelObjCSupport

+ (BOOL)setOutputDeviceOn:(AVSampleBufferAudioRenderer *)renderer
                      uid:(NSString *)uid
                    error:(NSError **)error {
    @try {
        renderer.audioOutputDeviceUniqueID = uid;
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *text = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"no reason"];
            *error = [NSError errorWithDomain:ReelObjCSupportErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: text}];
        }
        return NO;
    }
}

@end
