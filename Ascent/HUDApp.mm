#import <UIKit/UIKit.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <signal.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <errno.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

// SDK требует _XOPEN_SOURCE для <ucontext.h>, но менять его на весь файл нельзя
// (это задело бы другие системные заголовки). Определяем только на время
// включения: из него нужен лишь тип ucontext_t, чтобы в обработчике сигнала
// достать pc/lr/fp.
#define _XOPEN_SOURCE 600
#include <ucontext.h>
#undef _XOPEN_SOURCE

// Заголовок разворачивателя стека есть не во всех SDK, а обход по цепочке
// кадров (x29) на arm64 доступен всегда — поэтому он основной.
#if __has_include(<unwind.h>)
#import <unwind.h>
#define ASCENT_HAS_UNWIND 1
#else
#define ASCENT_HAS_UNWIND 0
#endif

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "GameMemory.h"
#import "TSEventFetcher.h"
#import "HUDOverlayView.h"
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

// Идентификатор пальца, который система прислала последним. Нужен потому, что
// у событий движения и подъёма список путей часто пуст: без запоминания такие
// события приходилось бы выбрасывать (панель тогда не едет за пальцем, а
// касание остаётся «живым» навсегда).
static NSInteger AscentActivePointerId = 0;

// Время последнего HID-события. Если палец «висит» и события пропали надолго,
// значит подъём мы не увидели — касание сбрасываем, иначе следующий тап
// потерялся бы (он был бы принят за движение старого пальца).
static NSTimeInterval AscentLastEventTime = 0;

#pragma mark - Состояние пальца из самого HID-события

// Флаги AXEventRepresentation (isMove/isLift/isInRange) на разных версиях iOS
// означают разное, и на одном только «подъём» ловить нельзя: если его принять
// за движение, касание зависает — тапы перестают доходить, а перетаскивание
// «прыгает» к старому месту. Поэтому состояние пальца спрашиваем у самого
// HID-события: у цифрового слоя есть признак касания (touch) и маска того, что
// в событии изменилось.
#define AscentIOHIDEventFieldBase(type) (type << 16)

enum {
    AscentIOHIDEventTypeDigitizer = 11,
};

enum {
    AscentIOHIDDigitizerEventRange    = 1 << 0,
    AscentIOHIDDigitizerEventTouch    = 1 << 1,
    AscentIOHIDDigitizerEventPosition = 1 << 2,
    AscentIOHIDDigitizerEventCancel   = 1 << 7,
};

// Порядок полей ровно как в IOHIDEvent+KIF.mm (IOHIDFamily/IOHIDEventTypes.h):
// от него зависят номера EventMask/Range/Touch.
enum {
    AscentIOHIDEventFieldDigitizerX = AscentIOHIDEventFieldBase(AscentIOHIDEventTypeDigitizer),
    AscentIOHIDEventFieldDigitizerY,
    AscentIOHIDEventFieldDigitizerZ,
    AscentIOHIDEventFieldDigitizerButtonMask,
    AscentIOHIDEventFieldDigitizerType,
    AscentIOHIDEventFieldDigitizerIndex,
    AscentIOHIDEventFieldDigitizerIdentity,
    AscentIOHIDEventFieldDigitizerEventMask,
    AscentIOHIDEventFieldDigitizerRange,
    AscentIOHIDEventFieldDigitizerTouch,
    AscentIOHIDEventFieldDigitizerPressure,
    AscentIOHIDEventFieldDigitizerAuxiliaryPressure,
    AscentIOHIDEventFieldDigitizerTwist,
    AscentIOHIDEventFieldDigitizerTiltX,
    AscentIOHIDEventFieldDigitizerTiltY,
    AscentIOHIDEventFieldDigitizerAltitude,
    AscentIOHIDEventFieldDigitizerAzimuth,
    AscentIOHIDEventFieldDigitizerQuality,
    AscentIOHIDEventFieldDigitizerDensity,
    AscentIOHIDEventFieldDigitizerIrregularity,
    AscentIOHIDEventFieldDigitizerMajorRadius,
    AscentIOHIDEventFieldDigitizerMinorRadius,
    AscentIOHIDEventFieldDigitizerCollection,
    AscentIOHIDEventFieldDigitizerCollectionChord,
    AscentIOHIDEventFieldDigitizerChildEventMask,
};

typedef uint32_t (*AscentIOHIDEventGetTypeFn)(IOHIDEventRef event);
typedef int64_t (*AscentIOHIDEventGetIntegerValueFn)(IOHIDEventRef event, uint32_t field);

// Возвращает: 1 — палец на экране, 0 — палец оторван, -1 — понять нельзя.
static int AscentHIDTouchState(IOHIDEventRef event, unsigned *outMask)
{
    static AscentIOHIDEventGetTypeFn getType = NULL;
    static AscentIOHIDEventGetIntegerValueFn getIntegerValue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                              RTLD_NOW | RTLD_GLOBAL);
        getType = (AscentIOHIDEventGetTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        getIntegerValue = (AscentIOHIDEventGetIntegerValueFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
        if (getType == NULL && handle != NULL) {
            getType = (AscentIOHIDEventGetTypeFn)dlsym(handle, "IOHIDEventGetType");
        }
        if (getIntegerValue == NULL && handle != NULL) {
            getIntegerValue = (AscentIOHIDEventGetIntegerValueFn)dlsym(handle, "IOHIDEventGetIntegerValue");
        }
    });

    if (getType == NULL || getIntegerValue == NULL || event == NULL) {
        return -1;
    }
    if ((uint32_t)getType(event) != AscentIOHIDEventTypeDigitizer) {
        return -1;
    }

    unsigned mask = (unsigned)getIntegerValue(event, AscentIOHIDEventFieldDigitizerEventMask);
    if (outMask != NULL) {
        *outMask = mask;
    }
    // Признак касания осмыслен только там, где он менялся (нажатие/отрыв);
    // на движении меняется лишь позиция.
    if ((mask & AscentIOHIDDigitizerEventTouch) == 0) {
        return -1;
    }
    return (int)getIntegerValue(event, AscentIOHIDEventFieldDigitizerTouch);
}

// Касания пишем в журнал с ограничением: при перетаскивании событий сотни, и
// без ограничения журнал забивался бы, а запись в него тормозила бы оверлей.
static void AscentLogTouch(UITouchPhase phase, CGPoint location, UIView *keyView, NSInteger pointerId)
{
    static NSTimeInterval windowStart = 0;
    static int linesInWindow = 0;
    static int moveCount = 0;

    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (now - windowStart > 0.5) {
        windowStart = now;
        linesInWindow = 0;
    }
    if (linesInWindow >= 20) {
        return;
    }

    static const char *kPhaseNames[] = { "began", "moved", "stationary", "ended", "cancelled" };
    const char *phaseName = (phase >= 0 && phase < 5) ? kPhaseNames[phase] : "?";

    if (phase == UITouchPhaseMoved) {
        moveCount++;
        // Движения пишем редко: они нужны лишь как доказательство, что до окна
        // оверлея вообще доходит поток движения.
        if (moveCount > 3 && moveCount % 25 != 0) {
            return;
        }
    } else {
        moveCount = 0;
    }

    linesInWindow++;
    AscentHUDLog(@"[touch] %s на (%.0f, %.0f) -> %@, pointer=%ld",
                 phaseName, location.x, location.y,
                 keyView != nil ? NSStringFromClass([keyView class]) : @"nil",
                 (long)pointerId);
}

// Признаки первых событий «жеста» пишем как есть (не больше 14 строк на
// касание): по ним видно, какими флагами система помечает протяжку. Без этого
// приходилось угадывать, почему движение не доходит до оверлея.
static void AscentLogRawFlags(BOOL isTouchDown, BOOL isMove, BOOL isLift, BOOL isCancel,
                              BOOL isInRange, BOOL isInRangeLift, unsigned hidMask,
                              int hidTouch, CGPoint location)
{
    static int budget = 0;
    if (isTouchDown) {
        budget = 14;
    }
    if (budget <= 0) {
        return;
    }
    budget--;

    AscentHUDLog(@"[raw] D%d M%d L%d C%d IR%d IRL%d mask=%#x touch=%d на (%.0f, %.0f)",
                 (int)isTouchDown, (int)isMove, (int)isLift, (int)isCancel,
                 (int)isInRange, (int)isInRangeLift, hidMask, hidTouch,
                 location.x, location.y);
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
    BOOL isTouchLift = rep.isLift;
    BOOL isInRange = rep.isInRange;
    BOOL isInRangeLift = rep.isInRangeLift;

    // Отрыв пальца у AX-признаков на разных версиях iOS отмечен по-разному, и
    // «в зоне» (isInRange) приходит и на нажатии, и на движении. Поэтому
    // состояние пальца спрашиваем у самого HID-события: у цифрового слоя есть
    // признак касания (touch) и маска того, что изменилось в событии.
    unsigned hidMask = 0;
    int hidTouch = AscentHIDTouchState((IOHIDEventRef)event, &hidMask);
    BOOL hidTouchTransition = (hidMask & AscentIOHIDDigitizerEventTouch) != 0;
    BOOL hidDown = hidTouchTransition && hidTouch == 1;
    BOOL hidUp = hidTouchTransition && hidTouch == 0;
    BOOL hidCancel = (hidMask & AscentIOHIDDigitizerEventCancel) != 0;

    // Похоже на протяжку? Признак берём и из AX, и из маски HID — по нему
    // отличаем движение от подъёма: подъём приходит с признаком «в зоне», но без
    // изменения позиции, поэтому «в зоне» на движении отрывом считать нельзя.
    BOOL hidPosition = (hidMask & AscentIOHIDDigitizerEventPosition) != 0;
    BOOL looksLikeMove = isTouchMove || (hidPosition && !hidTouchTransition);

    // Палец уже на экране, если «вниз» мы видели, а «подъёма» ещё нет.
    BOOL fingerDown = (AscentActivePointerId != 0);

    // Страховка от потерянного «подъёма»: долгая тишина между событиями —
    // палец давно отпущен.
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (fingerDown && now - AscentLastEventTime > 0.6) {
        AscentActivePointerId = 0;
        fingerDown = NO;
    }
    AscentLastEventTime = now;

    // Отрыв, увиденный по AX-признакам: явные «подъём»/«подъём из зоны», либо
    // «в зоне» на событии, которое не похоже на протяжку и при этом достоверно
    // не «палец внизу» по HID.
    BOOL axEndsTouch = isTouchLift || isInRangeLift ||
                       (isInRange && !looksLikeMove && !hidDown);

    UITouchPhase phase;
    if (isTouchCancel || hidCancel) {
        phase = UITouchPhaseCancelled;
    } else if (hidUp) {
        // Самый надёжный признак отрыва — прямо из HID-события.
        phase = UITouchPhaseEnded;
    } else if ((isTouchDown || hidDown) && !fingerDown) {
        phase = UITouchPhaseBegan;
    } else if (axEndsTouch) {
        phase = UITouchPhaseEnded;
    } else if (fingerDown) {
        phase = UITouchPhaseMoved;
    } else if (looksLikeMove) {
        phase = UITouchPhaseMoved;
    } else {
        phase = UITouchPhaseEnded;
    }

    // Идентификатор пальца приходит не в каждом событии: у движения и подъёма
    // список путей часто пуст и pathIdentity выходит нулевым. Берём сохранённый
    // идентификатор, а по завершении касания забываем его.
    NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];
    if (pointerId > 0) {
        AscentActivePointerId = pointerId;
    } else {
        pointerId = AscentActivePointerId;
    }
    if (phase == UITouchPhaseBegan && pointerId <= 0) {
        // Совсем без идентификатора первое нажатие терять нельзя — берём
        // запасной слот, он нужен лишь чтобы касание доехало до оверлея.
        pointerId = 97;
        AscentActivePointerId = pointerId;
    }
    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        AscentActivePointerId = 0;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *keyWindow = [[[UIApplication sharedApplication] windows] firstObject];
#pragma clang diagnostic pop
        if (keyWindow == nil) {
            return;
        }

        UIView *keyView = [keyWindow hitTest:location withEvent:nil];

        AscentLogTouch(phase, location, keyView, pointerId);
        AscentLogRawFlags(isTouchDown, isTouchMove, isTouchLift, isTouchCancel,
                          isInRange, isInRangeLift, hidMask, hidTouch, location);

        // Перетаскивание и прокрутку ведёт сам оверлей прямо от этих точек: на
        // синтетических UITouch распознаватели движения срабатывают ненадёжно.
        HUDOverlayView *overlay = [HUDOverlayView currentOverlay];
        if (overlay != nil) {
            [overlay handleRawTouchPhase:phase atLocation:location inWindow:keyWindow];
        }

        if (pointerId > 0) {
            [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98)
                          atGlobalCoordinate:location
                              withTouchPhase:phase
                                    inWindow:keyWindow
                                      onView:keyView];
        }
    });
}

#pragma mark - Диагностика падений HUD

// Падение HUD-процесса иначе выглядит просто как «квадрат исчез». Пишем
// причину в общий журнал, который потом показывает само приложение. Кроме
// самого сигнала снимаем стек: без него причину падения искать вслепую.

#define ASCENT_MAX_STACK_FRAMES 24

// Главный поток процесса — запоминаем при старте, чтобы в обработчике сигнала
// было понятно, где именно упало (главный поток или фоновый).
static pthread_t gAscentMainThread;

typedef struct {
    void *frames[ASCENT_MAX_STACK_FRAMES];
    int count;
} AscentStackWalk;

// Печатает один кадр: адрес, символ и образ (имя фреймворка). Форматируем
// только средствами C — в обработчике сигналов нельзя трогать Foundation.
static void AscentLogStackFrame(const char *tag, int index, uintptr_t address)
{
    char buffer[288];
    Dl_info info;

    memset(&info, 0, sizeof(info));
    if (address != 0 && dladdr((void *)address, &info) != 0 && info.dli_fname != NULL) {
        const char *image = strrchr(info.dli_fname, '/');
        image = (image != NULL) ? image + 1 : info.dli_fname;
        uintptr_t offset = info.dli_saddr != NULL ? address - (uintptr_t)info.dli_saddr : 0;
        snprintf(buffer, sizeof(buffer), "[HUD] !!! стек %s #%d: %s + 0x%lx (образ %s)\n",
                 tag, index, info.dli_sname != NULL ? info.dli_sname : "?", (unsigned long)offset, image);
    } else {
        snprintf(buffer, sizeof(buffer), "[HUD] !!! стек %s #%d: 0x%lx (образ не определён)\n",
                 tag, index, (unsigned long)address);
    }
    AscentHUDLogRaw(buffer);
}

#if ASCENT_HAS_UNWIND
static _Unwind_Reason_Code AscentUnwindStep(struct _Unwind_Context *context, void *argument)
{
    AscentStackWalk *walk = (AscentStackWalk *)argument;
    uintptr_t address = (uintptr_t)_Unwind_GetIP(context);

    if (address != 0 && walk->count < ASCENT_MAX_STACK_FRAMES) {
        walk->frames[walk->count++] = (void *)address;
    }
    return (walk->count >= ASCENT_MAX_STACK_FRAMES) ? _URC_END_OF_STACK : _URC_NO_REASON;
}
#endif

static void AscentHUDSignalHandler(int signalNumber, siginfo_t *info, void *context)
{
    // Главный поток запоминаем при старте: по журналу важно сразу понять,
    // упало в главном потоке или в фоновом (например, в ответе XPC).
    pthread_t currentThread = pthread_self();
    char buffer[256];
    int length = snprintf(buffer, sizeof(buffer),
                          "[HUD] !!! HUD pid=%d убит сигналом %d, адрес=%p, поток=%s (%p)\n",
                          (int)getpid(), signalNumber, info != NULL ? info->si_addr : NULL,
                          pthread_equal(currentThread, gAscentMainThread) ? "главный" : "фоновый",
                          (void *)currentThread);
    if (length > 0) {
        AscentHUDLogRaw(buffer);
    }

#if defined(__arm64__)
    if (context != NULL) {
        ucontext_t *ucontext = (ucontext_t *)context;
        AscentLogStackFrame("pc", 0, (uintptr_t)ucontext->uc_mcontext->__ss.__pc);
        AscentLogStackFrame("lr", 0, (uintptr_t)ucontext->uc_mcontext->__ss.__lr);
    }
#endif

    // Стек через разворачиватель (если он есть в SDK): он не доверяет
    // содержимому памяти, поэтому безопасен внутри обработчика сигнала.
#if ASCENT_HAS_UNWIND
    AscentStackWalk walk;
    memset(&walk, 0, sizeof(walk));
    _Unwind_Backtrace(AscentUnwindStep, &walk);
    for (int index = 0; index < walk.count; index++) {
        AscentLogStackFrame("uw", index, (uintptr_t)walk.frames[index]);
    }
#endif

#if defined(__arm64__)
    if (context != NULL) {
        // Обход по цепочке кадров (x29) обычно даёт более «человеческий» стек.
        // Указатели проверяем, чтобы не упасть повторно и не потерять уже
        // записанные строки.
        ucontext_t *ucontext = (ucontext_t *)context;
        uintptr_t framePointer = (uintptr_t)ucontext->uc_mcontext->__ss.__fp;
        for (int index = 0; index < ASCENT_MAX_STACK_FRAMES && framePointer != 0; index++) {
            uintptr_t *frame = (uintptr_t *)framePointer;
            uintptr_t returnAddress = frame[1];
            uintptr_t nextFrame = frame[0];

            if (returnAddress != 0) {
                AscentLogStackFrame("fp", index, returnAddress);
            }
            if (nextFrame <= framePointer || (nextFrame & 0x7) != 0) {
                break;
            }
            framePointer = nextFrame;
        }
    }
#endif

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

    const int signals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = AscentHUDSignalHandler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);

    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        sigaction(signals[index], &action, NULL);
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
        // Запоминаем главный поток до всего остального: обработчик сигналов
        // должен успеть сообщить, где именно упал процесс.
        gAscentMainThread = pthread_self();

        const char *mode = (argc > 1) ? argv[1] : NULL;
        BOOL isHelper = (mode != NULL) && (strcmp(mode, "-hud") == 0 ||
                                           strcmp(mode, "-check") == 0 ||
                                           strcmp(mode, "-exit") == 0 ||
                                           strcmp(mode, "-crash") == 0);

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
            } else if (strcmp(mode, "-crash") == 0) {
                AscentSetLogPrefix(@"[crash] ");
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

        if (mode != NULL && strcmp(mode, "-crash") == 0)
        {
            // Ищем системный отчёт Apple о падении оверлея: там есть и тип
            // исключения, и полный стек. Бежать это должно от root, поэтому
            // запускается как отдельный режим, а не из самого приложения.
            AscentCollectSystemCrashReports();
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
            // безопасно писать это до инициализации сервисов. В журнал пишем
            // коротко: полный дамп прав вытеснял из диагностики всё полезное.
            NSString *entitlements = AscentOwnEntitlements();
            AscentHUDLog(@"-hud: entitlements: %@, accessibility-window-hosting=%d, persona-mgmt=%d",
                         entitlements.length > 0 ? @"прочитаны" : @"НЕ ПРОЧИТАЛИСЬ",
                         (int)(entitlements.length > 0 && [entitlements containsString:@"accessibility-window-hosting"]),
                         (int)(entitlements.length > 0 && [entitlements containsString:@"persona-mgmt"]));

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

            // Проба чужой игры: без task-порта никакие игровые функции
            // невозможны, поэтому состояние доступа пишем в журнал сразу —
            // по нему видно, работает ли вся привилегированная часть.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AscentGameReportProcess(@"standoff");
            });

            // Раз в 1.5 с читаем переключатели меню из общего файла оверлея и
            // держим task-порт игры в соответствии с ними. Пока включённых
            // функций нет — таймер только читает файл.
            static dispatch_source_t gCheatTimer = NULL;
            gCheatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
            dispatch_source_set_timer(gCheatTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                      (uint64_t)(1.5 * NSEC_PER_SEC),
                                      (uint64_t)(0.25 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gCheatTimer, ^{
                AscentGameTick();
            });
            dispatch_resume(gCheatTimer);
            AscentHUDLog(@"-hud: таймер игровых функций поднят (%p)", gCheatTimer);

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
                kill(selfPid, SIGKILL);
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
