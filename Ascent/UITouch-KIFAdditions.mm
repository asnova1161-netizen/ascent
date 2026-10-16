//
//  UITouch-KIFAdditions.mm
//  KIF (adapted for ascent HUD)
//

#import "UITouch-KIFAdditions.h"
#import <objc/runtime.h>

@interface UITouch (KIFAdditionsPrivate)
- (void)kif_setHIDEvent;
@end

@implementation UITouch (KIFAdditions)

- (instancetype)initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView *)view
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    [self setWindow:window];              // wipes out some values, must be first
    [self _setLocationInWindow:point resetPrevious:YES];

    [self setView:view];
    [self setPhase:UITouchPhaseBegan];
    [self _setIsTapToClick:NO];
    [self setTimestamp:[[NSProcessInfo processInfo] systemUptime]];

    if ([self respondsToSelector:@selector(setGestureView:)]) {
        [self setGestureView:view];
    }

    [self kif_setHIDEvent];
    return self;
}

- (instancetype)initTouch
{
    self = [super init];
    if (self == nil) {
        return nil;
    }

    CGPoint point = CGPointZero;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *window = [[[UIApplication sharedApplication] windows] firstObject];
#pragma clang diagnostic pop
    [self setWindow:window];
    [self _setLocationInWindow:point resetPrevious:YES];

    UIView *hitTestView = [window hitTest:point withEvent:nil];
    [self setView:hitTestView];
    [self setPhase:UITouchPhaseEnded];
    [self _setIsTapToClick:NO];
    [self setTimestamp:[[NSProcessInfo processInfo] systemUptime]];

    if ([self respondsToSelector:@selector(setGestureView:)]) {
        [self setGestureView:hitTestView];
    }

    [self kif_setHIDEvent];
    return self;
}

- (void)setLocationInWindow:(CGPoint)location
{
    [self setTimestamp:[[NSProcessInfo processInfo] systemUptime]];
    [self _setLocationInWindow:location resetPrevious:NO];
}

- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase
{
    [self setTimestamp:[[NSProcessInfo processInfo] systemUptime]];
    [self setPhase:phase];
}

- (void)kif_setHIDEvent
{
    IOHIDEventRef event = kif_IOHIDEventWithTouches(@[ self ]);
    if (event != NULL) {
        [self _setHidEvent:event];
        CFRelease(event);
    }
}

@end
