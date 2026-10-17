#import <UIKit/UIKit.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <errno.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "TSEventFetcher.h"
#import "BackboardServices.h"
#import "AXEventRepresentation.h"
#import "UIApplication+Private.h"

// Имя уведомления, которым можно попросить оверлей погаснуть (как в TrollSpeed).
#define ASCENT_NOTIFY_DISMISSAL "com.ascentios.ascent.hud.dismissal"

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

#pragma mark - Диагностика падений HUD

// Падение HUD-процесса иначе выглядит просто как «квадрат исчез». Пишем
// причину в общий журнал, который потом показывает само приложение.
static void AscentHUDSignalHandler(int signalNumber)
{
    char buffer[192];
    int length = snprintf(buffer, sizeof(buffer), "[HUD] !!! HUD pid=%d убит сигналом %d\n", (int)getpid(), signalNumber);
    if (length > 0) {
        AscentHUDLogRaw(buffer);
    }

    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

static void AscentUncaughtExceptionHandler(NSException *exception)
{
    AscentHUDLogMessage([NSString stringWithFormat:@"!!! HUD: необработанное исключение %@: %@\n%@",
                         exception.name, exception.reason, exception.callStackSymbols]);
}

static void AscentInstallCrashHandlers(void)
{
    NSSetUncaughtExceptionHandler(&AscentUncaughtExceptionHandler);

    int signals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        signal(signals[index], AscentHUDSignalHandler);
    }
}

// Пустой callout: таймер нужен только для того, чтобы run loop оверлея не был
// пустым (иначе CFRunLoopRun() возвращается сразу и процесс выходит).
static void AscentKeepAliveTimerCallback(CFRunLoopTimerRef timer, void *info)
{
    (void)timer;
    (void)info;
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

        if (isHelper) {
            // Помечаем строки этого процесса, чтобы в общем журнале было
            // видно, что писал именно оверлей.
            AscentSetProcessMode([NSString stringWithUTF8String:mode]);
            if (strcmp(mode, "-hud") == 0) {
                AscentSetLogPrefix(@"[HUD] ");
            } else if (strcmp(mode, "-check") == 0) {
                AscentSetLogPrefix(@"[check] ");
            } else {
                AscentSetLogPrefix(@"[exit] ");
            }

            AscentHUDLog(@"main: режим %s, pid=%d uid=%d euid=%d, каталог состояния=%s",
                         mode, (int)getpid(), (int)getuid(), (int)geteuid(),
                         AscentStateDirectory().UTF8String);
        }

        if (mode != NULL && strcmp(mode, "-check") == 0)
        {
            // EXIT_FAILURE — оверлей жив, EXIT_SUCCESS — нет.
            NSString *pidString = [NSString stringWithContentsOfFile:AscentPIDFilePath()
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
            if (pidString.length > 0) {
                pid_t pid = (pid_t)[pidString intValue];
                if (pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)) {
                    AscentHUDLog(@"-check: pid=%d жив", pid);
                    return EXIT_FAILURE;
                }
                AscentHUDLog(@"-check: pid=%@ мёртв, errno=%d", pidString, errno);
            } else {
                AscentHUDLog(@"-check: PID-файла нет");
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
                    AscentHUDLog(@"-exit: убиваю pid=%d", pid);
                    kill(pid, SIGKILL);
                }
            } else {
                AscentHUDLog(@"-exit: PID-файла нет");
            }
            AscentRemovePIDFile();
            return EXIT_SUCCESS;
        }

        if (mode != NULL && strcmp(mode, "-hud") == 0)
        {
            AscentInstallCrashHandlers();

            NSString *pidPath = AscentPIDFilePath();
            NSString *pidString = [NSString stringWithFormat:@"%d", (int)getpid()];
            NSError *pidError = nil;
            BOOL pidWritten = [pidString writeToFile:pidPath
                                          atomically:YES
                                            encoding:NSUTF8StringEncoding
                                               error:&pidError];
            AscentHUDLog(@"-hud: старт pid=%@, PID-файл %@ -> %@ (error=%@)",
                         pidString, pidPath, pidWritten ? @"записан" : @"НЕ ЗАПИСАН", pidError);

            // Только чтение собственной подписи — ничего не загружает, поэтому
            // безопасно писать это до инициализации сервисов.
            AscentHUDLog(@"-hud: entitlements:\n%@", AscentOwnEntitlements() ?: @"(не прочитались)");

            [UIScreen initialize];
            CFRunLoopGetCurrent();

            AscentVoidFn fnGSInitialize = (AscentVoidFn)AscentResolvePrivateSymbol("GSInitialize");
            AscentVoidFn fnBKSDisplayServicesStart = (AscentVoidFn)AscentResolvePrivateSymbol("BKSDisplayServicesStart");
            AscentHUDLog(@"-hud: GSInitialize=%p, BKSDisplayServicesStart=%p",
                         (void *)fnGSInitialize, (void *)fnBKSDisplayServicesStart);

            if (fnGSInitialize) {
                fnGSInitialize();
            }

            if (fnBKSDisplayServicesStart) {
                fnBKSDisplayServicesStart();
            }

            UIApplicationInitialize();
            AscentHUDLog(@"-hud: UIApplicationInitialize() ок");

            // Класс SBSAccessibilityWindowHostingController живёт в приватном
            // SpringBoardServices. Без него окно оверлея не выводится на экран
            // вообще (внутри приложения оно есть, поверх — нет).
            dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                   RTLD_NOW | RTLD_GLOBAL);
            AscentHUDLog(@"-hud: SBSAccessibilityWindowHostingController=%p",
                         objc_getClass("SBSAccessibilityWindowHostingController"));

            Class hudApplicationClass = objc_getClass("HUDMainApplication");
            Class hudDelegateClass = objc_getClass("HUDMainApplicationDelegate");
            AscentVoidFn fnGSEventInitialize = (AscentVoidFn)AscentResolvePrivateSymbol("GSEventInitialize");
            AscentVoidFn fnGSEventPushRunLoopMode = (AscentVoidFn)AscentResolvePrivateSymbol("GSEventPushRunLoopMode");
            AscentRegisterHIDEventCallbackFn fnRegisterHIDCallback = (AscentRegisterHIDEventCallbackFn)AscentResolvePrivateSymbol("BKSHIDEventRegisterEventCallback");
            AscentHUDLog(@"-hud: HUDMainApplication=%p, HUDMainApplicationDelegate=%p, GSEventInitialize=%p, GSEventPushRunLoopMode=%p, BKSHIDEventRegisterEventCallback=%p",
                         (__bridge void *)hudApplicationClass, (__bridge void *)hudDelegateClass,
                         (void *)fnGSEventInitialize, (void *)fnGSEventPushRunLoopMode,
                         (void *)fnRegisterHIDCallback);

            UIApplicationInstantiateSingleton(hudApplicationClass);
            // Делегат держим статически: UIApplication.delegate — assign, а не
            // strong, и без этого его бы освободили сразу после setDelegate:.
            static id<UIApplicationDelegate> gHUDAppDelegate = nil;
            gHUDAppDelegate = [[hudDelegateClass alloc] init];
            [UIApplication.sharedApplication setDelegate:gHUDAppDelegate];
            [UIApplication.sharedApplication _accessibilityInit];
            AscentHUDLog(@"-hud: UIApplication поднят, delegate=%@", [UIApplication sharedApplication].delegate);

            [NSRunLoop currentRunLoop];

            // Порядок как в TrollSpeed: сначала подписка на HID-события,
            // потом инициализация GSEvent.
            if (fnRegisterHIDCallback) {
                fnRegisterHIDCallback(AscentHIDEventCallback);
                AscentHUDLog(@"-hud: HID-callback зарегистрирован");
            } else {
                AscentHUDLog(@"!!! -hud: BKSHIDEventRegisterEventCallback не найден — касания работать не будут");
            }

            if (@available(iOS 15.0, *)) {
                if (fnGSEventInitialize) {
                    ((AscentGSEventInitializeFn)fnGSEventInitialize)(0);
                }
                if (fnGSEventPushRunLoopMode) {
                    ((AscentGSEventPushRunLoopModeFn)fnGSEventPushRunLoopMode)(kCFRunLoopDefaultMode);
                }
            }

            [UIApplication.sharedApplication __completeAndRunAsPlugin];
            AscentHUDLog(@"-hud: __completeAndRunAsPlugin ок");

            // Пробы приватных API пишем чуть позже: dlopen посторонних
            // фреймворков до старта run loop может испортить порядок подъёма
            // сервисов. Заодно эта строка доказывает, что run loop жив.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AscentHUDLog(@"-hud: жив уже 2 с, run loop работает");
                AscentHUDLog(@"-hud: пробы приватных API:\n%@", AscentProbeReport());
            });

            // ГЛАВНОЕ: run loop оверлея не должен быть пустым. Если приватный
            // UIEventDispatcher не отдал своих источников (на новых iOS его
            // метод _installEventRunLoopSources: недоступен), CFRunLoopRun()
            // возвращается сразу — процесс выходит, и квадрат пропадает через
            // долю секунды. Поэтому держим run loop своим таймером.
            static CFRunLoopTimerRef gKeepAliveTimer = NULL;
            gKeepAliveTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                                   CFAbsoluteTimeGetCurrent() + 3600.0,
                                                   3600.0, 0, 0,
                                                   AscentKeepAliveTimerCallback, NULL);
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), gKeepAliveTimer, kCFRunLoopDefaultMode);
            AscentHUDLog(@"-hud: keep-alive таймер добавлен (%p), run loop не пустой", gKeepAliveTimer);

            // Гашение оверлея уведомлением — как в TrollSpeed.
            static int gDismissToken = 0;
            notify_register_dispatch(ASCENT_NOTIFY_DISMISSAL, &gDismissToken, dispatch_get_main_queue(), ^(int token) {
                notify_cancel(token);
                AscentHUDLog(@"пришло уведомление о гашении — выходим");
                exit(EXIT_SUCCESS);
            });

            // Перезапуск SpringBoard убивает окна оверлея — поднимаем заново.
            static int gBootToken = 0;
            notify_register_dispatch("SBSpringBoardDidLaunchNotification", &gBootToken, dispatch_get_main_queue(), ^(int token) {
                notify_cancel(token);
                AscentHUDLog(@"SpringBoard перезапустился — поднимаем оверлей заново");
                pid_t selfPid = getpid();
                AscentRemovePIDFile();
                SetHUDEnabled(YES);
                kill(self_pid, SIGKILL);
            });

            // ВАЖНО: здесь больше нет watchdog'а по родителю. Оверлей должен
            // переживать закрытие приложения ascent и гаснуть только по Exit.
            AscentHUDLog(@"-hud: уходим в CFRunLoopRun()");
            CFRunLoopRun();
            AscentHUDLog(@"-hud: run loop завершился, выходим");
            return EXIT_SUCCESS;
        }
    }

    // Обычный запуск: UIKit стартует приложение с нашим Swift-делегатом.
    Class delegateClass = NSClassFromString(@"AppDelegate");
    return UIApplicationMain(argc, argv, nil, delegateClass ? NSStringFromClass(delegateClass) : nil);
}
