#import <UIKit/UIKit.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "TSEventFetcher.h"
#import "BackboardServices.h"
#import "AXEventRepresentation.h"
#import "UIApplication+Private.h"

#define PID_PATH "/var/mobile/Library/Caches/ch.xxtou.hudapp.pid"

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0)
        {
            pid_t pid = getpid();
            NSString *pidPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"ch.xxtou.hudapp.pid"];
            NSString *pidString = [NSString stringWithFormat:@"%d", pid];
            [pidString writeToFile:pidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

            [UIScreen initialize];
            CFRunLoopGetCurrent();

            UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
            id<UIApplicationDelegate> appDelegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
            [UIApplication.sharedApplication setDelegate:appDelegate];
            [UIApplication.sharedApplication _accessibilityInit];

            [NSRunLoop currentRunLoop];

            [UIApplication.sharedApplication __completeAndRunAsPlugin];
            CFRunLoopRun();
            return EXIT_SUCCESS;
        }
    }

    // Normal (non-HUD) launch: let UIKit start the app with our Swift delegate.
    Class delegateClass = NSClassFromString(@"AppDelegate");
    return UIApplicationMain(argc, argv, nil, delegateClass ? NSStringFromClass(delegateClass) : nil);
}
