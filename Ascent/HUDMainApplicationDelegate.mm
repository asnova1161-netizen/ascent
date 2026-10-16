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
    AscentHUDLog(@"delegate: SBSAccessibilityWindowHostingController=%p", (void *)hostingClass);

    _windowHostingController = [[hostingClass alloc] init];
    unsigned int _contextId = [self.window _contextId];
    double windowLevel = [self.window windowLevel];

    AscentHUDLog(@"delegate: contextId=%u, hosting=%p", _contextId, _windowHostingController);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:_windowHostingController];
    [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [invocation setArgument:&_contextId atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    [invocation invoke];
#pragma clang diagnostic pop

    AscentHUDLog(@"delegate: registerWindowWithContextID:atLevel: вызван");

    return YES;
}

@end
