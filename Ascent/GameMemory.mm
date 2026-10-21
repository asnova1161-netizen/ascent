//
//  GameMemory.mm
//  Ascent
//
//  Реализация доступа к памяти чужого процесса. См. GameMemory.h.
//
//  ВАЖНО про API: на iOS SDK заголовок <mach/mach_vm.h> — заглушка
//  ("mach_vm.h unsupported"), поэтому mach_vm_* недоступны. Пользуемся
//  обычными vm_* (на arm64 vm_address_t/vm_size_t — 64-битные, потерь нет),
//  а базу главного модуля берём не обходом регионов, а через TASK_DYLD_INFO.
//

#import "GameMemory.h"
#import "HUDHelper.h"
#import "GameESP.h"
#import "Il2CppDiag.h"

#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

#import <mach/mach.h>
#import <mach/task.h>
#import <mach/task_info.h>
#import <mach/vm_map.h>
#import <mach/mach_host.h>
#import <mach/processor_set.h>
#import <mach-o/loader.h>

// Объявляем сами: в части SDK прототипа нет в публичных заголовках,
// а типы совпадают, поэтому повторное объявление безопасно.
extern "C" kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);

// <mach/mach_vm.h> на iOS SDK — заглушка ("unsupported"), поэтому прототип
// объявляем сами. Рабочий PastaWare читает память именно этим вызовом.
extern "C" kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
                                                mach_vm_address_t address,
                                                mach_vm_size_t size,
                                                mach_vm_address_t data,
                                                mach_vm_size_t *outsize);

// libproc. На iOS заголовка <libproc.h> нет, но функции есть в libsystem.
// Именно ими пользуется рабочий PastaWare: proc_listallpids отдаёт список
// pid, proc_pidpath — ПОЛНЫЙ путь исполняемого файла процесса. Искать игру
// по одному имени (kp_proc.p_comm) нельзя: у Standoff 2 полный путь
// .../Standoff2.app/Standoff2, а p_comm может быть обрезан/пуст, и из
// HUD-процесса (плагин SpringBoard под root) sysctl(KERN_PROC_ALL) список
// процессов игры не показывает — доступ к памяти тогда «не получен» всегда.
extern "C" int proc_listallpids(void *buffer, int buffersize);
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern "C" int proc_name(int pid, void *buffer, uint32_t buffersize);

// processor_set_default / host_processor_set_priv / processor_set_tasks /
// pid_for_task объявлены в <mach/mach_host.h>, <mach/processor_set.h> и
// <mach/task.h> — они уже подключены выше. Этими вызовами рабочий PastaWare
// (sub_10003b8cc) достаёт task-порт, когда task_for_pid его не дал.

// Сколько pid берём за раз. PastaWare просит список дважды: сначала узнать
// число, потом — сами pid.
#define ASCENT_MAX_PIDS 4096

// В части SDK константы нет: просим ядро сделать приватную копию страницы.
#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10
#endif

// Голова dyld_all_image_infos: только стабильные первые поля, без хвоста,
// который в разных версиях iOS разной длины.
//
// Раскладка на arm64 — СНЯТА С РАБОЧЕГО PastaWare (sub_10003b9d8): он читает
// 160 байт структуры и берёт infoArrayCount по смещению +4, а infoArray —
// по +8. Значит:
//   +0x00 version        (u32)
//   +0x04 infoArrayCount (u32)
//   +0x08 infoArray      (ptr)   <- уже выровнен на 8, зазора НЕТ
// Раньше здесь ошибочно считалось, что между счётчиком и массивом есть
// 4-байтовый зазор и infoArray лежит на +0x10 — из-за этого читался мусор,
// и образ UnityFramework не находился. Сверяемся с PastaWare, а не с догадкой.
typedef struct {
    uint32_t version;
    uint32_t infoArrayCount;
    uint64_t infoArray;
} AscentDyldImagesHead;

// dyld_image_info (arm64): три указателя, размер не менялся.
typedef struct {
    uint64_t imageLoadAddress;
    uint64_t imageFilePath;
    uint64_t imageFileModDate;
} AscentDyldImageInfo;

static task_t   gGameTask = MACH_PORT_NULL;
static int      gGamePid = 0;
static uint64_t gGameBase = 0;
static uint64_t gGameSize = 0;
static NSString *gGameError = nil;

// Последние прочитанные переключатели: чтобы писать в журнал только изменения.
static double gLastEsp = -1.0;
static double gLastAimbot = -1.0;

static void AscentGameSetError(NSString *message)
{
    gGameError = message;
}

static void AscentGameSetErrorFormat(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    gGameError = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
}

#pragma mark - Поиск процесса

static BOOL AscentContainsInsensitive(const char *haystack, const char *needle)
{
    if (haystack == NULL || needle == NULL || needle[0] == '\0') {
        return NO;
    }

    size_t needleLength = strlen(needle);
    for (const char *cursor = haystack; cursor[0] != '\0'; cursor++) {
        size_t matched = 0;
        while (matched < needleLength && cursor[matched] != '\0') {
            char left = cursor[matched];
            char right = needle[matched];
            if (left >= 'A' && left <= 'Z') left = (char)(left + 32);
            if (right >= 'A' && right <= 'Z') right = (char)(right + 32);
            if (left != right) break;
            matched++;
        }
        if (matched == needleLength) return YES;
    }
    return NO;
}

int AscentGameFindProcess(NSString *nameHint)
{
    if (nameHint.length == 0) {
        AscentGameSetError(@"имя процесса не задано");
        return -1;
    }

    const char *hint = nameHint.UTF8String;

    // Основной путь — ровно как у рабочего PastaWare (sub_10003b794):
    //   1) proc_listallpids(NULL, 0)              — сколько всего pid;
    //   2) proc_listallpids(pids, count*4)        — сами pid;
    //   3) proc_name(pid, buf, 1000)              — короткое имя процесса;
    //   4) strcasestr(buf, "Standoff2")           — регистронезависимая подстрока.
    // Дополнительно сверяем полный путь (proc_pidpath): если короткое имя
    // почему-то не отдалось, путь всё равно содержит «Standoff2».
    int found = -1;
    int count = proc_listallpids(NULL, 0);
    if (count > 0) {
        if (count > ASCENT_MAX_PIDS) { count = ASCENT_MAX_PIDS; }
        int *pids = (int *)malloc(sizeof(int) * (size_t)count);
        if (pids != NULL) {
            int filled = proc_listallpids(pids, (int)(sizeof(int) * (size_t)count));
            int got = filled > 0 ? (filled / (int)sizeof(int)) : 0;
            for (int i = 0; i < got && found < 0; i++) {
                int pid = pids[i];
                if (pid <= 0) continue;

                // 3) Короткое имя процесса — как в PastaWare.
                char shortName[1024];
                memset(shortName, 0, sizeof(shortName));
                if (proc_name(pid, shortName, (uint32_t)sizeof(shortName)) > 0 &&
                    AscentContainsInsensitive(shortName, hint)) {
                    found = pid;
                    break;
                }

                // Запас: полный путь исполняемого файла.
                char path[4096];
                memset(path, 0, sizeof(path));
                if (proc_pidpath(pid, path, (uint32_t)sizeof(path)) > 0 &&
                    AscentContainsInsensitive(path, hint)) {
                    found = pid;
                    break;
                }
            }
            free(pids);
        }
    }

    if (found > 0) {
        AscentHUDLog(@"[game] поиск «%@»: pid=%d (proc_listallpids: %d процессов)", nameHint, found, count);
        return found;
    }
    AscentHUDLog(@"[game] поиск «%@»: НЕ найден (proc_listallpids вернул %d)", nameHint, count);

    // Запасной путь: старый перебор через sysctl. На части сборок iOS он всё
    // же видит нужный процесс — пусть будет, вреда нет.
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) == 0 && length > 0) {
        struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
        if (procs != NULL) {
            if (sysctl(mib, 4, procs, &length, NULL, 0) == 0) {
                size_t n = length / sizeof(struct kinfo_proc);
                for (size_t i = 0; i < n; i++) {
                    const char *name = procs[i].kp_proc.p_comm;
                    if (name[0] == '\0') continue;
                    if (AscentContainsInsensitive(name, hint)) {
                        found = procs[i].kp_proc.p_pid;
                        break;
                    }
                }
            }
            free(procs);
        }
    }

    if (found <= 0) {
        AscentGameSetErrorFormat(@"процесс «%@» не найден", nameHint);
    }
    return found;
}

#pragma mark - Чтение/запись

BOOL AscentGameRead(uint64_t address, void *buffer, size_t length)
{
    if (gGameTask == MACH_PORT_NULL) {
        AscentGameSetError(@"task-порта нет");
        return NO;
    }
    if (buffer == NULL || length == 0) {
        AscentGameSetError(@"некорректный буфер чтения");
        return NO;
    }

    // Читаем ровно тем же вызовом, что и рабочий PastaWare —
    // mach_vm_read_overwrite(gGameTask, addr, size, buf, &readBytes).
    // vm_read_overwrite на части сборок iOS устарел и может отказывать там,
    // где mach_vm_read_overwrite проходит.
    mach_vm_size_t readBytes = 0;
    kern_return_t result = mach_vm_read_overwrite(gGameTask,
                                                  (mach_vm_address_t)address,
                                                  (mach_vm_size_t)length,
                                                  (mach_vm_address_t)buffer,
                                                  &readBytes);
    if (result != KERN_SUCCESS || readBytes != (mach_vm_size_t)length) {
        AscentGameSetErrorFormat(@"чтение 0x%llx (%zu байт) не удалось: 0x%x, errno=%d",
                                 address, length, result, errno);
        return NO;
    }
    return YES;
}

BOOL AscentGameWrite(uint64_t address, const void *buffer, size_t length)
{
    if (gGameTask == MACH_PORT_NULL) {
        AscentGameSetError(@"task-порта нет");
        return NO;
    }
    if (buffer == NULL || length == 0) {
        AscentGameSetError(@"некорректный буфер записи");
        return NO;
    }

    // Страница может быть доступна только на чтение: просим ядро сделать
    // приватную копию (VM_PROT_COPY), иначе запись молча не пройдёт.
    vm_size_t pageSize = (vm_size_t)getpagesize();
    if (pageSize > 0) {
        vm_address_t pageStart = (vm_address_t)(address & ~((uint64_t)pageSize - 1));
        vm_size_t pageLength = (vm_size_t)(length + (address - pageStart) + pageSize - 1);
        kern_return_t protect = vm_protect(gGameTask, pageStart, pageLength, FALSE,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (protect != KERN_SUCCESS) {
            AscentHUDLog(@"[game] !!! снять защиту страницы 0x%llx не вышло: 0x%x",
                         (uint64_t)pageStart, protect);
        }
    }

    kern_return_t result = vm_write(gGameTask,
                                   (vm_address_t)address,
                                   (vm_offset_t)buffer,
                                   (mach_msg_type_number_t)length);
    if (result != KERN_SUCCESS) {
        AscentGameSetErrorFormat(@"запись 0x%llx (%zu байт) не удалась: 0x%x",
                                 address, length, result);
        return NO;
    }
    return YES;
}

#pragma mark - База главного модуля

static uint64_t AscentHeaderTextSize(uint64_t base)
{
    struct mach_header_64 header;
    if (!AscentGameRead(base, &header, sizeof(header))) {
        return 0;
    }
    if (header.magic != MH_MAGIC_64) {
        return 0;
    }

    uint64_t offset = base + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header.ncmds && i < 8192; i++) {
        struct load_command command;
        if (!AscentGameRead(offset, &command, sizeof(command))) {
            return 0;
        }
        if (command.cmdsize == 0) {
            return 0;
        }
        if (command.cmd == LC_SEGMENT_64) {
            struct segment_command_64 segment;
            if (AscentGameRead(offset, &segment, sizeof(segment))) {
                if (strncmp(segment.segname, "__TEXT", 16) == 0) {
                    return segment.vmsize;
                }
            }
        }
        offset += command.cmdsize;
    }
    return 0;
}

// База главного исполняемого модуля: первый образ в списке dyld.
static uint64_t AscentMainModuleBase(uint64_t *outSize)
{
    task_dyld_info_data_t dyldInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t result = task_info(gGameTask, TASK_DYLD_INFO,
                                    (task_info_t)&dyldInfo, &count);
    if (result != KERN_SUCCESS) {
        AscentGameSetErrorFormat(@"TASK_DYLD_INFO не дался: 0x%x", result);
        return 0;
    }
    if (dyldInfo.all_image_info_addr == 0) {
        AscentGameSetError(@"dyld не отдал список образов");
        return 0;
    }

    AscentDyldImagesHead head;
    if (!AscentGameRead((uint64_t)dyldInfo.all_image_info_addr, &head, sizeof(head))) {
        return 0;
    }
    if (head.infoArray == 0 || head.infoArrayCount == 0) {
        AscentGameSetError(@"список образов dyld пуст");
        return 0;
    }

    AscentDyldImageInfo firstImage;
    if (!AscentGameRead(head.infoArray, &firstImage, sizeof(firstImage))) {
        return 0;
    }

    uint64_t base = firstImage.imageLoadAddress;
    if (base == 0) {
        AscentGameSetError(@"dyld отдал нулевую базу образа");
        return 0;
    }
    if (outSize != NULL) {
        *outSize = AscentHeaderTextSize(base);
    }
    return base;
}

#pragma mark - Подключение/отключение

BOOL AscentGameIsAttached(void)
{
    return gGameTask != MACH_PORT_NULL;
}

int AscentGamePid(void)        { return gGamePid; }
uint64_t AscentGameModuleBase(void) { return gGameBase; }
uint64_t AscentGameModuleSize(void) { return gGameSize; }
mach_port_t AscentGameTask(void)    { return gGameTask; }

void AscentGameDetach(void)
{
    if (gGameTask != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), gGameTask);
        gGameTask = MACH_PORT_NULL;
    }
    gGamePid = 0;
    gGameBase = 0;
    gGameSize = 0;
}

// Получение task-порта игры: сначала task_for_pid (как PastaWare
// sub_10003b758), при неудаче — перебор всех задач ядра через
// processor_set_tasks (как PastaWare sub_10003b8cc). Без этой второй дороги
// на части устройств/сборок iOS task_for_pid не отдаёт порт, и любое чтение
// памяти игры невозможно — ESP тогда честно пишет «нет доступа».
//
// host_processor_set_priv — приватный вызов; в публичном iOS SDK его
// заголовка может не быть. Поэтому берём его через dlsym: так сборка не
// зависит от версии SDK, а на устройстве символ есть (PastaWare зовёт его же).
typedef kern_return_t (*AscentHostPsetPrivFn)(host_t, processor_set_t, processor_set_t *);

static AscentHostPsetPrivFn AscentHostPsetPriv(void)
{
    static AscentHostPsetPrivFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (AscentHostPsetPrivFn)dlsym(RTLD_DEFAULT, "host_processor_set_priv");
    });
    return fn;
}

static task_t AscentTaskForPid(int pid)
{
    task_t task = MACH_PORT_NULL;

    // Дорога 1: обычный task_for_pid.
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr == KERN_SUCCESS && task != MACH_PORT_NULL) {
        return task;
    }
    AscentHUDLog(@"[game] task_for_pid(%d) = 0x%x — пробую processor_set_tasks", pid, kr);

    // Дорога 2: processor_set_default -> host_processor_set_priv ->
    // processor_set_tasks -> pid_for_task. Точная копия того, что делает
    // рабочий PastaWare.
    AscentHostPsetPrivFn psetPrivFn = AscentHostPsetPriv();
    if (psetPrivFn == NULL) {
        AscentHUDLog(@"[game] host_processor_set_priv недоступен");
        return MACH_PORT_NULL;
    }

    host_t host = mach_host_self();
    processor_set_t pset = MACH_PORT_NULL;
    processor_set_t psetPriv = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t taskCount = 0;

    if (processor_set_default(host, &pset) != KERN_SUCCESS) { return MACH_PORT_NULL; }
    if (psetPrivFn(host, pset, &psetPriv) != KERN_SUCCESS) { return MACH_PORT_NULL; }
    if (processor_set_tasks(psetPriv, &tasks, &taskCount) != KERN_SUCCESS) { return MACH_PORT_NULL; }

    for (mach_msg_type_number_t i = 0; i < taskCount; i++) {
        int taskPid = 0;
        if (pid_for_task(tasks[i], &taskPid) != KERN_SUCCESS) { continue; }
        if (taskPid == pid) {
            task = tasks[i];
            break;
        }
    }
    if (tasks != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)tasks,
                      (vm_size_t)(taskCount * sizeof(task_t)));
    }
    if (task == MACH_PORT_NULL) {
        AscentHUDLog(@"[game] processor_set_tasks: задача pid=%d не найдена", pid);
    } else {
        AscentHUDLog(@"[game] processor_set_tasks: задача pid=%d найдена", pid);
    }
    return task;
}

// Функции ниже определены в разделе «Образы (dyld)»: объявляем их заранее,
// потому что привязка к игре пользуется ими.
static uint64_t AscentImageBaseInTask(task_t task, const char *needle);
static BOOL AscentFindGameByContent(int *outPid, task_t *outTask, uint64_t *outBase);
static BOOL AscentFindGameByPidScan(int *outPid, task_t *outTask, uint64_t *outBase);

// Читаем СВОИ подписи-права через csops (CS_OPS_ENTITLEMENTS_BLOB = 7):
// blob — это plist, поэтому достаточно найти в нём строку с именем права.
// Нужно, чтобы на устройстве было видно, дали ли процессу task_for_pid-allow
// вообще: без него ни одна дорога к памяти игры не работает, и лечится это
// только переупаковкой, а не кодом.
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static BOOL AscentSelfHasTaskForPidEntitlement(void)
{
    const size_t blobSize = 16384;
    uint8_t *blob = (uint8_t *)malloc(blobSize);
    if (blob == NULL) {
        return NO;
    }
    memset(blob, 0, blobSize);

    BOOL found = NO;
    if (csops(getpid(), 7, blob, blobSize) == 0) {
        static const char needle[] = "task_for_pid-allow";
        const size_t needleLength = sizeof(needle) - 1;
        for (size_t i = 0; i + needleLength < blobSize; i++) {
            if (memcmp(blob + i, needle, needleLength) == 0) {
                found = YES;
                break;
            }
        }
    }

    free(blob);
    return found;
}

BOOL AscentGameAttach(NSString *nameHint)
{
    AscentGameDetach();

    static BOOL sLoggedEntitlement = NO;
    if (!sLoggedEntitlement) {
        sLoggedEntitlement = YES;
        AscentHUDLog(@"[game] права процесса: task_for_pid-allow %@",
                     AscentSelfHasTaskForPidEntitlement() ? @"ЕСТЬ" : @"НЕТ");
    }

    int pid = AscentGameFindProcess(nameHint);
    task_t task = MACH_PORT_NULL;
    uint64_t unityBase = 0;

    // Дорога 1: нашли процесс по имени — берём его task-порт.
    if (pid > 0) {
        task = AscentTaskForPid(pid);
        if (task != MACH_PORT_NULL) {
            unityBase = AscentImageBaseInTask(task, "UnityFramework");
            if (unityBase == 0) {
                // Порт дали, но UnityFramework в задаче нет — это не игра.
                AscentHUDLog(@"[game] pid=%d без UnityFramework — ищу игру по содержимому", pid);
                mach_port_deallocate(mach_task_self(), task);
                task = MACH_PORT_NULL;
            }
        }
    }

    // Дорога 2: имя/pid ничего не дали — перебираем все задачи ядра и берём
    // ту, в которой есть UnityFramework. Это работает даже когда proc_name и
    // proc_listallpids не отдают список процессов.
    if (task == MACH_PORT_NULL) {
        int foundPid = 0;
        task_t foundTask = MACH_PORT_NULL;
        uint64_t foundBase = 0;
        if (AscentFindGameByContent(&foundPid, &foundTask, &foundBase)) {
            pid = foundPid;
            task = foundTask;
            unityBase = foundBase;
            AscentHUDLog(@"[game] игра найдена по содержимому: pid=%d UnityFramework=0x%llx",
                         pid, unityBase);
        } else if (AscentFindGameByPidScan(&foundPid, &foundTask, &foundBase)) {
            pid = foundPid;
            task = foundTask;
            unityBase = foundBase;
        }
    }

    if (task == MACH_PORT_NULL) {
        AscentGameSetErrorFormat(@"task-порт игры не получен (pid %d)", pid);
        AscentHUDLog(@"[game] доступ НЕ получен: %@", gGameError);
        return NO;
    }

    gGamePid = pid;
    gGameTask = task;
    gGameBase = unityBase;
    gGameSize = 0;
    gGameError = nil;
    AscentHUDLog(@"[game] доступ есть: pid=%d UnityFramework=0x%llx task=%u",
                 pid, unityBase, (unsigned)task);
    return YES;
}

NSString *AscentGameStatus(void)
{
    if (gGameTask == MACH_PORT_NULL) {
        if (gGameError.length > 0) {
            return [NSString stringWithFormat:@"нет доступа (%@)", gGameError];
        }
        return @"нет доступа";
    }
    return [NSString stringWithFormat:@"pid %d, UnityFramework 0x%llx", gGamePid, gGameBase];
}

void AscentGameReportProcess(NSString *nameHint)
{
    int pid = AscentGameFindProcess(nameHint);
    if (pid <= 0) {
        AscentHUDLog(@"[game] процесс «%@»: %@", nameHint, gGameError ?: @"не найден");
        return;
    }
    AscentHUDLog(@"[game] процесс «%@» есть: pid=%d (task-порт ещё не брали)", nameHint, pid);
}

void AscentGameProbe(NSString *nameHint)
{
    int pid = AscentGameFindProcess(nameHint);
    if (pid > 0) {
        AscentHUDLog(@"[game] процесс «%@» найден: pid=%d, беру task-порт", nameHint, pid);
    } else {
        // Имя ничего не дало — это ещё не приговор: AscentGameAttach сам
        // переберёт все задачи ядра и найдёт игру по образу UnityFramework.
        AscentHUDLog(@"[game] процесс «%@»: %@ — перебираю задачи", nameHint, gGameError ?: @"не найден");
    }

    if (AscentGameAttach(nameHint)) {
        AscentHUDLog(@"[game] доступ есть: %@", AscentGameStatus());
    } else {
        AscentHUDLog(@"[game] доступ НЕ получен: %@", gGameError ?: @"неизвестно");
    }
}

#pragma mark - Поиск шаблонов

uint64_t AscentGameScanPattern(uint64_t start, uint64_t length,
                               const void *pattern, const char *mask)
{
    if (gGameTask == MACH_PORT_NULL) {
        AscentGameSetError(@"task-порта нет");
        return 0;
    }
    if (pattern == NULL || mask == NULL) {
        AscentGameSetError(@"шаблон не задан");
        return 0;
    }

    size_t patternLength = strlen(mask);
    if (patternLength == 0 || length < patternLength) {
        AscentGameSetError(@"шаблон пустой или длиннее области поиска");
        return 0;
    }

    const uint64_t chunkSize = 1024 * 1024;
    const size_t overlap = patternLength - 1;
    uint8_t *chunk = (uint8_t *)malloc((size_t)chunkSize + overlap);
    if (chunk == NULL) {
        AscentGameSetError(@"нет памяти под буфер поиска");
        return 0;
    }

    const uint8_t *bytes = (const uint8_t *)pattern;
    uint64_t found = 0;

    for (uint64_t offset = 0; offset < length; offset += chunkSize) {
        uint64_t remaining = length - offset;
        size_t want = (size_t)(remaining < chunkSize + overlap ? remaining : chunkSize + overlap);

        if (!AscentGameRead(start + offset, chunk, want)) {
            continue;
        }

        for (size_t i = 0; i + patternLength <= want; i++) {
            BOOL matched = YES;
            for (size_t j = 0; j < patternLength; j++) {
                if (mask[j] == '?') continue;
                if (chunk[i + j] != bytes[j]) {
                    matched = NO;
                    break;
                }
            }
            if (matched) {
                found = start + offset + i;
                break;
            }
        }

        if (found != 0) break;
    }

    free(chunk);

    if (found == 0) {
        AscentGameSetErrorFormat(@"шаблон не найден в 0x%llx..0x%llx", start, start + length);
    }
    return found;
}

#pragma mark - Образы (dyld)

// База образа, в пути которого есть `needle`, для ПРОИЗВОЛЬНОЙ задачи.
// Читаем через mach_vm_read_overwrite прямо по переданному task-порту: так
// можно проверить чужую задачу, ещё не выбрав её как игру. Именно этот
// признак (наличие UnityFramework) однозначно отличает Standoff 2 от любого
// другого процесса — имя процесса и proc_listallpids для этого не нужны.
static uint64_t AscentImageBaseInTask(task_t task, const char *needle)
{
    if (task == MACH_PORT_NULL || needle == NULL || needle[0] == '\0') {
        return 0;
    }

    task_dyld_info_data_t dyldInfo;
    mach_msg_type_number_t infoCount = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &infoCount) != KERN_SUCCESS) {
        return 0;
    }
    if (dyldInfo.all_image_info_addr == 0) {
        return 0;
    }

    // Голова dyld_all_image_infos: infoArrayCount на +4, infoArray на +8 —
    // ровно те смещения, что и в рабочем PastaWare.
    uint8_t head[32];
    memset(head, 0, sizeof(head));
    mach_vm_size_t got = 0;
    if (mach_vm_read_overwrite(task,
                               (mach_vm_address_t)dyldInfo.all_image_info_addr,
                               (mach_vm_size_t)sizeof(head),
                               (mach_vm_address_t)head, &got) != KERN_SUCCESS || got < 16) {
        return 0;
    }

    uint32_t imageCount = 0;
    uint64_t imageArray = 0;
    memcpy(&imageCount, head + 4, 4);
    memcpy(&imageArray, head + 8, 8);
    if (imageCount == 0 || imageCount > 8192 || imageArray == 0) {
        return 0;
    }

    size_t arrayBytes = (size_t)imageCount * 24;   // dyld_image_info: 3 x u64
    uint8_t *images = (uint8_t *)malloc(arrayBytes);
    if (images == NULL) {
        return 0;
    }

    uint64_t result = 0;
    got = 0;
    if (mach_vm_read_overwrite(task,
                               (mach_vm_address_t)imageArray,
                               (mach_vm_size_t)arrayBytes,
                               (mach_vm_address_t)images, &got) == KERN_SUCCESS) {
        for (uint32_t i = 0; i < imageCount && result == 0; i++) {
            uint64_t loadAddress = 0;
            uint64_t filePathPtr = 0;
            memcpy(&loadAddress, images + (size_t)i * 24 + 0, 8);
            memcpy(&filePathPtr, images + (size_t)i * 24 + 8, 8);
            if (loadAddress == 0 || filePathPtr == 0) {
                continue;
            }

            // Путь читаем кусками по 64 байта до NUL: так один длинный путь
            // не упирается в границу страницы и чтение не падает целиком.
            char path[320];
            memset(path, 0, sizeof(path));
            int done = 0;
            for (size_t off = 0; off + 64 < sizeof(path) && !done; off += 64) {
                char chunk[64];
                memset(chunk, 0, sizeof(chunk));
                mach_vm_size_t pathGot = 0;
                if (mach_vm_read_overwrite(task,
                                           (mach_vm_address_t)(filePathPtr + off),
                                           (mach_vm_size_t)sizeof(chunk),
                                           (mach_vm_address_t)chunk, &pathGot) != KERN_SUCCESS) {
                    break;
                }
                for (size_t k = 0; k < sizeof(chunk); k++) {
                    path[off + k] = chunk[k];
                    if (chunk[k] == 0) { done = 1; break; }
                }
            }
            path[sizeof(path) - 1] = 0;

            if (strstr(path, needle) != NULL) {
                result = loadAddress;
            }
        }
    }

    free(images);
    return result;
}

// Поиск игры «по содержимому»: перебираем ВСЕ задачи ядра и берём ту, в
// списке образов которой есть UnityFramework. Не зависит ни от proc_name,
// ни от proc_listallpids, ни от пути к бандлу — поэтому работает даже там,
// где обычный поиск по имени процесса ничего не находит.
static BOOL AscentFindGameByContent(int *outPid, task_t *outTask, uint64_t *outBase)
{
    if (outPid == NULL || outTask == NULL || outBase == NULL) {
        return NO;
    }

    AscentHostPsetPrivFn psetPrivFn = AscentHostPsetPriv();
    if (psetPrivFn == NULL) {
        AscentHUDLog(@"[game] перебор задач: host_processor_set_priv недоступен");
        return NO;
    }

    host_t host = mach_host_self();
    processor_set_t pset = MACH_PORT_NULL;
    processor_set_t psetPriv = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t taskCount = 0;

    if (processor_set_default(host, &pset) != KERN_SUCCESS ||
        psetPrivFn(host, pset, &psetPriv) != KERN_SUCCESS ||
        processor_set_tasks(psetPriv, &tasks, &taskCount) != KERN_SUCCESS ||
        tasks == NULL) {
        AscentHUDLog(@"[game] перебор задач: processor_set_tasks не отдал список");
        return NO;
    }

    int selfPid = (int)getpid();
    BOOL found = NO;
    for (mach_msg_type_number_t i = 0; i < taskCount; i++) {
        int pid = 0;
        if (pid_for_task(tasks[i], &pid) != KERN_SUCCESS || pid <= 0 || pid == selfPid) {
            continue;
        }
        uint64_t base = AscentImageBaseInTask(tasks[i], "UnityFramework");
        if (base != 0) {
            *outPid = pid;
            *outTask = tasks[i];
            *outBase = base;
            found = YES;
            break;
        }
    }

    AscentHUDLog(@"[game] перебор %u задач: игра %@",
                 (unsigned)taskCount, found ? @"найдена" : @"не найдена");

    // Освобождаем только память массива: порты, которые ядро уже отдало,
    // остаются нашими, поэтому найденный порт выше не теряется.
    vm_deallocate(mach_task_self(), (vm_address_t)tasks,
                  (vm_size_t)(taskCount * sizeof(task_t)));
    return found;
}

// Последняя дорога: прямой перебор pid от 1 до 1500. Каждому даём
// task-порт и смотрим, есть ли в задаче UnityFramework. Это нужно на случай,
// когда и список процессов (proc_*), и перебор задач ядра закрыты, а
// task_for_pid при этом работает — как раз то, на чём держится PastaWare.
static BOOL AscentFindGameByPidScan(int *outPid, task_t *outTask, uint64_t *outBase)
{
    if (outPid == NULL || outTask == NULL || outBase == NULL) {
        return NO;
    }

    int selfPid = (int)getpid();
    for (int pid = 1; pid <= 1500; pid++) {
        if (pid == selfPid) { continue; }
        task_t task = MACH_PORT_NULL;
        if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS || task == MACH_PORT_NULL) {
            continue;
        }
        uint64_t base = AscentImageBaseInTask(task, "UnityFramework");
        if (base != 0) {
            *outPid = pid;
            *outTask = task;
            *outBase = base;
            AscentHUDLog(@"[game] игра найдена перебором pid: %d", pid);
            return YES;
        }
        mach_port_deallocate(mach_task_self(), task);
    }

    AscentHUDLog(@"[game] перебор pid 1..1500: игра не найдена");
    return NO;
}

// База образа по имени (например, «UnityFramework»): идём по списку dyld
// (dyld_all_image_info → infoArray[i].{imageFilePath, imageLoadAddress}),
// сравниваем путь с нужным именем. Результат кэшируется — база образа
// не меняется пока игра жива.
uint64_t AscentGameImageBase(NSString *name)
{
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    if (name == nil) { return 0; }
    // Ключ кэша включает pid: после перезапуска игры адресное пространство
    // новое и база образа другая, а старый кэш вернул бы мёртвый адрес.
    NSString *cacheKey = [NSString stringWithFormat:@"%d:%@", gGamePid, name];
    @synchronized (cache) {
        NSNumber *hit = cache[cacheKey];
        if (hit != nil) { return (uint64_t)hit.unsignedLongLongValue; }
    }

    uint64_t result = 0;
    task_dyld_info_data_t dyldInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(gGameTask, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
    if (kr == KERN_SUCCESS && dyldInfo.all_image_info_addr != 0) {
        // Раскладку головы см. в AscentDyldImagesHead: infoArrayCount на +4,
        // infoArray на +8 (ровно как в рабочем PastaWare).
        AscentDyldImagesHead head;
        memset(&head, 0, sizeof(head));
        if (!AscentGameRead(dyldInfo.all_image_info_addr, &head, sizeof(head))) {
            AscentGameSetError(@"не прочитали голову dyld_all_image_infos");
            return 0;
        }
        uint32_t infoArrayCount = head.infoArrayCount;
        uint64_t infoArray = head.infoArray;
        if (infoArray == 0 || infoArrayCount == 0) {
            AscentGameSetErrorFormat(@"список образов dyld пуст (count=%u, array=0x%llx)",
                                     infoArrayCount, infoArray);
            return 0;
        }
        if (infoArrayCount < 4096) {
            // Массив образов читаем ОДНИМ куском, как PastaWare: у него на
            // это один vm_read_overwrite на count*24 байт, а не по два чтения
            // на каждый образ. Иначе при большом списке (в игре ~600-900
            // образов) мы делали бы больше тысячи syscall-ов на каждый поиск.
            size_t arrayBytes = (size_t)infoArrayCount * 24;
            AscentDyldImageInfo *images = (AscentDyldImageInfo *)malloc(arrayBytes);
            if (images != NULL) {
                if (AscentGameRead(infoArray, images, arrayBytes)) {
                    const char *needle = name.UTF8String;
                    for (uint32_t i = 0; i < infoArrayCount && result == 0; i++) {
                        uint64_t loadAddr = images[i].imageLoadAddress;
                        uint64_t filePathPtr = images[i].imageFilePath;
                        if (loadAddr == 0 || filePathPtr == 0) { continue; }

                        // Читаем C-строку пути кусками, пока не упрёмся в NUL.
                        char path[512];
                        memset(path, 0, sizeof(path));
                        int donePath = 0;
                        for (size_t off = 0; off < sizeof(path) - 1 && !donePath; off += 64) {
                            char chunk[64];
                            size_t want = sizeof(path) - 1 - off;
                            if (want > sizeof(chunk)) { want = sizeof(chunk); }
                            if (!AscentGameRead(filePathPtr + off, chunk, want)) { break; }
                            for (size_t k = 0; k < want; k++) {
                                path[off + k] = chunk[k];
                                if (chunk[k] == 0) { donePath = 1; break; }
                            }
                        }
                        path[sizeof(path) - 1] = 0;
                        if (needle != NULL && strstr(path, needle) != NULL) {
                            result = loadAddr;
                        }
                    }
                }
                free(images);
            }
        }
    }

    // Отрицательный результат НЕ кэшируем: игру могли ещё не дочитать, и тогда
    // залипший ноль навсегда лишил бы ESP образа UnityFramework до перезапуска
    // оверлея. Положительный результат кэшируем — база образа не меняется.
    if (result != 0) {
        @synchronized (cache) {
            cache[cacheKey] = @((unsigned long long)result);
        }
    }
    return result;
}

#pragma mark - Переключатели из общего файла

static double AscentSharedNumber(NSString *key)
{
    NSString *path = [AscentStateDirectory() stringByAppendingPathComponent:@"ascent.overlay.plist"];
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:path];
    id value = values[key];
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return [value doubleValue];
    }
    return 0.0;
}

void AscentGameTick(void)
{
    double esp = AscentSharedNumber(@"cheat.esp");
    double aimbot = AscentSharedNumber(@"cheat.aimbot");

    BOOL changed = (esp != gLastEsp) || (aimbot != gLastAimbot);
    BOOL anyOn = (esp > 0.5) || (aimbot > 0.5);
    BOOL attachedBefore = AscentGameIsAttached();

    if (changed) {
        gLastEsp = esp;
        gLastAimbot = aimbot;
        AscentHUDLog(@"[game] переключатели: esp=%d, aimbot=%d", esp > 0.5, aimbot > 0.5);

        if (anyOn && !attachedBefore) {
            AscentGameProbe(@"standoff");
        } else if (!anyOn && attachedBefore) {
            AscentGameDetach();
            AscentHUDLog(@"[game] все функции выключены — task-порт отпущен");
        }
    } else if (anyOn && !attachedBefore) {
        // Чит включён, а доступа нет — игра могла запуститься ПОСЛЕ тумблера.
        // Раньше привязка делалась ТОЛЬКО при смене переключателя, и если игру
        // запускали позже, ESP и диагностика не стартовали вообще. Повторяем
        // тихо раз в ~4.5 с (каждый 3-й тик); логируем только когда процесс
        // уже появился, чтобы не забивать журнал.
        static int sAttachRetry = 0;
        if ((++sAttachRetry % 3) == 0 && AscentGameFindProcess(@"standoff") > 0) {
            AscentGameProbe(@"standoff");
        }
    }

    BOOL attachedNow = AscentGameIsAttached();
    BOOL attachUp = (!attachedBefore && attachedNow);

    // ESP живёт своим потоком. Поднимаем его уже по одному тумблеру ESP
    // (даже без task-порта): тогда на вкладке Misc видно ПРИЧИНУ (нет
    // доступа / образ не найден), а не вечное «esp: —». Раньше цикл не
    // стартовал без attach, и диагностика в меню была пустой.
    AscentESPSetEnabled(esp > 0.5);

    if (esp > 0.5 && attachedNow && (changed || attachUp)) {
        // Прогон диагностики и при смене тумблера, и при ПЕРВОЙ успешной
        // привязке — иначе логи не появлялись, если игру запустили позже.
        // Сама диагностика уходит на фоновый поток с бюджетом (Il2CppDiag.mm).
        AscentESPRunProbe();
        AscentIl2CppDiagnose();
    }
}
