//
//  Il2CppDiag.mm
//  Ascent
//
//  См. Il2CppDiag.h. Мы внешние: читаем чужую память, но НЕ можем «вызывать»
//  il2cpp-функции в процессе игры. Единственный путь к игрокам — обходить
//  структуры il2cpp чтением. Чтобы построить обход, нужна раскладка памяти
//  конкретной сборки: где замаплены метаданные (global-metadata.dat) и какая
//  у них версия. Это то, что собирает этот модуль. Ничего в чужую память не пишет.
//
//  Итог пишем в журнал (ascent.hud.log) — по нему проектируем Il2Cpp.mm.
//

#import "Il2CppDiag.h"
#import "GameMemory.h"
#import "HUDHelper.h"

#import <mach/mach.h>
#import <string.h>

// Магия il2cpp global-metadata.dat: 0xFAB11BAF (little-endian в памяти).
static const unsigned char kIl2CppMetaMagic[4] = {0xAF, 0x1B, 0xB1, 0xFA};

// Лимиты, чтобы диагностика гарантированно не зависла надолго.
static const uint64_t kMaxTotalScan = 1536ULL * 1024 * 1024; // всего не больше 1.5 ГБ
static const uint64_t kMaxRegionScan = 96ULL * 1024 * 1024;  // и не больше 96 МБ на регион
static const size_t   kChunk = 1024 * 1024;                  // читаем по 1 МБ

// Поиск 4-байтовой магии внутри буфера. Возвращает смещение или -1.
// Никаких внешних функций — чтобы не зависеть от _GNU_SOURCE/memmem.
static long AscentFindMagic(const unsigned char *buf, size_t len)
{
    if (len < 4) return -1;
    for (size_t i = 0; i + 4 <= len; i++) {
        if (buf[i]   == kIl2CppMetaMagic[0] &&
            buf[i+1] == kIl2CppMetaMagic[1] &&
            buf[i+2] == kIl2CppMetaMagic[2] &&
            buf[i+3] == kIl2CppMetaMagic[3]) {
            return (long)i;
        }
    }
    return -1;
}

// Сканировать регион [start, start+size) на предмет магии. При находке пишет
// журнал (шапку метаданных) и возвращает YES. Уже прочитанное считаем в
// *ioScanned (общий бюджет), чтобы остановиться по kMaxTotalScan.
static BOOL AscentScanRegionForMagic(uint64_t start, uint64_t size,
                                     uint64_t *ioScanned,
                                     uint64_t fileOffset, int prot)
{
    unsigned char *buf = (unsigned char *)malloc(kChunk + 8);
    if (buf == NULL) return NO;

    uint64_t addr = start;
    uint64_t end  = start + size;
    uint64_t regionScanned = 0;
    BOOL found = NO;

    while (addr < end && regionScanned < kMaxRegionScan &&
           *ioScanned < kMaxTotalScan) {
        uint64_t remaining = end - addr;
        size_t toRead = (remaining > (uint64_t)kChunk) ? kChunk : (size_t)remaining;

        if (!AscentGameRead(addr, buf, toRead)) {
            // Регион заявлен читаемым, но страница не отдаётся (guard/списана).
            // Перескакиваем его, чтобы не зациклиться.
            addr += toRead;
            regionScanned += toRead;
            *ioScanned += toRead;
            continue;
        }

        long off = AscentFindMagic(buf, toRead);
        if (off >= 0) {
            uint64_t magicAddr = addr + (uint64_t)off;
            // Проверяем, что это правда шапка: версия на +4 должна быть
            // разумной (1..40). Иначе это ложное совпадение — ищем дальше.
            int32_t version = 0;
            if (AscentGameRead(magicAddr + 4, &version, sizeof(version)) &&
                version >= 1 && version <= 40) {

                AscentHUDLog(@"[il2cpp] МЕТАДАННЫЕ найдены @ 0x%llx (регион 0x%llx, смещ. файла 0x%llx, prot=%x)",
                             magicAddr, start, fileOffset, prot);
                AscentHUDLog(@"[il2cpp] версия метаданных: %d", version);

                // Печатаем шапку: первые 40 int32 (160 байт). Интерпретируем
                // офлайн — раскладка зависит от версии, нам важны сырые значения.
                int32_t hdr[40];
                memset(hdr, 0, sizeof(hdr));
                if (AscentGameRead(magicAddr, hdr, sizeof(hdr))) {
                    NSMutableString *row = [NSMutableString string];
                    for (int i = 0; i < 40; i++) {
                        [row appendFormat:@"%d ", hdr[i]];
                        if ((i % 8) == 7) {
                            AscentHUDLog(@"[il2cpp]   шапка[%02d]: %@", i - 7, row);
                            row = [NSMutableString string];
                        }
                    }
                    if (row.length) {
                        AscentHUDLog(@"[il2cpp]   шапка[32]: %@", row);
                    }
                }
                found = YES;
                break;
            }
            // Ложное сдвигаемся на 4 и продолжаем.
            addr += (uint64_t)off + 4;
            regionScanned += (uint64_t)off + 4;
            *ioScanned += (uint64_t)off + 4;
            continue;
        }

        // Магии нет. Сдвигаемся с перекрытием в 3 байта, чтобы 4-байтовая
        // магия, «переехавшая» на границу чанков, не потерялась.
        size_t adv = (toRead > 3) ? (toRead - 3) : toRead;
        if (adv == 0) break;
        addr += adv;
        regionScanned += adv;
        *ioScanned += adv;
    }

    free(buf);
    return found;
}

void AscentIl2CppDiagnose(void)
{
    if (!AscentGameIsAttached()) {
        AscentHUDLog(@"[il2cpp] диагностика: нет task-порта — пропуск");
        return;
    }
    mach_port_t task = AscentGameTask();
    if (task == MACH_PORT_NULL) {
        AscentHUDLog(@"[il2cpp] диагностика: task-порт пуст — пропуск");
        return;
    }

    @autoreleasepool {
        uint64_t base = AscentGameModuleBase();
        uint64_t size = AscentGameModuleSize();
        AscentHUDLog(@"[il2cpp] === старт диагностики: pid=%d, модуль=0x%llx (+0x%llx) ===",
                     AscentGamePid(), base, size);

        // Перебираем регионы адресного пространства.
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objName = MACH_PORT_NULL;

        vm_address_t addr = 0;
        vm_size_t    regionSize = 0;

        int regionCount = 0, readableCount = 0;
        uint64_t readableBytes = 0;
        uint64_t scanned = 0;
        BOOL found = NO;
        int logged = 0;

        for (;;) {
            // Сбрасываем входные параметры MIG-вызова на каждой итерации:
            // count — «сколько элементов info влезло», objName — выходной порт.
            count = VM_REGION_BASIC_INFO_COUNT_64;
            objName = MACH_PORT_NULL;
            kern_return_t kr = vm_region_64(task, &addr, &regionSize,
                                            VM_REGION_BASIC_INFO_64,
                                            (vm_region_info_t)&info,
                                            &count, &objName);
            if (kr != KERN_SUCCESS) {
                break; // регионы кончились
            }

            if (objName != MACH_PORT_NULL) {
                mach_port_deallocate(mach_task_self(), objName);
                objName = MACH_PORT_NULL;
            }

            uint64_t rStart = (uint64_t)addr;
            uint64_t rSize  = (uint64_t)regionSize;
            regionCount++;

            BOOL readable = (info.protection & VM_PROT_READ) != 0;
            if (readable) {
                readableCount++;
                readableBytes += rSize;
            }

            // Первые 18 регионов печатаем, чтобы понять раскладку (где код,
            // стек, куча, файловые маппинги — рядом обычно и метаданные).
            if (logged < 18) {
                AscentHUDLog(@"[il2cpp]   регион #%d: 0x%llx +0x%llx prot=%x off=0x%llx%s",
                             regionCount, rStart, rSize,
                             info.protection, (uint64_t)info.offset,
                             readable ? "" : " (не читается)");
                logged++;
            }

            // Ищем метаданные только в читаемых регионах.
            if (readable && !found) {
                if (AscentScanRegionForMagic(rStart, rSize, &scanned,
                                             (uint64_t)info.offset,
                                             info.protection)) {
                    found = YES;
                }
            }

            // Следующий регион: vm_region_64 вернул начало найденного,
            // поэтому двигаемся в конец текущего.
            addr = (vm_address_t)(rStart + rSize);

            // Выходим, когда метаданные уже есть или упёрлись в бюджет чтения.
            if (found || scanned >= kMaxTotalScan) {
                break;
            }
        }

        AscentHUDLog(@"[il2cpp] === итог: регионов=%d, читаемых=%d (0x%llx байт), прочитано=0x%llx ===",
                     regionCount, readableCount, readableBytes, scanned);
        if (found) {
            AscentHUDLog(@"[il2cpp] метаданные НАЙДЕНЫ — есть фундамент для резолвера");
        } else if (scanned >= kMaxTotalScan) {
            AscentHUDLog(@"[il2cpp] бюджет чтения исчерпан, метаданные не найдены");
        } else {
            AscentHUDLog(@"[il2cpp] магия 0xFAB11BAF не найдена — возможно, в другой области или сжата");
        }
    }
}
