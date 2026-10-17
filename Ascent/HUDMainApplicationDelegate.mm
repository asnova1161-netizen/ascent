#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"
#import "HUDRootViewController.h"
#import "HUDOverlayView.h"

#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"
#import "HUDHelper.h"

@implementation HUDMainApplicationDelegate {
    HUDRootViewController *_rootViewController;
    SBSAccessibilityWindowHostingController *_windowHostingController;
    HUDOverlayView *_overlayView;
}

- (instancetype)init
{
    if (self = [super init])
    {
        AscentHUDLog(@"delegate: init");
    }
    return self;
}

// Один вызов регистрации окна в SpringBoard. Окно перед чтением _contextId
// укладываем: контекст берём уже после layoutIfNeeded (тот же порядок, что в
// PastaWare: makeKeyAndVisible -> setNeedsLayout -> layoutIfNeeded -> _contextId).
- (void)ascentRegisterWindowWithTag:(NSString *)tag
{
    if (_windowHostingController == nil) {
        AscentHUDLog(@"!!! delegate[%@]: хостинг не создан", tag);
        return;
    }

    [self.window setNeedsLayout];
    [self.window layoutIfNeeded];

    unsigned int contextId = [self.window _contextId];
    double windowLevel = [self.window windowLevel];

    AscentHUDLog(@"delegate[%@]: контекст=%u, уровень=%.0f, скрыто=%d, key=%d, сцена=%@, подвью=%lu",
                 tag, contextId, windowLevel, (int)[self.window isHidden],
                 (int)[self.window isKeyWindow], self.window.windowScene,
                 (unsigned long)self.window.subviews.count);

    if (contextId == 0) {
        AscentHUDLog(@"!!! delegate[%@]: contextId=0 — хостингу нечего показывать", tag);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:_windowHostingController];
    [invocation setSelector:registerSelector];
    [invocation setArgument:&contextId atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    [invocation invoke];
#pragma clang diagnostic pop

    AscentHUDLog(@"delegate[%@]: registerWindowWithContextID:atLevel: вызван (контекст=%u, уровень=%.0f)",
                 tag, contextId, windowLevel);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    AscentHUDLog(@"delegate: didFinishLaunchingWithOptions, launchOptions=%@", launchOptions);

    @try {
        _rootViewController = [[HUDRootViewController alloc] init];

        self.window = [[HUDMainWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        [self.window setRootViewController:_rootViewController];
        [self.window setWindowLevel:10000010.0];
        [self.window setHidden:NO];
        [self.window makeKeyAndVisible];
        [self.window setNeedsLayout];
        [self.window layoutIfNeeded];

        AscentHUDLog(@"delegate: окно создано, frame=%@, level=%.0f, hidden=%d, windowScene=%@",
                     NSStringFromCGRect(self.window.bounds), [self.window windowLevel],
                     (int)[self.window isHidden], self.window.windowScene);

        // Квадрат-триггер и панель меню — чистый UIKit, прямо в окне (тот же
        // путь, что и раньше у диагностической метки, а она рисовалась).
        // SwiftUI в HUD-процессе не отрисовывался, поэтому его тут нет.
        _overlayView = [HUDOverlayView overlayForWindow:self.window];
        if (_overlayView != nil) {
            [self.window addSubview:_overlayView];
            AscentHUDLog(@"delegate: UIKit-оверлей добавлен в окно, кадр=%@",
                         NSStringFromCGRect(_overlayView.frame));
        } else {
            AscentHUDLog(@"!!! delegate: не удалось создать UIKit-оверлей");
        }

        Class hostingClass = objc_getClass("SBSAccessibilityWindowHostingController");
        AscentHUDLog(@"delegate: SBSAccessibilityWindowHostingController=%p", (__bridge void *)hostingClass);

        if (hostingClass == nil) {
            AscentHUDLog(@"!!! delegate: SBSAccessibilityWindowHostingController не найден — окно не выведется на экран");
            return YES;
        }

        _windowHostingController = [[hostingClass alloc] init];

        SEL registerSelector = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if (![_windowHostingController respondsToSelector:registerSelector]) {
            AscentHUDLog(@"!!! delegate: у хостинга нет registerWindowWithContextID:atLevel: — окно не выведется на экран");
            return YES;
        }

        AscentHUDLog(@"delegate: хостинг=%p", _windowHostingController);

        // Первый раз — как в TrollSpeed, сразу в делегате.
        [self ascentRegisterWindowWithTag:@"сразу"];

        // Затем повторяем: если контекст окна в момент старта ещё не был готов,
        // SpringBoard о той регистрации ничего не знал. Повторы ничего не ломают
        // (вызов идемпотентный), а шанс показать окно заметно выше.
        for (NSNumber *delay in @[ @0.5, @1.5, @3.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self ascentRegisterWindowWithTag:[NSString stringWithFormat:@"+%.1fс", delay.doubleValue]];
            });
        }
    }
    @catch (NSException *exception) {
        AscentHUDLog(@"!!! delegate: исключение %@: %@\n%@",
                     exception.name, exception.reason, exception.callStackSymbols);
    }

    // Если этой метки нет в журнале — процесс умер синхронно, ещё внутри
    // __completeAndRunAsPlugin, до того как управление вернулось в очередь main.
    AscentHUDLog(@"delegate: хостинг вызван, очередь main свободна");
    return YES;
}

@end
