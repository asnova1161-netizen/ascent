#import "HUDHelper.h"
#import <spawn.h>
#import <signal.h>
#import <unistd.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <limits.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
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

#pragma mark - Журнал оверлея

static void AscentLogPathsInit(void)
{
    if (gLogPathCount > 0) {
        return;
    }

    NSArray<NSString *> *paths = @[
        [AscentStateDirectory() stringByAppendingPathComponent:@"ascent.hud.log"],
        [@ASCENT_SHARED_CACHE_PATH stringByAppendingPathComponent:@"com.ascentios.ascent.hud.log"],
    ];

    for (NSUInteger index = 0; index < paths.count && gLogPathCount < ASCENT_LOG_MAX_PATHS; index++) {
        const char *cString = paths[index].UTF8String;
        if (cString == NULL || cString[0] == '\0') {
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
    NSString *line = [NSString stringWithFormat:@"%@ [%d uid=%d] %@\n",
                      [NSDate date], (int)getpid(), (int)getuid(), message ?: @"(nil)"];
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

static char gExecutablePath[PATH_MAX];
static int gLastSpawnError = 0;

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
    // выходе на домашний экран. Поэтому (как в TrollSpeed) выводим HUD в
    // собственную группу процессов.
    if (strcmp(argument, "-hud") == 0) {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    }

    const char *args[] = { exe, argument, stateBuf, NULL };
    pid_t pid = -1;
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char **)args, environ);
    if (rc != 0) {
        gLastSpawnError = rc;
    }

    posix_spawnattr_destroy(&attr);

    return rc == 0 ? pid : -1;
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
    gLastSpawnError = 0;

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

#pragma mark - Публичный API

BOOL IsHUDEnabled(void)
{
    NSString *path = AscentPIDFilePath();
    NSFileManager *manager = [NSFileManager defaultManager];

    // Обычный путь: читаем PID-файл сами. Файл пишет root с правами 0644, так
    // что читается кем угодно.
    if ([manager fileExistsAtPath:path] && [manager isReadableFileAtPath:path]) {
        NSString *pidString = [NSString stringWithContentsOfFile:path
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
        pid_t pid = (pid_t)[pidString intValue];
        if (pid <= 0) {
            return NO;
        }

        // HUD бежит от root, поэтому для приложения (оно от mobile) живой
        // процесс даёт EPERM, а не 0. И то, и другое означает «жив».
        if (kill(pid, 0) == 0) {
            return YES;
        }
        return errno == EPERM;
    }

    // Файл почему-то не читается из приложения — спрашиваем root-хелпер: он
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
        AscentHUDLog(@"SetHUDEnabled(YES): запускаю оверлей, uid=%d euid=%d, состояние=%s",
                     getuid(), geteuid(), AscentStateDirectory().UTF8String);

        pid_t pid = AscentSpawnSelf("-hud");
        if (pid > 0) {
            AscentHUDLog(@"spawn -hud ок, pid=%d", pid);

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
            AscentHUDLog(@"!!! spawn -hud НЕ УДАЛСЯ, errno=%d (%s)", gLastSpawnError, strerror(gLastSpawnError));
        }
    } else {
        AscentHUDLog(@"SetHUDEnabled(NO): гашу оверлей");

        NSString *pidString = [NSString stringWithContentsOfFile:AscentPIDFilePath()
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
        pid_t pid = (pid_t)[pidString intValue];

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
