#import <UIKit/UIKit.h>
#import "UITouch+Private.h"
#import "IOHIDEvent+KIF.h"

@interface UITouch (KIFAdditions)

- (instancetype)initTouch;
- (instancetype)initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView *)view;
- (void)setLocationInWindow:(CGPoint)location;
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase;

@end
