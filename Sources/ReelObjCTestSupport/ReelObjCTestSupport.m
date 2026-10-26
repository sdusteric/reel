#import "ReelObjCTestSupport.h"

@implementation ReelThrowingAudioRenderer

- (void)setAudioOutputDeviceUniqueID:(NSString *)uid {
    @throw [NSException exceptionWithName:@"NSInvalidArgumentException"
                                   reason:@"device not ready"
                                 userInfo:nil];
}

@end
