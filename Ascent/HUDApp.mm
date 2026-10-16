#import <UIKit/UIKit.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "TSEventFetcher.h"
#import "BackboardServices.h"
#import "AXEventRepresentation.h"
#import "UIApplication+Private.h"

// Сервисы GraphicsServices/BackBoardServices не слинкованы в наш бинарь
// (они приватные), поэтому символы достаём из уже загруженных образов.
typedef void (*AscentVoidFn)(void);
typedef void (*AscentGSEventInitializeFn)(unsigned int);
typedef void (*AscentGSEventPushRunLoopModeFn)(CFStringRef);
typedef void (*AscentHIDEventCallbackPtr)(void *, void *, void *, void *);
typedef void (*AscentRegisterHIDEventCallbackFn)(AscentHIDEventCallbackPtr);

static void *AscentResolvePrivateSymbol(const char *name)
{
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol == NULL) {
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW | RTLD_GLOBAL);
        symbol = dlsym(RTLD_DEFAULT, name);
    }
    return symbol;
}

#pragma mark - HID -> синтетические касания

// Accessibility-окно не получает касаний от window-сервера, поэтому мы
// подписываемся на глобальный поток HID-событий и превращаем их в обычные
// UITouch'и для нашего окна. Событие при этом не «съедается» — как только
// палец попадает в квадрат/панель, окно оверлея и так перехватывает касание
// (см. -[HUDMainWindow _ignoresHitTest]).
static Class AscentAXEventRepresentationClass(void)
{
    static Class cls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Без явной загрузки фреймворка objc_getClass вернёт nil и касаний
        // не будет вообще (окно видно, но не нажимается).
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
        cls = objc_getClass("AXEventRepresentation");
    });
    return cls;
}

static void AscentHIDEventCallback(void *target, void *refcon, void *service, void *event)
{
    Class repClass = AscentAXEventRepresentationClass();
    if (repClass == nil) {
        return;
    }

    AXEventRepresentation *rep = [repClass representationWithHIDEvent:(__bridge id)event
                                                    hidStreamIdentifier:@"UIApplicationEvents"];
    if (rep == nil) {
        return;
    }

    CGPoint location = rep.location;
    BOOL isTouchDown = rep.isTouchDown;
    BOOL isTouchMove = rep.isMove;
    BOOL isTouchCancel = rep.isCancel;
    BOOL isTouchUp = rep.isLift || rep.isInRange || rep.isInRangeLift;

    NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];

    dispatch_async(dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *keyWindow = [[[UIApplication sharedApplication] windows] firstObject];
#pragma clang diagnostic pop
        if (keyWindow == nil) {
            return;
        }

        UIView *keyView = [keyWindow hitTest:location withEvent:nil];

        UITouchPhase phase = UITouchPhaseEnded;
        if (isTouchDown) {
            phase = UITouchPhaseBegan;
        } else if (isTouchMove) {
            phase = UITouchPhaseMoved;
        } else if (isTouchCancel) {
            phase = UITouchPhaseCancelled;
        }

        if (pointerId > 0) {
            [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98)
                          atGlobalCoordinate:location
                              withTouchPhase:phase
                                    inWindow:[UIApplication sharedApplication].windows.firstObject
                                      onView:keyView];
        }
    });
}

#pragma mark - main

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        const char *mode = (argc > 1) ? argv[1] : NULL;
        BOOL isHelper = (mode != NULL) && (strcmp(mode, "-hud") == 0 ||
                                           strcmp(mode, "-check") == 0 ||
                                           strcmp(mode, "-exit") == 0);

        // Каталог общих файлов состояния (PID + позиции) приходит из главного
        // процесса: у root-процесса свой «дом», общий путь надо знать точно.
        if (isHelper && argc > 2 && argv[2] != NULL) {
            NSString *dir = [NSString stringWithUTF8String:argv[2]];
            AscentSetStateDirectory(dir);
        }

        if (mode != NULL && strcmp(mode, "-check") == 0)
        {
            // EXIT_FAILURE — оверлей жив, EXIT_SUCCESS — нет.
            NSString *pidString = [NSString stringWithContentsOfFile:AscentPIDFilePath()
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
            if (pidString.length > 0) {
                pid_t pid = (pid_t)[pidString intValue];
                if (pid > 0 && kill(pid, 0) == 0) {
                    return EXIT_FAILURE;
                }
            }
            return EXIT_SUCCESS;
        }

        if (mode != NULL && strcmp(mode, "-exit") == 0)
        {
            NSString *pidString = [NSString stringWithContentsOfFile:AscentPIDFilePath()
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
            if (pidString.length > 0) {
                pid_t pid = (pid_t)[pidString intValue];
                if (pid > 0) {
                    kill(pid, SIGKILL);
                }
            }
            AscentRemovePIDFile();
            return EXIT_SUCCESS;
        }

        if (mode != NULL && strcmp(mode, "-hud") == 0)
        {
            // Запоминаем свой PID: по нему главный процесс понимает, что
            // оверлей уже поднят, и гасит его по Exit.
            pid_t pid = getpid();
            NSString *pidString = [NSString stringWithFormat:@"%d", pid];
            [pidString writeToFile:AscentPIDFilePath()
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:nil];

            [UIScreen initialize];
            CFRunLoopGetCurrent();

            AscentVoidFn fnGSInitialize = (AscentVoidFn)AscentResolvePrivateSymbol("GSInitialize");
            if (fnGSInitialize) {
                fnGSInitialize();
            }

            AscentVoidFn fnBKSDisplayServicesStart = (AscentVoidFn)AscentResolvePrivateSymbol("BKSDisplayServicesStart");
            if (fnBKSDisplayServicesStart) {
                fnBKSDisplayServicesStart();
            }

            UIApplicationInitialize();

            UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
            // Делегат держим статически: UIApplication.delegate — assign, а не
            // strong, и без этого его бы освободили сразу после setDelegate:.
            static id<UIApplicationDelegate> gHUDAppDelegate = nil;
            gHUDAppDelegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
            [UIApplication.sharedApplication setDelegate:gHUDAppDelegate];
            [UIApplication.sharedApplication _accessibilityInit];

            [NSRunLoop currentRunLoop];

            if (@available(iOS 15.0, *)) {
                AscentGSEventInitializeFn fnGSEventInitialize = (AscentGSEventInitializeFn)AscentResolvePrivateSymbol("GSEventInitialize");
                if (fnGSEventInitialize) {
                    fnGSEventInitialize(0);
                }
                AscentGSEventPushRunLoopModeFn fnGSEventPushRunLoopMode = (AscentGSEventPushRunLoopModeFn)AscentResolvePrivateSymbol("GSEventPushRunLoopMode");
                if (fnGSEventPushRunLoopMode) {
                    fnGSEventPushRunLoopMode(kCFRunLoopDefaultMode);
                }
            }

            AscentRegisterHIDEventCallbackFn fnRegisterHIDCallback = (AscentRegisterHIDEventCallbackFn)AscentResolvePrivateSymbol("BKSHIDEventRegisterEventCallback");
            if (fnRegisterHIDCallback) {
                fnRegisterHIDCallback(AscentHIDEventCallback);
            }

            [UIApplication.sharedApplication __completeAndRunAsPlugin];

            // ВАЖНО: здесь больше нет watchdog'а по родителю. Оверлей должен
            // переживать закрытие приложения ascent и гаснуть только по Exit.
            CFRunLoopRun();
            return EXIT_SUCCESS;
        }
    }

    // Обычный запуск: UIKit стартует приложение с нашим Swift-делегатом.
    Class delegateClass = NSClassFromString(@"AppDelegate");
    return UIApplicationMain(argc, argv, nil, delegateClass ? NSStringFromClass(delegateClass) : nil);
}
