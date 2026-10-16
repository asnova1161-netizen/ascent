#import "HUDHelper.h"
#import <spawn.h>
#import <notify.h>
#import <mach-o/dyld.h>

extern "C" char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

BOOL IsHUDEnabled(void) {
    return NO;
}

void SetHUDEnabled(BOOL isEnabled) {
    // Spawn HUD process with -hud if enabling
    if (isEnabled) {
        char *executablePath = NULL;
        uint32_t executablePathSize = 0;
        _NSGetExecutablePath(NULL, &executablePathSize);
        executablePath = (char *)calloc(1, executablePathSize);
        _NSGetExecutablePath(executablePath, &executablePathSize);
        
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        
        pid_t task_pid;
        const char *args[] = { executablePath, "-hud", NULL };
        posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);
    }
}

NSUserDefaults *GetStandardUserDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}
