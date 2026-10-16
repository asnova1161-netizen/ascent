#import <dlfcn.h>
#import <string.h>
#import <CoreFoundation/CoreFoundation.h>
#import "TSEventFetcher.h"
#import "UIEvent+Private.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication+Private.h"

@implementation TSEventFetcher

+ (NSInteger)receiveAXEventID:(NSInteger)eventId
           atGlobalCoordinate:(CGPoint)coordinate
               withTouchPhase:(UITouchPhase)phase
                     inWindow:(UIWindow *)window
                       onView:(UIView *)view {
    return 0;
}

@end
