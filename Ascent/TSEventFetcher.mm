#import <dlfcn.h>
#import <string.h>
#import <CoreFoundation/CoreFoundation.h>

#import "TSEventFetcher.h"
#import "UIEvent+Private.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication+Private.h"
#import "HUDHelper.h"

// Pool of reusable `UITouch` objects (one per pointer id) plus the set of
// touches that are currently down. Events arriving from BackBoard are turned
// into synthetic `UITouch`/`UIEvent` pairs and pushed through
// `-[UIApplication sendEvent:]`, because an accessibility-hosted window does
// not receive real touches from the window server.
static NSMutableArray<UITouch *> *_touchPool = nil;
static NSMutableArray<UITouch *> *_livingTouches = nil;

// Сколько касаний может быть «живым» одновременно. Пальцев больше восьми не
// бывает, а ограничение страхует от накопления, если событие «подъёма»
// потеряется: иначе живые касания копились бы в каждом следующем событии.
static const NSUInteger kMaxLivingTouches = 8;

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

// Отправляет одно событие со всеми текущими касаниями. Вынесено отдельно,
// потому что то же событие нужно послать, когда повторное «начал» вытесняет
// старое касание того же пальца.
+ (void)deliverLivingTouches
{
    if (_livingTouches.count == 0) {
        return;
    }

    UIApplication *app = [UIApplication sharedApplication];
    NSArray<UITouch *> *snapshot = [_livingTouches copy];
    UIEvent *event = [app _touchesEvent];
    [event _clearTouches];
    for (UITouch *t in snapshot) {
        [event _addTouch:t forDelayedDelivery:NO];
    }
    [app sendEvent:event];
}

+ (NSInteger)receiveAXEventID:(NSInteger)eventId
           atGlobalCoordinate:(CGPoint)coordinate
               withTouchPhase:(UITouchPhase)phase
                     inWindow:(UIWindow *)window
                       onView:(UIView *)view
{
    // Раздача касаний идёт через UIKit: жест, прокрутка или распознаватель
    // внутри могут бросить исключение (например, при несогласованном касании).
    // Ронять из-за этого весь оверлей нельзя — ловим, пишем в журнал и
    // сбрасываем живые касания, чтобы меню с квадратом остались на экране.
    @try {
        [self deliverTouchWithEventID:eventId
                   atGlobalCoordinate:coordinate
                       withTouchPhase:phase
                             inWindow:window
                               onView:view];
    } @catch (NSException *exception) {
        AscentHUDLog(@"[touch] отправка касания бросила %@: %@ — сбрасываю живые касания",
                     exception.name, exception.reason);
        [_livingTouches removeAllObjects];
    }

    return 0;
}

+ (void)deliverTouchWithEventID:(NSInteger)eventId
             atGlobalCoordinate:(CGPoint)coordinate
                 withTouchPhase:(UITouchPhase)phase
                       inWindow:(UIWindow *)window
                         onView:(UIView *)view
{
    [self preparePoolIfNeeded];

    NSInteger index = MIN(MAX(eventId, 1), 98) - 1;

    UITouch *touch = nil;

    if (phase == UITouchPhaseBegan) {
        // Если для этого пальца касание ещё числится живым, значит событие
        // «подъёма» потерялось либо система помечает «вниз» и на движениях.
        // Новое касание не создаём, а продлеваем текущее как движение: так
        // панель продолжает ехать за пальцем, а «живые» касания не копятся
        // (из-за копления оверлей раньше и падал при перетаскивании).
        UITouch *existing = _touchPool[index];
        if (existing != nil && [_livingTouches indexOfObjectIdenticalTo:existing] != NSNotFound) {
            [existing setLocationInWindow:coordinate];
            [existing setPhaseAndUpdateTimestamp:UITouchPhaseMoved];
            [self deliverLivingTouches];
            return;
        }

        touch = [[UITouch alloc] initAtPoint:coordinate inWindow:window onView:view];
        [_touchPool replaceObjectAtIndex:index withObject:touch];
        [_livingTouches addObject:touch];

        // Страховка: живых касаний не может быть больше, чем пальцев.
        while (_livingTouches.count > kMaxLivingTouches) {
            UITouch *oldest = _livingTouches.firstObject;
            [oldest setPhaseAndUpdateTimestamp:UITouchPhaseCancelled];
            [self deliverLivingTouches];
            [_livingTouches removeObjectIdenticalTo:oldest];
        }
    } else {
        touch = _touchPool[index];
        if (touch == nil || [_livingTouches indexOfObjectIdenticalTo:touch] == NSNotFound) {
            return;
        }
        [touch setLocationInWindow:coordinate];
        [touch setPhaseAndUpdateTimestamp:phase];
    }

    [self deliverLivingTouches];

    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        [_livingTouches removeObjectIdenticalTo:touch];
    }
}

@end
