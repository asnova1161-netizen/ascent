#import "HUDHelper.h"
#import <spawn.h>
#import <signal.h>
#import <unistd.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <limits.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

extern "C" char **environ;

// Персона root (как в TrollSpeed). Без неё `platform-application` и
// `com.apple.private.security.no-sandbox` не действуют, и accessibility-окно
// оверлея не поднимается выше приложений.
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

typedef int (*AscentPersonaSetNpFn)(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
typedef int (*AscentPersonaSetIdFn)(const posix_spawnattr_t *__restrict, uid_t);

static AscentPersonaSetNpFn gPersonaSetNp = NULL;
static AscentPersonaSetIdFn gPersonaSetUid = NULL;
static AscentPersonaSetIdFn gPersonaSetGid = NULL;

static void AscentResolvePersonaSymbols(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gPersonaSetNp = (AscentPersonaSetNpFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        gPersonaSetUid = (AscentPersonaSetIdFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        gPersonaSetGid = (AscentPersonaSetIdFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");

        if (gPersonaSetNp == NULL || gPersonaSetUid == NULL || gPersonaSetGid == NULL) {
            void *handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);
            if (handle == NULL) {
                handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW);
            }
            if (handle != NULL) {
                if (gPersonaSetNp == NULL) gPersonaSetNp = (AscentPersonaSetNpFn)dlsym(handle, "posix_spawnattr_set_persona_np");
                if (gPersonaSetUid == NULL) gPersonaSetUid = (AscentPersonaSetIdFn)dlsym(handle, "posix_spawnattr_set_persona_uid_np");
                if (gPersonaSetGid == NULL) gPersonaSetGid = (AscentPersonaSetIdFn)dlsym(handle, "posix_spawnattr_set_persona_gid_np");
            }
        }
    });
}

static void AscentApplyRootPersona(posix_spawnattr_t *attr)
{
    AscentResolvePersonaSymbols();
    if (gPersonaSetNp) gPersonaSetNp(attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (gPersonaSetUid) gPersonaSetUid(attr, 0);
    if (gPersonaSetGid) gPersonaSetGid(attr, 0);
}

#pragma mark - Общий каталог состояния

static NSString *gAscentStateDir = nil;

// Журнал пишем сразу в два места: в контейнер приложения (там же, где позиции
// квадрата/панели) и в общий /var/mobile/Library/Caches. HUD-процесс бежит от
// root — если одно из мест ему недоступно, второе всё равно останется.
#define ASCENT_SHARED_CACHE_PATH "/var/mobile/Library/Caches"

#define ASCENT_LOG_MAX_PATHS 2
static char gLogPathStorage[ASCENT_LOG_MAX_PATHS][PATH_MAX];
static const char *gLogPaths[ASCENT_LOG_MAX_PATHS];
static int gLogPathCount = 0;

// Журнал не должен расти бесконечно: раз в 2 секунды пишется «HUD alive».
#define ASCENT_LOG_MAX_BYTES (512 * 1024)

NSString *AscentStateDirectory(void)
{
    if (gAscentStateDir.length > 0) {
        return gAscentStateDir;
    }

    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        if (dir.length == 0) {
            dir = NSTemporaryDirectory();
        }
        cached = [dir copy];
    });
    return cached;
}

void AscentSetStateDirectory(NSString *dir)
{
    if (dir.length > 0) {
        gAscentStateDir = [dir copy];
        gLogPathCount = 0;
    }
}

#pragma mark - Журнал

static NSString *gLogPrefix = nil;

void AscentSetLogPrefix(NSString *prefix)
{
    gLogPrefix = [prefix copy];
}

static void AscentLogPathsInit(void)
{
    if (gLogPathCount > 0) {
        return;
    }

    NSArray<NSString *> *paths = @[
        [AscentStateDirectory() stringByAppendingPathComponent:@"ascent.hud.log"],
        [@ASCENT_SHARED_CACHE_PATH stringByAppendingPathComponent:@"com.ascentios.ascent.hud.log"],
    ];
    for (NSString *path in paths) {
        if (gLogPathCount >= ASCENT_LOG_MAX_PATHS) {
            break;
        }
        const char *cString = path.UTF8String;
        if (cString == NULL) {
            continue;
        }
        strncpy(gLogPathStorage[gLogPathCount], cString, PATH_MAX - 1);
        gLogPathStorage[gLogPathCount][PATH_MAX - 1] = '\0';
        gLogPaths[gLogPathCount] = gLogPathStorage[gLogPathCount];
        gLogPathCount++;
    }
}

void AscentHUDLogRaw(const char *text)
{
    if (text == NULL) {
        return;
    }

    AscentLogPathsInit();

    size_t length = strlen(text);
    for (int index = 0; index < gLogPathCount; index++) {
        int fd = open(gLogPaths[index], O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd < 0) {
            continue;
        }

        // Простейшая ротация: файл вырос — начинаем с чистого листа.
        struct stat info;
        if (fstat(fd, &info) == 0 && info.st_size > (off_t)(1024 * 1024)) {
            ftruncate(fd, 0);
        }

        ssize_t written = 0;
        while (written < (ssize_t)length) {
            ssize_t chunk = write(fd, text + written, length - (size_t)written);
            if (chunk <= 0) {
                break;
            }
            written += chunk;
        }
        close(fd);
    }
}

void AscentHUDLogMessage(NSString *message)
{
    NSString *line = [NSString stringWithFormat:@"%@ [%d uid=%d] %@%@\n",
                      [NSDate date], (int)getpid(), (int)getuid(),
                      gLogPrefix.length > 0 ? gLogPrefix : @"",
                      message ?: @"(nil)"];
    AscentHUDLogRaw(line.UTF8String);
}

void AscentHUDLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    AscentHUDLogMessage(message);
}

void AscentHUDLogReset(void)
{
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *path in @[
             [AscentStateDirectory() stringByAppendingPathComponent:@"ascent.hud.log"],
             [@ASCENT_SHARED_CACHE_PATH stringByAppendingPathComponent:@"com.ascentios.ascent.hud.log"],
         ]) {
        [manager removeItemAtPath:path error:nil];
    }
}

// Содержимое первого непустого журнала (контейнер, иначе общий кэш).
static NSString *AscentLogText(void)
{
    AscentLogPathsInit();

    for (int index = 0; index < gLogPathCount; index++) {
        NSString *path = [NSString stringWithUTF8String:gLogPaths[index]];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (text.length > 0) {
            return text;
        }
    }
    return nil;
}

NSString *AscentHUDLogText(void)
{
    AscentLogPathsInit();

    NSMutableString *result = [NSMutableString string];
    for (int index = 0; index < gLogPathCount; index++) {
        NSString *path = [NSString stringWithUTF8String:gLogPaths[index]];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        [result appendFormat:@"=== %@ ===\n%@\n", path, text.length > 0 ? text : @"(пусто)"];
    }
    return result;
}

NSString *AscentHUDLogTail(int maxLines)
{
    if (maxLines <= 0) {
        maxLines = 30;
    }

    NSString *text = AscentLogText();
    if (text.length == 0) {
        return @"(журнал пуст)";
    }

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *tail = [NSMutableArray array];
    for (NSInteger index = (NSInteger)lines.count - 1; index >= 0 && (NSInteger)tail.count < maxLines; index--) {
        [tail insertObject:lines[(NSUInteger)index] atIndex:0];
    }
    return [tail componentsJoinedByString:@"\n"];
}

#pragma mark - Запуск самого себя

// Путь фиксированный и общий для root и для приложения (как в TrollSpeed):
// так его точно видят оба процесса, независимо от песочницы и data protection
// контейнера приложения.
#define ASCENT_HUD_PID_PATH "/var/mobile/Library/Caches/com.ascentios.ascent.overlay.pid"

NSString *AscentPIDFilePath(void)
{
    return @ASCENT_HUD_PID_PATH;
}

void AscentRemovePIDFile(void)
{
    [[NSFileManager defaultManager] removeItemAtPath:AscentPIDFilePath() error:nil];
}

pid_t AscentHUDProcessID(void)
{
    NSString *pidString = [NSString stringWithContentsOfFile:AscentPIDFilePath()
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
    pid_t pid = (pid_t)[pidString intValue];
    return pid > 0 ? pid : 0;
}

static char gExecutablePath[PATH_MAX];
static int gLastSpawnError = 0;
static pid_t gLastSpawnPID = 0;
static char gLastSpawnMode[32];

int AscentLastSpawnReturnCode(void) { return gLastSpawnError; }
int AscentLastSpawnErrno(void) { return gLastSpawnError; }
pid_t AscentLastSpawnPID(void) { return gLastSpawnPID; }
NSString *AscentLastSpawnMode(void) { return [NSString stringWithUTF8String:gLastSpawnMode]; }

static const char *AscentExecutablePath(void)
{
    if (gExecutablePath[0] != '\0') {
        return gExecutablePath;
    }

    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (size == 0 || size > PATH_MAX) {
        return NULL;
    }

    char buf[PATH_MAX];
    if (_NSGetExecutablePath(buf, &size) != 0) {
        return NULL;
    }

    char resolved[PATH_MAX];
    const char *finalPath = realpath(buf, resolved) ? resolved : buf;
    strncpy(gExecutablePath, finalPath, PATH_MAX - 1);
    gExecutablePath[PATH_MAX - 1] = '\0';
    return gExecutablePath;
}

static pid_t AscentSpawnSelf(const char *argument)
{
    gLastSpawnError = 0;
    gLastSpawnPID = 0;
    strncpy(gLastSpawnMode, argument ? argument : "", sizeof(gLastSpawnMode) - 1);
    gLastSpawnMode[sizeof(gLastSpawnMode) - 1] = '\0';

    const char *exe = AscentExecutablePath();
    if (exe == NULL) {
        gLastSpawnError = ENOENT;
        return -1;
    }

    NSString *stateDir = AscentStateDirectory();
    char stateBuf[PATH_MAX];
    if (stateDir.length > 0) {
        strncpy(stateBuf, stateDir.UTF8String, sizeof(stateBuf) - 1);
    } else {
        stateBuf[0] = '\0';
    }
    stateBuf[sizeof(stateBuf) - 1] = '\0';

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        gLastSpawnError = EINVAL;
        return -1;
    }

    AscentApplyRootPersona(&attr);

    // HUD-процесс должен переживать уход приложения в фон и его закрытие.
    // Если оставить его в группе процессов приложения, iOS вместе с
    // приложением приостанавливает и оверлей — и квадрат пропадает при
    // выходе на домашний экран.
    // Для самого оверлея даём СВОЮ группу процессов (как в TrollSpeed), а
    // короткоживущие -check/-exit оставляем в группе родителя, иначе waitpid
    // по ним работал бы нестабильно.
    if (strcmp(argument, "-hud") == 0) {
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        posix_spawnattr_setpgroup(&attr, 0);
    }

    pid_t pid = 0;
    char *const arguments[] = { (char *)exe, (char *)argument, stateBuf, NULL };
    int rc = posix_spawn(&pid, exe, NULL, &attr, arguments, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        gLastSpawnError = rc;
        return -1;
    }

    gLastSpawnPID = pid;
    return pid;
}

static NSString *AscentSignalName(int signalNumber)
{
    switch (signalNumber) {
        case SIGKILL: return @"SIGKILL";
        case SIGTERM: return @"SIGTERM";
        case SIGSEGV: return @"SIGSEGV";
        case SIGABRT: return @"SIGABRT";
        case SIGBUS:  return @"SIGBUS";
        case SIGILL:  return @"SIGILL";
        case SIGTRAP: return @"SIGTRAP";
        case SIGSTOP: return @"SIGSTOP";
        default: return [NSString stringWithFormat:@"сигнал %d", signalNumber];
    }
}

static pid_t AscentSpawnSelfAndWait(const char *argument, int *outStatus)
{
    pid_t pid = AscentSpawnSelf(argument);
    if (pid <= 0) {
        return -1;
    }

    int status = 0;
    while (waitpid(pid, &status, 0) == -1) {
        if (errno != EINTR) {
            return -1;
        }
    }
    if (outStatus != NULL) {
        *outStatus = status;
    }
    return pid;
}

#pragma mark - Пробы приватных API

static NSString *gProcessMode = @"app";

NSString *AscentProcessMode(void) { return gProcessMode; }

void AscentSetProcessMode(NSString *mode)
{
    gProcessMode = mode.length > 0 ? [mode copy] : @"app";
}

// Подгружаем приватные фреймворки, чтобы dlsym/objc_getClass их видели.
// Это же делает и сам оверлей, так что проба отражает реальную картину.
static void AscentLoadPrivateFrameworks(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *frameworks = @[
            @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/System/Library/PrivateFrameworks/SpringBoardUI.framework/SpringBoardUI",
            @"/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation",
            @"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        ];
        for (NSString *path in frameworks) {
            dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        }
    });
}

BOOL AscentProbeSymbol(const char *name)
{
    if (name == NULL) {
        return NO;
    }
    if (dlsym(RTLD_DEFAULT, name) != NULL) {
        return YES;
    }
    AscentLoadPrivateFrameworks();
    return dlsym(RTLD_DEFAULT, name) != NULL;
}

BOOL AscentProbeClass(const char *name)
{
    if (name == NULL) {
        return NO;
    }
    if (objc_getClass(name) != nil) {
        return YES;
    }
    AscentLoadPrivateFrameworks();
    return objc_getClass(name) != nil;
}

NSString *AscentProbeReport(void)
{
    static const char *symbols[] = {
        "GSInitialize",
        "BKSDisplayServicesStart",
        "GSEventInitialize",
        "GSEventPushRunLoopMode",
        "BKSHIDEventRegisterEventCallback",
        "UIApplicationInitialize",
        "UIApplicationInstantiateSingleton",
        "posix_spawnattr_set_persona_np",
        "posix_spawnattr_set_persona_uid_np",
        "posix_spawnattr_set_persona_gid_np",
    };
    static const char *classes[] = {
        "HUDMainApplication",
        "HUDMainApplicationDelegate",
        "HUDRootViewController",
        "HUDMainWindow",
        "HUDHostFactory",
        "AppDelegate",
        "SBSAccessibilityWindowHostingController",
        "AXEventRepresentation",
    };

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"символы (dlsym):\n"];
    for (size_t index = 0; index < sizeof(symbols) / sizeof(symbols[0]); index++) {
        [report appendFormat:@"  %-38s %@\n", symbols[index], AscentProbeSymbol(symbols[index]) ? @"ok" : @"нет"];
    }
    [report appendString:@"классы (objc_getClass):\n"];
    for (size_t index = 0; index < sizeof(classes) / sizeof(classes[0]); index++) {
        [report appendFormat:@"  %-38s %@\n", classes[index], AscentProbeClass(classes[index]) ? @"ok" : @"нет"];
    }
    return report;
}

#pragma mark - Свои entitlements

static uint32_t AscentBigToHost32(uint32_t value)
{
    return ((value & 0x000000FFu) << 24) | ((value & 0x0000FF00u) << 8) |
           ((value & 0x00FF0000u) >> 8) | ((value & 0xFF000000u) >> 24);
}

// Достаём XML с entitlements прямо из подписи Mach-O: это единственный способ
// показать, что реально вшито в бинарник, без приватных API.
static NSData *AscentEntitlementsXMLData(void)
{
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (header == NULL) {
        return nil;
    }

    const uint8_t *base = (const uint8_t *)header;
    const uint8_t *cursor = base + sizeof(struct mach_header_64);
    const uint8_t *limit = cursor + header->sizeofcmds;

    uint32_t dataOffset = 0;
    uint32_t dataSize = 0;
    BOOL found = NO;

    for (uint32_t index = 0; index < header->ncmds && cursor + sizeof(struct load_command) <= limit; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_CODE_SIGNATURE) {
            const struct linkedit_data_command *linkedit = (const struct linkedit_data_command *)command;
            dataOffset = linkedit->dataoff;
            dataSize = linkedit->datasize;
            found = YES;
            break;
        }
        cursor += command->cmdsize;
    }
    if (!found || dataSize < 12) {
        return nil;
    }

    const uint8_t *signature = base + dataOffset;
    uint32_t magic = 0;
    memcpy(&magic, signature, 4);
    if (AscentBigToHost32(magic) != 0xfade0cc0) {
        return nil; // не SuperBlob
    }

    uint32_t count = 0;
    memcpy(&count, signature + 8, 4);
    count = AscentBigToHost32(count);

    for (uint32_t index = 0; index < count; index++) {
        const uint8_t *entry = signature + 12 + (size_t)index * 8;
        if (entry + 8 > base + dataOffset + dataSize) {
            break;
        }

        uint32_t entryType = 0;
        uint32_t entryOffset = 0;
        memcpy(&entryType, entry, 4);
        memcpy(&entryOffset, entry + 4, 4);
        entryType = AscentBigToHost32(entryType);
        entryOffset = AscentBigToHost32(entryOffset);

        // 5 == CSSLOT_ENTITLEMENTS
        if (entryType != 5 || entryOffset + 8 > dataSize) {
            continue;
        }

        const uint8_t *blob = base + dataOffset + entryOffset;
        uint32_t blobMagic = 0;
        uint32_t blobLength = 0;
        memcpy(&blobMagic, blob, 4);
        memcpy(&blobLength, blob + 4, 4);
        blobMagic = AscentBigToHost32(blobMagic);
        blobLength = AscentBigToHost32(blobLength);

        if (blobMagic != 0xfade7171 || blobLength < 8 || entryOffset + blobLength > dataSize) {
            continue;
        }
        return [NSData dataWithBytes:blob + 8 length:blobLength - 8];
    }
    return nil;
}

NSString *AscentOwnEntitlements(void)
{
    NSData *xml = AscentEntitlementsXMLData();
    if (xml.length == 0) {
        return nil;
    }

    id plist = [NSPropertyListSerialization propertyListWithData:xml
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:NULL];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)plist;
        NSMutableString *result = [NSMutableString string];
        NSArray *keys = [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *key in keys) {
            [result appendFormat:@"  %@ = %@\n", key, dictionary[key]];
        }
        return result;
    }
    return [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
}

#pragma mark - Публичный API

BOOL IsHUDEnabled(void)
{
    // Обычный путь: читаем PID-файл сами. Файл пишет root с правами 0644, так
    // что читается кем угодно.
    pid_t pid = AscentHUDProcessID();
    if (pid > 0) {
        // HUD бежит от root, поэтому для приложения (оно от mobile) живой
        // процесс даёт EPERM, а не 0. И то, и другое означает «жив».
        if (kill(pid, 0) == 0 || errno == EPERM) {
            return YES;
        }
        return NO;
    }

    // Файл почему-то недоступен из приложения — спрашиваем root-хелпер: он
    // читает тот же файл и отвечает через код возврата.
    int status = 0;
    if (AscentSpawnSelfAndWait("-check", &status) <= 0) {
        return NO;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == EXIT_FAILURE;
}

void SetHUDEnabled(BOOL isEnabled)
{
    if (isEnabled) {
        if (IsHUDEnabled()) {
            AscentHUDLog(@"SetHUDEnabled(YES): оверлей уже работает, второй раз не поднимаем");
            return;
        }

        AscentHUDLogReset();
        AscentHUDLog(@"SetHUDEnabled(YES): запускаю оверлей, uid=%d euid=%d, состояние=%s, exe=%s",
                     getuid(), geteuid(), AscentStateDirectory().UTF8String,
                     AscentExecutablePath() ? AscentExecutablePath() : "(нет)");

        pid_t pid = AscentSpawnSelf("-hud");
        if (pid > 0) {
            AscentHUDLog(@"spawn -hud ок, rc=0, pid=%d", pid);

            // Не блокируем вызывающего: HUD живёт сам по себе. В фоне дождёмся
            // его завершения и запишем в журнал, чем именно он закончился —
            // это главный ключ к «квадрат пропал».
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                int status = 0;
                pid_t result = waitpid(pid, &status, 0);
                if (result != pid) {
                    AscentHUDLog(@"waitpid(%d) вернул %d, errno=%d", pid, (int)result, errno);
                    return;
                }
                if (WIFSIGNALED(status)) {
                    AscentHUDLog(@"!!! HUD pid=%d убит сигналом %@", pid, AscentSignalName(WTERMSIG(status)));
                } else if (WIFEXITED(status)) {
                    AscentHUDLog(@"!!! HUD pid=%d завершился сам, код %d", pid, WEXITSTATUS(status));
                } else {
                    AscentHUDLog(@"!!! HUD pid=%d остановлен, status=%d", pid, status);
                }
            });
        } else {
            AscentHUDLog(@"!!! spawn -hud НЕ УДАЛСЯ: rc/errno=%d (%s)",
                         gLastSpawnError, strerror(gLastSpawnError));
        }
    } else {
        AscentHUDLog(@"SetHUDEnabled(NO): гашу оверлей");

        pid_t pid = AscentHUDProcessID();
        AscentSpawnSelfAndWait("-exit", NULL);

        if (pid > 0 && kill(pid, 0) == 0) {
            AscentHUDLog(@"после -exit pid=%d всё ещё жив, kill(SIGKILL)", pid);
            kill(pid, SIGKILL);
        }

        AscentRemovePIDFile();
    }
}

NSUserDefaults *GetStandardUserDefaults(void)
{
    return [NSUserDefaults standardUserDefaults];
}
