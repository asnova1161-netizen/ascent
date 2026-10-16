#import <UIKit/UIKit.h>

@interface UITouch (KIFAdditions)

- (id)initTouch;
- (id)initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView *)view;
- (void)setLocationInWindow:(CGPoint)location;
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase;

@end
