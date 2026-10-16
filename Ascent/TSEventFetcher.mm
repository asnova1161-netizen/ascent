#import <dlfcn.h>
#import <string.h>
#import <CoreFoundation/CoreFoundation.h>

#import "TSEventFetcher.h"
#import "UIEvent+Private.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication+Private.h"

// Pool of reusable `UITouch` objects (one per pointer id) plus the set of
// touches that are currently down. Events arriving from BackBoard are turned
// into synthetic `UITouch`/`UIEvent` pairs and pushed through
// `-[UIApplication sendEvent:]`, because an accessibility-hosted window does
// not receive real touches from the window server.
static NSMutableArray<UITouch *> *_touchPool = nil;
static NSMutableArray<UITouch *> *_livingTouches = nil;

@implementation TSEventFetcher

+ (void)preparePoolIfNeeded
{
    if (_touchPool != nil) {
        return;
    }

    _touchPool = [NSMutableArray array];
    _livingTouches = [NSMutableArray array];

    for (NSInteger i = 0; i < 100; i++) {
        UITouch *touch = [[UITouch alloc] initTouch];
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
        [_touchPool addObject:touch];
    }
}

+ (NSInteger)receiveAXEventID:(NSInteger)eventId
           atGlobalCoordinate:(CGPoint)coordinate
               withTouchPhase:(UITouchPhase)phase
                     inWindow:(UIWindow *)window
                       onView:(UIView *)view
{
    [self preparePoolIfNeeded];

    NSInteger index = MIN(MAX(eventId, 1), 98) - 1;

    UITouch *touch = nil;

    if (phase == UITouchPhaseBegan) {
        touch = [[UITouch alloc] initAtPoint:coordinate inWindow:window onView:view];
        [_touchPool replaceObjectAtIndex:index withObject:touch];
        [_livingTouches addObject:touch];
    } else {
        touch = _touchPool[index];
        if (![_livingTouches containsObject:touch]) {
            return 0;
        }
        [touch setLocationInWindow:coordinate];
        [touch setPhaseAndUpdateTimestamp:phase];
    }

    UIApplication *app = [UIApplication sharedApplication];
    NSArray<UITouch *> *snapshot = [_livingTouches copy];
    UIEvent *event = [app _touchesEvent];
    [event _clearTouches];
    for (UITouch *t in snapshot) {
        [event _addTouch:t forDelayedDelivery:NO];
    }
    [app sendEvent:event];

    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        [_livingTouches removeObjectIdenticalTo:touch];
    }

    return 0;
}

@end
