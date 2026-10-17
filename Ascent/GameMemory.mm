//
//  GameMemory.mm
//  Ascent
//
//  Реализация доступа к памяти чужого процесса. См. GameMemory.h.
//

#import "GameMemory.h"
#import "HUDHelper.h"

#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/vm_region.h>
#import <mach-o/loader.h>

// Объявляем сами: в некоторых SDK прототипа нет в публичных заголовках,
// а типы совпадают, поэтому повторное объявление безопасно.
extern "C" kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);

// В части SDK константы нет: просим ядро сделать приватную копию страницы.
#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10
#endif

static task_t   gGameTask = MACH_PORT_NULL;
static int      gGamePid = 0;
static uint64_t gGameBase = 0;
static uint64_t gGameSize = 0;
static NSString *gGameError = nil;

// Последние прочитанные переключатели: чтобы писать в журнал только изменения.
static double gLastEsp = -1.0;
static double gLastAimbot = -1.0;
static double gLastTrigger = -1.0;

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

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t length = 0;
    if (sysctl(mib, 4, NULL, &length, NULL, 0) != 0 || length == 0) {
        AscentGameSetErrorFormat(@"список процессов не получен (errno=%d)", errno);
        return -1;
    }

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
    if (procs == NULL) {
        AscentGameSetError(@"нет памяти под список процессов");
        return -1;
    }

    if (sysctl(mib, 4, procs, &length, NULL, 0) != 0) {
        AscentGameSetErrorFormat(@"список процессов не прочитан (errno=%d)", errno);
        free(procs);
        return -1;
    }

    size_t count = length / sizeof(struct kinfo_proc);
    const char *hint = nameHint.UTF8String;
    int found = -1;

    for (size_t i = 0; i < count; i++) {
        const char *name = procs[i].kp_proc.p_comm;
        if (name[0] == '\0') continue;
        if (AscentContainsInsensitive(name, hint)) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }

    free(procs);

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
    vm_size_t pageSize = 0;
    if (host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS && pageSize > 0) {
        mach_vm_address_t pageStart = (mach_vm_address_t)(address & ~((uint64_t)pageSize - 1));
        mach_vm_size_t pageLength = (mach_vm_size_t)(length + (address - pageStart) + pageSize - 1);
        kern_return_t protect = mach_vm_protect(gGameTask, pageStart, pageLength, FALSE,
                                               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (protect != KERN_SUCCESS) {
            AscentHUDLog(@"[game] !!! снять защиту страницы 0x%llx не вышло: 0x%x", (uint64_t)pageStart, protect);
        }
    }

    kern_return_t result = mach_vm_write(gGameTask,
                                        (mach_vm_address_t)address,
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

static uint64_t AscentFindMainModule(uint64_t *outSize)
{
    mach_vm_address_t address = 0;

    for (int step = 0; step < 400000; step++) {
        mach_vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;

        kern_return_t result = mach_vm_region(gGameTask, &address, &regionSize,
                                              VM_REGION_BASIC_INFO_64,
                                              (vm_region_info_t)&info, &infoCount,
                                              &objectName);
        if (objectName != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), objectName);
        }
        if (result != KERN_SUCCESS || regionSize == 0) {
            break;
        }

        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_EXECUTE)) {
            uint32_t magic = 0;
            mach_vm_size_t readBytes = 0;
            kern_return_t readResult = mach_vm_read_overwrite(gGameTask, address,
                                                              sizeof(magic),
                                                              (mach_vm_address_t)&magic,
                                                              &readBytes);
            if (readResult == KERN_SUCCESS && readBytes == sizeof(magic) &&
                (magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
                 magic == MH_MAGIC || magic == MH_CIGAM)) {
                if (outSize != NULL) {
                    *outSize = AscentHeaderTextSize((uint64_t)address);
                }
                return (uint64_t)address;
            }
        }

        address += regionSize;
    }

    return 0;
}

#pragma mark - Подключение/отключение

BOOL AscentGameIsAttached(void)
{
    return gGameTask != MACH_PORT_NULL;
}

int AscentGamePid(void)        { return gGamePid; }
uint64_t AscentGameModuleBase(void) { return gGameBase; }
uint64_t AscentGameModuleSize(void) { return gGameSize; }

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

BOOL AscentGameAttach(NSString *nameHint)
{
    AscentGameDetach();

    int pid = AscentGameFindProcess(nameHint);
    if (pid <= 0) {
        return NO;
    }

    task_t task = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), pid, &task);
    if (result != KERN_SUCCESS || task == MACH_PORT_NULL) {
        AscentGameSetErrorFormat(@"task_for_pid(%d) вернул 0x%x — права не дали task-порт", pid, result);
        return NO;
    }

    gGamePid = pid;
    gGameTask = task;
    gGameBase = AscentFindMainModule(&gGameSize);
    gGameError = nil;

    if (gGameBase == 0) {
        AscentGameSetError(@"task-порт есть, но главный модуль не найден");
    }
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
    return [NSString stringWithFormat:@"pid %d, модуль 0x%llx (%.1f МБ)",
            gGamePid, gGameBase, (double)gGameSize / 1048576.0];
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
    if (pid <= 0) {
        AscentHUDLog(@"[game] процесс «%@»: %@", nameHint, gGameError ?: @"не найден");
        return;
    }

    AscentHUDLog(@"[game] процесс «%@» найден: pid=%d, беру task-порт", nameHint, pid);
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
    double trigger = AscentSharedNumber(@"cheat.trigger");

    if (esp == gLastEsp && aimbot == gLastAimbot && trigger == gLastTrigger) {
        return;
    }

    gLastEsp = esp;
    gLastAimbot = aimbot;
    gLastTrigger = trigger;

    BOOL anyOn = (esp > 0.5) || (aimbot > 0.5) || (trigger > 0.5);
    AscentHUDLog(@"[game] переключатели: esp=%d, aimbot=%d, triggerbot=%d",
                 esp > 0.5, aimbot > 0.5, trigger > 0.5);

    if (anyOn && !AscentGameIsAttached()) {
        // Пока это только доступ к памяти: самих смещений игры здесь ещё нет,
        // поэтому рисовать/целиться нечем — но видно, что доступ есть.
        AscentGameProbe(@"standoff");
    } else if (!anyOn && AscentGameIsAttached()) {
        AscentGameDetach();
        AscentHUDLog(@"[game] все функции выключены — task-порт отпущен");
    }
}
