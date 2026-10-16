#import "HUDHelper.h"
#import <spawn.h>
#import <unistd.h>
#import <sys/wait.h>
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
// оверлея не поднимается выше обычных приложений.
#define ASCENT_PERSONA_OVERRIDE 1

// Приватные символы персона-спавна достаём через dlsym, чтобы не тянуть
// линковку на приватные API (иначе сборка падала бы на undefined symbol).
typedef int (*AscentPersonaSetNpFn)(const posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
typedef int (*AscentPersonaSetUidFn)(const posix_spawnattr_t *attr, uid_t uid);
typedef int (*AscentPersonaSetGidFn)(const posix_spawnattr_t *attr, gid_t gid);

static AscentPersonaSetNpFn gPersonaSetNp = NULL;
static AscentPersonaSetUidFn gPersonaSetUid = NULL;
static AscentPersonaSetGidFn gPersonaSetGid = NULL;

static void AscentResolvePersonaSymbols(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);
        if (handle == NULL) {
            handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW);
        }

        gPersonaSetNp = (AscentPersonaSetNpFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        gPersonaSetUid = (AscentPersonaSetUidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        gPersonaSetGid = (AscentPersonaSetGidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");

        if (handle != NULL) {
            if (gPersonaSetNp == NULL) gPersonaSetNp = (AscentPersonaSetNpFn)dlsym(handle, "posix_spawnattr_set_persona_np");
            if (gPersonaSetUid == NULL) gPersonaSetUid = (AscentPersonaSetUidFn)dlsym(handle, "posix_spawnattr_set_persona_uid_np");
            if (gPersonaSetGid == NULL) gPersonaSetGid = (AscentPersonaSetGidFn)dlsym(handle, "posix_spawnattr_set_persona_gid_np");
        }
    });
}

static void AscentApplyRootPersona(posix_spawnattr_t *attr)
{
    AscentResolvePersonaSymbols();
    if (gPersonaSetNp) gPersonaSetNp(attr, 99, ASCENT_PERSONA_OVERRIDE);
    if (gPersonaSetUid) gPersonaSetUid(attr, 0);
    if (gPersonaSetGid) gPersonaSetGid(attr, 0);
}

#pragma mark - Общий каталог состояния

static NSString *gAscentStateDir = nil;

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
    }
}

NSString *AscentPIDFilePath(void)
{
    return [AscentStateDirectory() stringByAppendingPathComponent:@"ascent.overlay.pid"];
}

void AscentRemovePIDFile(void)
{
    [[NSFileManager defaultManager] removeItemAtPath:AscentPIDFilePath() error:nil];
}

#pragma mark - Запуск самого себя

static char gExecutablePath[PATH_MAX];

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
    const char *exe = AscentExecutablePath();
    if (exe == NULL) {
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
    int rc = posix_spawn(&pid, exe, NULL, &attr, (char *const *)args, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        return -1;
    }
    return pid;
}

static int AscentSpawnSelfAndWait(const char *argument)
{
    pid_t pid = AscentSpawnSelf(argument);
    if (pid <= 0) {
        return -1;
    }

    int status = 0;
    while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

#pragma mark - Публичный API

BOOL IsHUDEnabled(void)
{
    // `-check` возвращает EXIT_FAILURE, если HUD реально жив, и EXIT_SUCCESS —
    // если его нет. Ошибка запуска (-1) тоже считается «не запущен».
    return AscentSpawnSelfAndWait("-check") == EXIT_FAILURE;
}

void SetHUDEnabled(BOOL isEnabled)
{
    if (isEnabled) {
        if (IsHUDEnabled()) {
            return; // уже работает — второй раз не поднимаем
        }

        pid_t pid = AscentSpawnSelf("-hud");
        if (pid > 0) {
            // Не блокируем вызывающего: HUD живёт сам по себе. Зомби подберём
            // в фоне, чтобы не копить их, пока это приложение открыто.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                int status = 0;
                waitpid(pid, &status, 0);
            });
        }
    } else {
        AscentSpawnSelfAndWait("-exit");
    }
}

NSUserDefaults *GetStandardUserDefaults(void)
{
    return [NSUserDefaults standardUserDefaults];
}
