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
#import <sys/sysctl.h>

#import <mach/mach.h>
#import <mach/task.h>
#import <mach/task_info.h>
#import <mach/vm_map.h>
#import <mach-o/loader.h>

// Объявляем сами: в части SDK прототипа нет в публичных заголовках,
// а типы совпадают, поэтому повторное объявление безопасно.
extern "C" kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);

// libproc. На iOS заголовка <libproc.h> нет, но функции есть в libsystem.
// Именно ими пользуется рабочий PastaWare: proc_listallpids отдаёт список
// pid, proc_pidpath — ПОЛНЫЙ путь исполняемого файла процесса. Искать игру
// по одному имени (kp_proc.p_comm) нельзя: у Standoff 2 полный путь
// .../Standoff2.app/Standoff2, а p_comm может быть обрезан/пуст, и из
// HUD-процесса (плагин SpringBoard под root) sysctl(KERN_PROC_ALL) список
// процессов игры не показывает — доступ к памяти тогда «не получен» всегда.
extern "C" int proc_listallpids(void *buffer, int buffersize);
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

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
// Раскладка на arm64 (см. <mach-o/dyld_images.h>, struct dyld_all_image_infos):
//   +0x00 version        (u32)
//   +0x04 infoArrayCount (u32)
//   +0x08 ЗАЗОР          (4..7 байт — infoArray должен быть выровнен на 8)
//   +0x10 infoArray      (ptr)
// Зазор объявлен ЯВНО: если положиться на неявное выравнивание, смещение
// infoArray легко «уедет» и вместо массива образов прочитается мусор.
typedef struct {
    uint32_t version;
    uint32_t infoArrayCount;
    uint32_t _reserved;
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

    // Основной путь — тот же, что у рабочего PastaWare: перебор pid через
    // libproc и сверка ПОЛНОГО пути исполняемого файла. Так «Standoff2»
    // находится и из HUD-процесса, где sysctl(KERN_PROC_ALL) бесполезен.
    int found = -1;
    int count = proc_listallpids(NULL, 0);
    if (count > 0) {
        if (count > ASCENT_MAX_PIDS) { count = ASCENT_MAX_PIDS; }
        int *pids = (int *)malloc(sizeof(int) * (size_t)count);
        if (pids != NULL) {
            int filled = proc_listallpids(pids, (int)(sizeof(int) * (size_t)count));
            int got = filled > 0 ? (filled / (int)sizeof(int)) : 0;
            char path[4096];
            for (int i = 0; i < got; i++) {
                int pid = pids[i];
                if (pid <= 0) continue;
                memset(path, 0, sizeof(path));
                // proc_pidpath возвращает длину пути или <= 0 при отказе.
                if (proc_pidpath(pid, path, (uint32_t)sizeof(path)) <= 0) continue;
                if (AscentContainsInsensitive(path, hint)) {
                    found = pid;
                    break;
                }
            }
            free(pids);
        }
    }

    if (found > 0) {
        return found;
    }

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

    vm_size_t readBytes = 0;
    kern_return_t result = vm_read_overwrite(gGameTask,
                                            (vm_address_t)address,
                                            (vm_size_t)length,
                                            (vm_address_t)buffer,
                                            &readBytes);
    if (result != KERN_SUCCESS || readBytes != (vm_size_t)length) {
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
    gGameBase = AscentMainModuleBase(&gGameSize);
    gGameError = nil;

    if (gGameBase == 0 && gGameError == nil) {
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

#pragma mark - Образы (dyld)

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
    @synchronized (cache) {
        NSNumber *hit = cache[name];
        if (hit != nil) { return (uint64_t)hit.unsignedLongLongValue; }
    }

    uint64_t result = 0;
    task_dyld_info_data_t dyldInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(gGameTask, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
    if (kr == KERN_SUCCESS && dyldInfo.all_image_info_addr != 0) {
        // dyld_all_image_infos (arm64): +0x00 version (u32), +0x04 infoArrayCount (u32),
        // +0x08..0x0F выравнивающий зазор, +0x10 infoArray (ptr). Читаем структуру
        // целиком — так компилятор сам расставит выравнивание, и мы не завяжемся
        // на «магические» смещения (раньше здесь были +0x0/+0x8, из-за чего
        // вместо infoArray читался зазор, и образ UnityFramework не находился).
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
            const char *needle = name.UTF8String;
            for (uint32_t i = 0; i < infoArrayCount && result == 0; i++) {
                // dyld_image_info: +0x00 imageLoadAddress, +0x08 imageFilePath, +0x10 imageFileModDate
                uint64_t entry = infoArray + (uint64_t)i * 24;
                uint64_t loadAddr = 0;
                uint64_t filePathPtr = 0;
                if (!AscentGameRead(entry + 0x0, &loadAddr, sizeof(loadAddr))) { continue; }
                if (!AscentGameRead(entry + 0x8, &filePathPtr, sizeof(filePathPtr))) { continue; }
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
    }

    // Отрицательный результат НЕ кэшируем: игру могли ещё не дочитать, и тогда
    // залипший ноль навсегда лишил бы ESP образа UnityFramework до перезапуска
    // оверлея. Положительный результат кэшируем — база образа не меняется.
    if (result != 0) {
        @synchronized (cache) {
            cache[name] = @((unsigned long long)result);
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
