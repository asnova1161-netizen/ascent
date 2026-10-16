#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface TSEventFetcher : NSObject

+ (NSInteger)receiveAXEventID:(NSInteger)eventId
           atGlobalCoordinate:(CGPoint)coordinate
               withTouchPhase:(UITouchPhase)phase
                     inWindow:(UIWindow *)window
                       onView:(UIView *)view;

@end
