#import <UIKit/UIKit.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>
#import <dispatch/dispatch.h>

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "TSEventFetcher.h"
#import "BackboardServices.h"
#import "AXEventRepresentation.h"
#import "UIApplication+Private.h"

#define PID_PATH "/var/mobile/Library/Caches/ch.xxtou.hudapp.pid"

// Если родительский процесс (само приложение) умер, HUD больше не нужен —
// сам себя завершаем. Иначе «квадратик» остаётся висеть после закрытия app.
static void AscentStartParentWatchdog(void)
{
    pid_t parentPid = getppid();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                              (uint64_t)(1 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        // Когда приложение закрывается, HUD переподчиняется launchd (pid 1).
        if (getppid() != parentPid) {
            exit(0);
        }
    });
    dispatch_resume(timer);
}

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
            AscentStartParentWatchdog();
            CFRunLoopRun();
            return EXIT_SUCCESS;
        }
    }

    // Normal (non-HUD) launch: let UIKit start the app with our Swift delegate.
    Class delegateClass = NSClassFromString(@"AppDelegate");
    return UIApplicationMain(argc, argv, nil, delegateClass ? NSStringFromClass(delegateClass) : nil);
}
