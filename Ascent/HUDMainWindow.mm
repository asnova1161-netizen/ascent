#import "HUDMainWindow.h"
#import "HUDRootViewController.h"

@implementation HUDMainWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return [HUDRootViewController passthroughMode]; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

// Пустые места оверлея касаний не забирают: если квадрат и панель под пальцем
// не оказались, окно возвращает nil, и касание достаётся приложению под ним.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) { return nil; }
    return hit;
}

@end
