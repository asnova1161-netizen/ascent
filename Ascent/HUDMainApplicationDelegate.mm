#import <objc/runtime.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"
#import "HUDRootViewController.h"

#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"
#import "HUDHelper.h"

@implementation HUDMainApplicationDelegate {
    HUDRootViewController *_rootViewController;
    SBSAccessibilityWindowHostingController *_windowHostingController;
}

- (instancetype)init
{
    if (self = [super init])
    {
    }
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    AscentHUDLog(@"delegate: didFinishLaunching, launchOptions=%@", launchOptions);

    // Любое исключение здесь иначе убило бы процесс оверлея целиком — и для
    // пользователя это выглядело бы как «квадрат мигнул и пропал».
    @try {
        _rootViewController = [[HUDRootViewController alloc] init];

        self.window = [[HUDMainWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        [self.window setRootViewController:_rootViewController];

        [self.window setWindowLevel:10000010.0];
        [self.window setHidden:NO];
        [self.window makeKeyAndVisible];

        AscentHUDLog(@"delegate: окно создано, frame=%@, level=%.0f, hidden=%d, windowScene=%@",
                     NSStringFromCGRect(self.window.bounds), [self.window windowLevel],
                     (int)[self.window isHidden], self.window.windowScene);

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

        unsigned int _contextId = [self.window _contextId];
        double windowLevel = [self.window windowLevel];

        AscentHUDLog(@"delegate: contextId=%u, hosting=%p", _contextId, _windowHostingController);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:_windowHostingController];
        [invocation setSelector:registerSelector];
        [invocation setArgument:&_contextId atIndex:2];
        [invocation setArgument:&windowLevel atIndex:3];
        [invocation invoke];
#pragma clang diagnostic pop

        AscentHUDLog(@"delegate: registerWindowWithContextID:atLevel: вызван (contextId=%u, level=%.0f)",
                     _contextId, windowLevel);
    }
    @catch (NSException *exception) {
        AscentHUDLog(@"!!! delegate: исключение %@: %@\n%@",
                     exception.name, exception.reason, exception.callStackSymbols);
    }

    // Через 2 секунды после регистрации пишем состояние окна: если процесс жив,
    // а эти строки не появились — значит процессу не дали дожить до 2 секунд.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        AscentHUDLog(@"делегат: окно через 2 с: hidden=%d, level=%.0f, contextId=%u, scene=%@, rootVC=%@",
                     (int)[window isHidden], [window windowLevel], [window _contextId],
                     window.windowScene, window.rootViewController);
    });

    return YES;
}

@end
