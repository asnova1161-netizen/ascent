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
//  Требования по производительности (жалобы «греется телефон, проседает FPS»):
//    • весь прогон идёт НА ФОНОВОМ ПОТОКЕ с приоритетом BACKGROUND — главный
//      поток HUD не блокируется, а диагностика уступает игре;
//    • жёсткие бюджеты: 3 секунды / 512 МБ / не больше 12 попыток за сессию;
//    • между чтениями usleep — мы не забираем всю полосу памяти у игры;
//    • защита от нулевых регионов и лимит числа регионов — никаких вечных
//      циклов даже на странной раскладке памяти.
//
//  Итог пишем в журнал (ascent.hud.log) и статусом в меню — по нему проектируем
//  резолвер.
//

#import "Il2CppDiag.h"
#import "GameMemory.h"
#import "HUDHelper.h"

#import <mach/mach.h>
#import <string.h>
#import <unistd.h>

// Магия il2cpp global-metadata.dat: 0xFAB11BAF (little-endian в памяти).
static const unsigned char kIl2CppMetaMagic[4] = {0xAF, 0x1B, 0xB1, 0xFA};

// Бюджеты одного прогона.
static const double   kTimeBudget    = 3.0;               // секунд на прогон
static const uint64_t kMaxTotalScan  = 512ULL << 20;      // 512 МБ прочитать
static const uint64_t kMaxRegionScan = 64ULL << 20;       // 64 МБ на регион
static const size_t   kChunk          = 512 * 1024;       // 512 КБ на чтение
static const int      kMaxAttempts    = 12;               // попыток за сессию
static const int      kMaxRegions     = 200000;           // лимит регионов

// Состояние (вызывается только с главного потока HUD — гонок нет).
static BOOL gDiagRunning = NO;
static BOOL gDiagFound   = NO;
static int  gDiagAttempts = 0;

static double DiagNow(void)
{
    return [NSProcessInfo processInfo].systemUptime;
}

// Поиск 4-байтовой магии внутри буфера. Возвращает смещение или -1.
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
// в журнал шапку метаданных и возвращает YES. Учтённое чтение копится в
// *ioScanned, остановка — по бюджетам (байты, время).
static BOOL AscentScanRegionForMagic(uint64_t start, uint64_t size,
                                     uint64_t *ioScanned, double deadline,
                                     uint64_t fileOffset, int prot)
{
    unsigned char *buf = (unsigned char *)malloc(kChunk + 8);
    if (buf == NULL) return NO;

    uint64_t addr = start;
    uint64_t end  = start + size;
    uint64_t regionScanned = 0;
    BOOL found = NO;

    while (addr < end && regionScanned < kMaxRegionScan &&
           *ioScanned < kMaxTotalScan && DiagNow() < deadline) {

        // Микро-паузу ставим ПЕРЕД чтением: и упёрлись в бюджет времени —
        // вышли. Плюс так игра не теряет полосу памяти во время скана.
        usleep(150);

        uint64_t remaining = end - addr;
        size_t toRead = (remaining > (uint64_t)kChunk) ? kChunk : (size_t)remaining;

        if (!AscentGameRead(addr, buf, toRead)) {
            // Страница заявленной читаемой области не отдаётся (guard/списана).
            // Перескакиваем чанк, чтобы не зациклиться на неудачах.
            addr += toRead;
            regionScanned += toRead;
            *ioScanned += toRead;
            continue;
        }

        long off = AscentFindMagic(buf, toRead);
        if (off >= 0) {
            uint64_t magicAddr = addr + (uint64_t)off;
            // Проверяем, что это правда шапка: версия на +4 должна быть
            // разумной (1..40). Иначе ложное совпадение — ищем дальше.
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
            // Ложное совпадение — сдвигаемся на 4 и продолжаем.
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
    // Один прогон за раз, не больше kMaxAttempts за сессию, после находки —
    // вообще не трогаемся. Все проверки — на вызывающем (главном) потоке.
    if (gDiagFound || gDiagRunning || gDiagAttempts >= kMaxAttempts) {
        return;
    }
    if (!AscentGameIsAttached() || AscentGameTask() == MACH_PORT_NULL) {
        return;
    }

    gDiagAttempts++;
    gDiagRunning = YES;
    const int attempt = gDiagAttempts;

    // Фон с приоритетом BACKGROUND: диагностика уступает игре и не греет
    // телефон большими синхронными копиями памяти.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        @autoreleasepool {
            const double t0 = DiagNow();
            const double deadline = t0 + kTimeBudget;
            uint64_t base = AscentGameModuleBase();
            AscentHUDLog(@"[il2cpp] попытка %d/%d: модуль=0x%llx, бюджет %.0f с / 512 МБ",
                         attempt, kMaxAttempts, base, kTimeBudget);

            vm_region_basic_info_data_64_t info;
            mach_msg_type_number_t count;
            mach_port_t objName;

            vm_address_t addr = 0;
            vm_size_t    regionSize = 0;

            int regionCount = 0, readableCount = 0, logged = 0;
            uint64_t readableBytes = 0, scanned = 0;
            BOOL found = NO;

            while (regionCount < kMaxRegions && DiagNow() < deadline &&
                   scanned < kMaxTotalScan) {
                // Входные параметры MIG-вызова сбрасываем на каждой итерации.
                count = VM_REGION_BASIC_INFO_COUNT_64;
                objName = MACH_PORT_NULL;
                kern_return_t kr = vm_region_64(AscentGameTask(), &addr, &regionSize,
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

                if (rSize == 0) {
                    // Нулевой регион не должен крутить цикл вечно: сдвигаемся
                    // на страницу и идём дальше.
                    addr = (vm_address_t)(rStart + 0x1000);
                    continue;
                }

                BOOL readable = (info.protection & VM_PROT_READ) != 0;
                if (readable) {
                    readableCount++;
                    readableBytes += rSize;
                }

                // Первые 12 регионов печатаем — по ним видна раскладка памяти.
                if (logged < 12) {
                    AscentHUDLog(@"[il2cpp]   регион #%d: 0x%llx +0x%llx prot=%x off=0x%llx%s",
                                 regionCount, rStart, rSize,
                                 info.protection, (uint64_t)info.offset,
                                 readable ? "" : " (не читается)");
                    logged++;
                }

                if (readable && !found) {
                    if (AscentScanRegionForMagic(rStart, rSize, &scanned, deadline,
                                                 (uint64_t)info.offset,
                                                 info.protection)) {
                        found = YES;
                    }
                }

                addr = (vm_address_t)(rStart + rSize);
            }

            const double elapsed = DiagNow() - t0;
            AscentHUDLog(@"[il2cpp] итог попытки %d: регионов=%d, читаемых=%d (%.1f МБ), "
                         @"прочитано=%.1f МБ, %.1f с, найдено=%d",
                         attempt, regionCount, readableCount,
                         (double)readableBytes / 1048576.0,
                         (double)scanned / 1048576.0, elapsed, found);

            if (found) {
                gDiagFound = YES;
                AscentHUDLog(@"[il2cpp] метаданные НАЙДЕНЫ — фундамент для резолвера есть");
            } else if (scanned >= kMaxTotalScan || elapsed >= kTimeBudget) {
                AscentHUDLog(@"[il2cpp] бюджет исчерпан, метаданные не найдены (следующая попытка будет позже)");
            } else {
                AscentHUDLog(@"[il2cpp] магия 0xFAB11BAF не найдена (следующая попытка будет позже)");
            }

            gDiagRunning = NO;
        }
    });
}
