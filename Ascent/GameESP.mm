//
//  GameESP.mm
//  Ascent
//
//  Фоновое чтение памяти Standoff 2 для ESP. Работает на своём потоке: таск-
//  порт у игры берёт AscentGameTick (он же отпускает, когда читы выключили),
//  а здесь мы раз в кадр читаем список игроков, проецируем их на экран и
//  кладём снимок в общую память, откуда его забирает оверлей.
//
//  Смещения IL2CPP читаем из общего plist — см. GameESP.h. Никаких вшитых в
//  бинарник чисел здесь нет: обновление игры ломает только конфиг, а не код.
//

#import "GameESP.h"
#import "GameMemory.h"
#import "HUDHelper.h"

#import <os/lock.h>
#import <math.h>
#import <string.h>

#pragma mark - Конфигурация

// Все смещения — целые числа из общего plist. Значения по умолчанию нулевые:
// без них ESP честно пишет «смещения не заданы» и ничего не выдумывает.
typedef struct {
    BOOL     on;             ///< cheat.esp
    uint64_t offList;        ///< смещение от базы модуля → указатель на список игроков
    uint32_t offListArray;   ///< смещение поля T[] внутри List<T>; 0 — offList уже массив
    uint64_t offMatrix;      ///< смещение →4x4 матрица вида/проекции (16 float)
    uint32_t offPos;         ///< поле Vector3 позиции в объекте игрока
    uint32_t offHealth;      ///< поле здоровья (float)
    uint32_t offTeam;        ///< поле команды (int32)
    uint32_t offName;        ///< поле имени (Il2CppString*)
    uint32_t offLocal;       ///< смещение локального игрока (для расстояния)
    float    boxScale;       ///< множитель высоты бокса
    uint32_t refreshMs;      ///< как часто перечитывать конфиг, мс
} AscentESPConfig;

static AscentESPConfig gConfig;
static NSTimeInterval gConfigTime = 0;

/// Число из общего plist оверлея. Отсутствующий ключ — 0.0.
static double AscentESPNumber(NSString *key)
{
    NSString *path = [AscentStateDirectory() stringByAppendingPathComponent:@"ascent.overlay.plist"];
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:path];
    id value = values[key];
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return [value doubleValue];
    }
    return 0.0;
}

static void AscentESPConfigLoad(void)
{
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (gConfigTime != 0 && (now - gConfigTime) * 1000.0 < gConfig.refreshMs) {
        return;
    }
    gConfigTime = now;

    gConfig.on              = AscentESPNumber(@"cheat.esp") > 0.5;
    gConfig.offList         = (uint64_t)AscentESPNumber(@"esp.off.list");
    gConfig.offListArray    = (uint32_t)AscentESPNumber(@"esp.off.listArray");
    gConfig.offMatrix       = (uint64_t)AscentESPNumber(@"esp.off.matrix");
    gConfig.offPos          = (uint32_t)AscentESPNumber(@"esp.off.pos");
    gConfig.offHealth       = (uint32_t)AscentESPNumber(@"esp.off.health");
    gConfig.offTeam         = (uint32_t)AscentESPNumber(@"esp.off.team");
    gConfig.offName         = (uint32_t)AscentESPNumber(@"esp.off.name");
    gConfig.offLocal        = (uint32_t)AscentESPNumber(@"esp.off.local");
    gConfig.boxScale        = (float)AscentESPNumber(@"esp.scale");
    gConfig.refreshMs       = (uint32_t)AscentESPNumber(@"esp.refreshMs");

    // Стандартный сдвиг поля _items у System.Collections.Generic.List<T>.
    if (gConfig.offListArray == 0) { gConfig.offListArray = 0x10; }
    if (gConfig.refreshMs < 100) { gConfig.refreshMs = 100; }
    if (gConfig.boxScale <= 0.1f || gConfig.boxScale > 5.0f) { gConfig.boxScale = 1.0f; }
}

#pragma mark - Снимок кадра

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static AscentESPPlayer gPlayers[kAscentESPMaxPlayers];
static AscentESPFrame  gFrame;
static BOOL            gEnabled = NO;

int AscentESPGetFrame(AscentESPPlayer *outPlayers, int capacity, AscentESPFrame *outInfo)
{
    os_unfair_lock_lock(&gLock);

    int count = gFrame.count;
    if (outInfo != NULL) { *outInfo = gFrame; }

    if (outPlayers != NULL && capacity > 0 && count > 0) {
        int copy = count < capacity ? count : capacity;
        memcpy(outPlayers, gPlayers, sizeof(AscentESPPlayer) * (size_t)copy);
        count = copy;
    }

    os_unfair_lock_unlock(&gLock);
    return outPlayers == NULL || capacity <= 0 ? 0 : count;
}

/// Публикует новый кадр: копирует игроков, увеличивает номер кадра и пишет
/// короткий статус (его видно в «Misc», чтобы понимать, почему боксы не рисуются).
static void AscentESPPublish(const AscentESPPlayer *players, int count,
                             BOOL live, NSString *status)
{
    const char *text = (status != nil && status.UTF8String != NULL) ? status.UTF8String : "";

    os_unfair_lock_lock(&gLock);
    int copy = count;
    if (copy < 0) { copy = 0; }
    if (copy > kAscentESPMaxPlayers) { copy = kAscentESPMaxPlayers; }
    if (copy > 0 && players != NULL) {
        memcpy(gPlayers, players, sizeof(AscentESPPlayer) * (size_t)copy);
    }
    gFrame.count = copy;
    gFrame.frameId += 1;
    gFrame.live = live;
    gFrame.pid = AscentGamePid();
    strncpy(gFrame.status, text, sizeof(gFrame.status) - 1);
    gFrame.status[sizeof(gFrame.status) - 1] = '\0';
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Проекция

// Мир→экран по матрице вида/проекции Unity (column-major: элемент (row r,
// col c) лежит в m[c*4 + r]). Результат нормализован: 0..1 по обеим осям, так
// что разрешение игры не нужно, а поворот экрана рисовальщик делает сам.
static BOOL AscentESPProject(const float m[16], float wx, float wy, float wz,
                             CGPoint *outScreen)
{
    float cx = m[0] * wx + m[4] * wy + m[8]  * wz + m[12];
    float cy = m[1] * wx + m[5] * wy + m[9]  * wz + m[13];
    float cw = m[3] * wx + m[7] * wy + m[11] * wz + m[15];

    if (!isfinite(cw) || fabsf(cw) < 1e-4f) { return NO; }

    float nx = cx / cw;
    float ny = cy / cw;
    if (!isfinite(nx) || !isfinite(ny)) { return NO; }

    outScreen->x = nx * 0.5f + 0.5f;
    outScreen->y = 1.0f - (ny * 0.5f + 0.5f);
    return YES;
}

#pragma mark - Чтение IL2CPP

// Il2CppArray: объект (16 байт) + max_length (8) + элементы.
static const uint32_t kIl2CppArrayItems = 24;

// Il2CppString: объект (16) + length (int32) + UTF-16 символы.
static const uint32_t kIl2CppStringLength = 16;
static const uint32_t kIl2CppStringChars  = 20;

// Указатель на кучу iOS: верхние байты нулевые. Мусор отсекаем сразу, чтобы
// не дёргать vm_read_overwrite на заведомо мёртвых адресах.
static BOOL AscentESPLooksLikePointer(uint64_t value)
{
    return value != 0 && (value >> 48) == 0;
}

static BOOL AscentESPReadName(uint64_t address, char *out, size_t outSize)
{
    if (address == 0 || outSize == 0) { return NO; }

    uint32_t length = 0;
    if (!AscentGameRead(address + kIl2CppStringLength, &length, sizeof(length))) { return NO; }
    if (length == 0 || length > 24) { return NO; }

    uint16_t chars[24];
    memset(chars, 0, sizeof(chars));
    if (!AscentGameRead(address + kIl2CppStringChars, chars,
                        (size_t)length * sizeof(uint16_t))) {
        return NO;
    }

    size_t written = 0;
    for (uint32_t i = 0; i < length && written + 1 < outSize; i++) {
        uint16_t ch = chars[i];
        out[written++] = (ch >= 32 && ch < 127) ? (char)ch : '?';
    }
    out[written] = '\0';
    return written > 0;
}

#pragma mark - Один проход по игре

static void AscentESPTickOnce(void)
{
    if (!AscentGameIsAttached()) {
        AscentESPPublish(NULL, 0, NO, @"нет доступа к процессу игры");
        return;
    }
    if (gConfig.offList == 0 || gConfig.offPos == 0 || gConfig.offMatrix == 0) {
        AscentESPPublish(NULL, 0, NO, @"смещения не заданы (esp.off.*)");
        return;
    }

    uint64_t base = AscentGameModuleBase();
    if (base == 0) {
        AscentESPPublish(NULL, 0, NO, @"база модуля игры неизвестна");
        return;
    }

    // Указатель на список игроков лежит по смещению от базы модуля.
    uint64_t list = 0;
    if (!AscentGameRead(base + gConfig.offList, &list, sizeof(list)) ||
        !AscentESPLooksLikePointer(list)) {
        AscentESPPublish(NULL, 0, YES, @"список игроков пуст (матч не начался?)");
        return;
    }

    // List<T> хранит массив элементов отдельным объектом; если поле не задано —
    // считаем, что по смещению уже указатель на Il2CppArray.
    uint64_t array = list;
    if (gConfig.offListArray != 0) {
        if (!AscentGameRead(list + gConfig.offListArray, &array, sizeof(array)) ||
            !AscentESPLooksLikePointer(array)) {
            AscentESPPublish(NULL, 0, YES, @"массив игроков не найден");
            return;
        }
    }

    uint64_t maxCount = 0;
    if (!AscentGameRead(array + 16, &maxCount, sizeof(maxCount))) {
        AscentESPPublish(NULL, 0, YES, @"размер списка не прочитан");
        return;
    }
    if (maxCount > kAscentESPMaxPlayers) { maxCount = kAscentESPMaxPlayers; }
    if (maxCount == 0) {
        AscentESPPublish(NULL, 0, YES, @"в списке никого");
        return;
    }

    // Указатели на игроков читаем одним куском — так дешевле, чем по одному.
    uint64_t pointers[kAscentESPMaxPlayers];
    memset(pointers, 0, sizeof(pointers));
    if (!AscentGameRead(array + kIl2CppArrayItems, pointers,
                        sizeof(uint64_t) * (size_t)maxCount)) {
        AscentESPPublish(NULL, 0, YES, @"указатели игроков не прочитаны");
        return;
    }

    // Матрицу вида/проекции читаем один раз на кадр.
    float matrix[16];
    memset(matrix, 0, sizeof(matrix));
    if (!AscentGameRead(base + gConfig.offMatrix, matrix, sizeof(matrix))) {
        AscentESPPublish(NULL, 0, YES, @"матрица камеры не прочитана");
        return;
    }
    // У живой проекции нулевых чисел почти нет: пустая матрица означает, что
    // смещение указывает не туда, и рисовать по ней нечего.
    if (!isfinite(matrix[0]) || !isfinite(matrix[5]) || !isfinite(matrix[10]) ||
        (matrix[0] == 0.0f && matrix[5] == 0.0f && matrix[10] == 0.0f)) {
        AscentESPPublish(NULL, 0, YES, @"матрица камеры выглядит мусором");
        return;
    }

    // Позиция локального игрока — чтобы считать расстояние до остальных.
    BOOL haveLocal = NO;
    float localPos[3] = { 0, 0, 0 };
    if (gConfig.offLocal != 0) {
        uint64_t local = 0;
        if (AscentGameRead(base + gConfig.offLocal, &local, sizeof(local)) &&
            AscentESPLooksLikePointer(local)) {
            haveLocal = AscentGameRead(local + gConfig.offPos, localPos, sizeof(localPos));
        }
    }

    AscentESPPlayer players[kAscentESPMaxPlayers];
    memset(players, 0, sizeof(players));
    int count = 0;

    // Один блок на объект: позиция/здоровье/команда обычно лежат рядом, и одно
    // чтение вместо трёх заметно дешевле.
    uint8_t block[256];
    const size_t blockSize = sizeof(block);

    for (uint64_t i = 0; i < maxCount && count < kAscentESPMaxPlayers; i++) {
        uint64_t object = pointers[i];
        if (!AscentESPLooksLikePointer(object)) { continue; }

        memset(block, 0, blockSize);
        if (!AscentGameRead(object, block, blockSize)) { continue; }

        AscentESPPlayer *player = &players[count];
        player->health = -1.0f;
        player->team = -1;
        player->distance = -1;
        player->screen = CGPointMake(-1.0f, -1.0f);
        player->boxHeight = 0.12f;

        if (gConfig.offPos + sizeof(float) * 3 <= blockSize) {
            const float *pos = (const float *)(block + gConfig.offPos);
            if (!isfinite(pos[0]) || !isfinite(pos[1]) || !isfinite(pos[2])) { continue; }
            if (!AscentESPProject(matrix, pos[0], pos[1], pos[2], &player->screen)) {
                continue;
            }

            if (haveLocal) {
                float dx = pos[0] - localPos[0];
                float dy = pos[1] - localPos[1];
                float dz = pos[2] - localPos[2];
                player->distance = (int)(sqrtf(dx * dx + dy * dy + dz * dz) + 0.5f);
            }
        }

        if (gConfig.offHealth + sizeof(float) <= blockSize) {
            float health = *(const float *)(block + gConfig.offHealth);
            if (isfinite(health) && health >= 0.0f && health <= 1000.0f) {
                player->health = health;
            }
        }
        if (gConfig.offTeam + sizeof(int32_t) <= blockSize) {
            int32_t team = *(const int32_t *)(block + gConfig.offTeam);
            if (team >= 0 && team <= 15) { player->team = team; }
        }
        if (gConfig.offName != 0) {
            uint64_t name = 0;
            if (AscentGameRead(object + gConfig.offName, &name, sizeof(name)) &&
                AscentESPLooksLikePointer(name)) {
                AscentESPReadName(name, player->name, sizeof(player->name));
            }
        }

        count++;
    }

    if (count == 0) {
        AscentESPPublish(NULL, 0, YES, @"прочитано, но игроков не набралось");
        return;
    }

    AscentESPPublish(players, count, YES, [NSString stringWithFormat:@"игроков: %d", count]);
}

#pragma mark - Фоновый цикл

static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;

static void AscentESPTimerFired(void)
{
    @autoreleasepool {
        AscentESPConfigLoad();
        if (!gConfig.on) {
            AscentESPPublish(NULL, 0, NO, @"esp выключен");
            return;
        }
        AscentESPTickOnce();
    }
}

void AscentESPSetEnabled(BOOL enabled)
{
    if (enabled == gEnabled) { return; }
    gEnabled = enabled;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gQueue = dispatch_queue_create("com.ascentios.ascent.esp", DISPATCH_QUEUE_SERIAL);
    });

    if (!enabled) {
        AscentESPConfigLoad();
        gConfig.on = NO;
        dispatch_async(gQueue, ^{
            if (gTimer != NULL) {
                dispatch_source_cancel(gTimer);
                gTimer = NULL;
            }
            AscentESPPublish(NULL, 0, NO, @"esp выключен");
        });
        return;
    }

    dispatch_async(gQueue, ^{
        if (gTimer != NULL) { return; }
        gConfigTime = 0;
        AscentESPConfigLoad();

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        gTimer = timer;
        // 15 кадров в секунду: для ESP хватает, а чтение памяти не мешает игре.
        uint64_t interval = NSEC_PER_SEC / 15;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  interval, interval / 10);
        dispatch_source_set_event_handler(timer, ^{ AscentESPTimerFired(); });
        dispatch_resume(timer);
    });
}

BOOL AscentESPIsEnabled(void)
{
    return gEnabled;
}

void AscentESPSyncFromState(void)
{
    AscentESPConfigLoad();
    AscentESPSetEnabled(gConfig.on);
}

#pragma mark - Диагностика

void AscentESPRunProbe(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            AscentESPConfigLoad();
            uint64_t base = AscentGameModuleBase();

            AscentHUDLog(@"[esp] probe: attached=%d base=0x%llx offList=0x%llx offMatrix=0x%llx "
                         @"offPos=%u offHealth=%u offTeam=%u offName=%u offLocal=%u",
                         AscentGameIsAttached(), base, gConfig.offList, gConfig.offMatrix,
                         gConfig.offPos, gConfig.offHealth, gConfig.offTeam,
                         gConfig.offName, gConfig.offLocal);

            if (!AscentGameIsAttached() || base == 0 || gConfig.offList == 0) {
                AscentHUDLog(@"[esp] probe: нет данных для проверки");
                return;
            }

            uint64_t list = 0;
            if (!AscentGameRead(base + gConfig.offList, &list, sizeof(list))) {
                AscentHUDLog(@"[esp] probe: адрес 0x%llx не читается", base + gConfig.offList);
                return;
            }
            AscentHUDLog(@"[esp] probe: указатель списка = 0x%llx", list);
            if (!AscentESPLooksLikePointer(list)) {
                AscentHUDLog(@"[esp] probe: значение не похоже на указатель — смещение неверное");
                return;
            }

            uint64_t array = list;
            if (gConfig.offListArray != 0) {
                if (!AscentGameRead(list + gConfig.offListArray, &array, sizeof(array))) {
                    AscentHUDLog(@"[esp] probe: поле массива не читается");
                    return;
                }
                AscentHUDLog(@"[esp] probe: массив игроков = 0x%llx", array);
            }
            if (!AscentESPLooksLikePointer(array)) {
                AscentHUDLog(@"[esp] probe: поле массива не указатель — поправьте esp.off.listArray");
                return;
            }

            uint64_t maxCount = 0;
            if (!AscentGameRead(array + 16, &maxCount, sizeof(maxCount))) {
                AscentHUDLog(@"[esp] probe: размер списка не читается");
                return;
            }
            AscentHUDLog(@"[esp] probe: размер списка = %llu", maxCount);
            if (maxCount == 0 || maxCount > kAscentESPMaxPlayers) {
                AscentHUDLog(@"[esp] probe: размер неправдоподобен — смещение неверное");
                return;
            }

            uint64_t pointers[kAscentESPMaxPlayers];
            memset(pointers, 0, sizeof(pointers));
            if (!AscentGameRead(array + kIl2CppArrayItems, pointers,
                                sizeof(uint64_t) * (size_t)maxCount)) {
                AscentHUDLog(@"[esp] probe: указатели игроков не читаются");
                return;
            }

            for (uint64_t i = 0; i < maxCount && i < 3; i++) {
                uint64_t object = pointers[i];
                AscentHUDLog(@"[esp] probe: игрок[%llu] = 0x%llx", i, object);
                if (!AscentESPLooksLikePointer(object)) { continue; }

                uint8_t block[64];
                memset(block, 0, sizeof(block));
                if (!AscentGameRead(object, block, sizeof(block))) { continue; }

                AscentHUDLog(@"[esp] probe:   первые 16 байт: "
                             @"%02x %02x %02x %02x %02x %02x %02x %02x  "
                             @"%02x %02x %02x %02x %02x %02x %02x %02x",
                             block[0], block[1], block[2], block[3],
                             block[4], block[5], block[6], block[7],
                             block[8], block[9], block[10], block[11],
                             block[12], block[13], block[14], block[15]);

                if (gConfig.offPos + sizeof(float) * 3 <= sizeof(block)) {
                    const float *pos = (const float *)(block + gConfig.offPos);
                    AscentHUDLog(@"[esp] probe:   позиция[offPos=%u] = %.1f %.1f %.1f",
                                 gConfig.offPos, pos[0], pos[1], pos[2]);
                }
            }

            AscentHUDLog(@"[esp] probe: готово");
        }
    });
}
