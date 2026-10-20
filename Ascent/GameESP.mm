//
//  GameESP.mm
//  Ascent
//
//  Внешний ESP для Standoff 2. Отдельный процесс HUD читает память игры
//  через task_for_pid (GameMemory.mm) и раз в кадр публикует «снимок» —
//  готовый список игроков в нормализованных координатах экрана.
//  Рисовальщик (HUDOverlayView) только читает снимок: чтения памяти на
//  главном потоке нет.
//
//  РЕЗОЛВЕР. Список игроков, матрица камеры и позиции ищутся по цепочкам
//  указателей UnityFramework (статические поля, классы, массивы, TRS-записи
//  трансформов). Логика — построчный порт разобранного внешнего чита
//  (PastaWare): сканирование статиков (~200 мс), поиск «корня» и камеры
//  (~8 с), валидация класса игрока (K1), фильтр здоровья [1..32], цепочка
//  родителей трансформа (≤50 итераций), world→screen по 4x4 матрице.
//  Ручные смещения из plist для этого ESP не нужны.
//
#import "GameESP.h"
#import "GameMemory.h"
#import "HUDHelper.h"
#import <pthread.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

#pragma mark - Снимок (кадр)

static pthread_mutex_t gSnapshotMutex = PTHREAD_MUTEX_INITIALIZER;
static AscentESPPlayer gSnapshotPlayers[kAscentESPMaxPlayers];
static AscentESPFrame gSnapshotInfo;

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

int AscentESPGetFrame(AscentESPPlayer *outPlayers, int capacity, AscentESPFrame *outInfo)
{
    if (outInfo == NULL) {
        return 0;
    }
    pthread_mutex_lock(&gSnapshotMutex);
    AscentESPFrame copyInfo = gSnapshotInfo;
    int count = 0;
    if (outPlayers != NULL && capacity > 0) {
        count = MIN(gSnapshotInfo.count, capacity);
        if (count > 0) {
            memcpy(outPlayers, gSnapshotPlayers, count * sizeof(AscentESPPlayer));
        }
    }
    pthread_mutex_unlock(&gSnapshotMutex);
    *outInfo = copyInfo;
    return count;
}

static void AscentESPPublish(const AscentESPPlayer *players, int count,
                             BOOL active, const char *status)
{
    pthread_mutex_lock(&gSnapshotMutex);
    gSnapshotInfo.count = count;
    gSnapshotInfo.live = active;
    gSnapshotInfo.frameId++;
    gSnapshotInfo.pid = AscentGamePid();
    if (status != NULL) {
        strncpy(gSnapshotInfo.status, status, sizeof(gSnapshotInfo.status) - 1);
        gSnapshotInfo.status[sizeof(gSnapshotInfo.status) - 1] = 0;
    }
    if (players != NULL && count > 0) {
        memcpy(gSnapshotPlayers, players, count * sizeof(AscentESPPlayer));
    }
    pthread_mutex_unlock(&gSnapshotMutex);
}

#pragma mark - Резолвер: константы UnityFramework

// Статические поля UnityFramework (RVA от базы образа).
static const uint64_t kRvaP1          = 0xB813600;  // аргумент фильтра списка игроков
static const uint64_t kRvaP2          = 0xB810E80;  // тег «корень P2»
static const uint64_t kRvaP3          = 0xB818340;  // тег «корень P3»
static const uint64_t kRvaP4          = 0xB802058;  // тег камеры
static const uint64_t kRvaK1          = 0xB8117D8;  // klass игроков
static const uint64_t kRvaRootProbe   = 0xB80B2A0;  // точка входа поиска корня

// 11 пар «кандидат klass → смещение поля» для поиска корня.
static const uint64_t kCandidateRva[11] = {
    0xB816578, 0xB8142F8, 0xB818CD8, 0xB811560, 0xB813C90, 0xB8130D8,
    0xB814E60, 0xB811020, 0xB816CD0, 0xB812F18, 0xB817EF0
};
static const uint32_t kCandidateFieldOff[11] = {16, 16, 16, 16, 16, 64, 56, 32, 40, 16, 16};

// Смещения полей игрока (из реверса).
static const uint32_t kOffTeam      = 0x14;  // u32 команда
static const uint32_t kOffTransform = 0x28;  // u64 Transform
static const uint32_t kOffHealth    = 0x90;  // u32 здоровье (фильтр 1..32)

// Тайминги (мкс), как в оригинале.
static const uint64_t kScanIntervalUs   = 200ull * 1000ull;    // перескан статиков
static const uint64_t kRootsIntervalUs  = 8000ull * 1000ull;   // полный поиск корня/камеры
static const uint64_t kRootsRetryUs     = 3125ull * 1000ull;   // повтор, если корня нет

#pragma mark - Резолвер: состояние

typedef struct {
    uint64_t base;        // база UnityFramework
    uint64_t P1, P2, P3, P4, K1;

    uint64_t rootA;       // «корень» списка игроков
    int      rootFlag;    // 0 → список по rootA+0x40, 1 → rootA+0x50

    uint64_t camHolder;   // объект камеры (из поиска корня)
    uint64_t camObj;      // камера, с которой перечитываем матрицу
    int      matrixReady;
    float    matrix[16];
    int      matrixSource;  // 1 = cam+0x100, 2 = A×B

    uint64_t lastScanUs;
    uint64_t lastRootsUs;
    uint64_t lastLogUs;

    // диагностика (видна в Misc)
    int      lastFail;      // код неудачи поиска корня (0 — ок)
    int      listVariant;   // 1 или 2 — какая вложенность списка сработала
    uint32_t nEntries;      // сколько записей в списке
    uint32_t nRejected;     // отброшено (не K1 / здоровье вне 1..32)
    uint32_t nPlayers;      // сколько игроков в последнем снимке
} ESPResolver;

static ESPResolver gResolver;

static uint64_t ESPNowUs(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

#pragma mark - Резолвер: чтение

// Диапазон адресов, который читает оригинал (guard «addr ∈ [1; ~100 ГБ]»).
static BOOL ESPLikePointer(uint64_t address)
{
    return address >= 0x1000001ull && address <= 0x174876E800ull;
}

static uint64_t ESPRead64(uint64_t address)
{
    uint64_t value = 0;
    if (!ESPLikePointer(address)) { return 0; }
    if (!AscentGameRead(address, &value, sizeof(value))) { return 0; }
    return value;
}

static uint32_t ESPRead32(uint64_t address)
{
    uint32_t value = 0;
    if (!ESPLikePointer(address)) { return 0; }
    if (!AscentGameRead(address, &value, sizeof(value))) { return 0; }
    return value;
}

static BOOL ESPReadBulk(uint64_t address, void *buffer, size_t length)
{
    if (!ESPLikePointer(address)) { return NO; }
    return AscentGameRead(address, buffer, length);
}

// Читает il2cpp-массив: количество по +0x18 (в пределах [1; maxCount]),
// элементы по +0x20 (указатели по 8 байт).
static BOOL ESPReadArrayInfo(uint64_t array, uint32_t maxCount,
                             uint64_t *outElements, uint32_t *outCount)
{
    if (!ESPLikePointer(array)) { return NO; }
    uint32_t count = ESPRead32(array + 0x18);
    if (count < 1 || count > maxCount) { return NO; }
    *outElements = array + 0x20;
    *outCount = count;
    return YES;
}

#pragma mark - Резолвер: матрица

// Валидация 4x4 матрицы (как validate из оригинала): все значения конечны и
// |v| ≤ 1e5; частичная сумма третьей строки > 0.05; суммы строк 0 и 3 > 1e-4.
static int ESPMatValid(const void *matrix64)
{
    const float *m = (const float *)matrix64;
    for (int i = 0; i < 16; i++) {
        if (!isfinite(m[i]) || fabsf(m[i]) > 1e5f) { return 0; }
    }
    float partial3 = fabsf(m[3]) + fabsf(m[7]) + fabsf(m[11]);
    if (!(partial3 > 0.05f)) { return 0; }
    float sum0 = fabsf(m[0]) + fabsf(m[4]) + fabsf(m[8]) + fabsf(m[12]);
    float sum3 = partial3 + fabsf(m[15]);
    return (sum0 > 1e-4f && sum3 > 1e-4f) ? 1 : 0;
}

// C = A × B (по строкам, как в оригинальном fallback).
static void ESPMatMul(float out[16], const float a[16], const float b[16])
{
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            out[c * 4 + r] = a[r]        * b[c * 4]
                           + a[4 + r]    * b[c * 4 + 1]
                           + a[8 + r]    * b[c * 4 + 2]
                           + a[12 + r]   * b[c * 4 + 3];
        }
    }
}

// Чтение матрицы с камеры: гейт (пара 0x80 байт по cam+0x70), затем быстрый
// путь (64 байта по cam+0x100) или произведение пара A×B.
static int ESPMatrixFromCamera(uint64_t cam, float out[16])
{
    uint8_t pair[128];
    if (!ESPReadBulk(cam + 0x70, pair, sizeof(pair))) { return 0; }
    if (!ESPMatValid(pair) || !ESPMatValid(pair + 64)) { return 0; }

    uint8_t fast[64];
    if (ESPReadBulk(cam + 0x100, fast, sizeof(fast)) && ESPMatValid(fast)) {
        memcpy(out, fast, 64);
        gResolver.matrixSource = 1;
        return 1;
    }
    ESPMatMul(out, (const float *)pair, (const float *)(pair + 64));
    gResolver.matrixSource = 2;
    return ESPMatValid(out);
}

// Обновление матрицы: сначала перечитываем с уже известной камеры,
// иначе берём камеру из кэмп-холдера (свежий путь).
static int ESPUpdateMatrix(void)
{
    if (gResolver.matrixReady && ESPLikePointer(gResolver.camObj)) {
        float m[16];
        if (ESPMatrixFromCamera(gResolver.camObj, m)) {
            memcpy(gResolver.matrix, m, 64);
            return 1;
        }
        gResolver.matrixReady = 0;
        gResolver.camObj = 0;
    }
    uint64_t cam = gResolver.camHolder;
    if (ESPLikePointer(cam)) {
        float m[16];
        if (ESPMatrixFromCamera(cam, m)) {
            gResolver.camObj = cam;
            memcpy(gResolver.matrix, m, 64);
            gResolver.matrixReady = 1;
            return 1;
        }
    }
    return gResolver.matrixReady;
}

#pragma mark - Резолвер: скан статиков и поиск корня

static void ESPScanStatics(uint64_t base)
{
    ESPResolver *r = &gResolver;
    r->P1 = ESPRead64(base + kRvaP1);
    r->P2 = ESPRead64(base + kRvaP2);
    r->P3 = ESPRead64(base + kRvaP3);
    r->P4 = ESPRead64(base + kRvaP4);
    r->K1 = ESPRead64(base + kRvaK1);
}

// Имя класса: il2cpp-строка по klass+0x10, сравниваем первые 3 символа.
static int ESPClassNameIs(uint64_t klass, char c0, char c1, char c2)
{
    uint64_t nameObj = ESPRead64(klass + 0x10);
    if (!ESPLikePointer(nameObj)) { return 0; }
    uint32_t length = ESPRead32(nameObj + 0x10);
    if (length < 3) { return 0; }
    uint16_t chars[3] = {0, 0, 0};
    if (!ESPReadBulk(nameObj + 0x14, chars, sizeof(chars))) { return 0; }
    return (chars[0] == (uint16_t)c0 && chars[1] == (uint16_t)c1 && chars[2] == (uint16_t)c2) ? 1 : 0;
}

// Поиск «корня» списка игроков и камеры (порт f_270f0):
//   V1=[base+0xB80B2A0] → +0xB8 → [V3] → массив1;
//   z → [z+0x10] → +0x18 → массив2; z2 → [z2+0x20]==0 → [z2+0x10] → массив3;
//   e → klass=[e]; для пары кандидатов: v=[e+off], w=[v]; w==P3 → корень
//   (флаг 0), иначе w==P2 → запасной корень (флаг 1). Камера: a2=[e+0x20],
//   [a2]==P4, имя класса «loa» → камера, «qst» → пропуск, прочее — резерв.
static void ESPFindRoots(void)
{
    ESPResolver *r = &gResolver;
    r->lastFail = 0;

    uint64_t candidates[11];
    for (int c = 0; c < 11; c++) {
        candidates[c] = ESPRead64(r->base + kCandidateRva[c]);
    }

    uint64_t v1 = ESPRead64(r->base + kRvaRootProbe);
    if (!ESPLikePointer(v1)) { r->lastFail = 1; return; }
    uint64_t v2 = ESPRead64(v1 + 0xB8);
    if (!ESPLikePointer(v2)) { r->lastFail = 1; return; }
    uint64_t v3 = ESPRead64(v2);
    if (!ESPLikePointer(v3)) { r->lastFail = 2; return; }

    uint64_t elements1 = 0;
    uint32_t count1 = 0;
    if (!ESPReadArrayInfo(v3, 0x2000, &elements1, &count1)) { r->lastFail = 3; return; }

    uint64_t foundRoot = 0;
    uint64_t fallbackRoot = 0;
    uint64_t cam = 0;

    for (uint32_t i = 0; i < count1; i++) {
        uint64_t z = ESPRead64(elements1 + i * 8);
        if (!ESPLikePointer(z)) { continue; }
        uint64_t a = ESPRead64(z + 0x10);
        if (!ESPLikePointer(a)) { continue; }
        uint64_t b = ESPRead64(a + 0x18);
        if (!ESPLikePointer(b)) { continue; }

        uint64_t elements2 = 0;
        uint32_t count2 = 0;
        if (!ESPReadArrayInfo(b, 0x2000, &elements2, &count2)) { continue; }

        for (uint32_t j = 0; j < count2; j++) {
            uint64_t z2 = ESPRead64(elements2 + j * 8);
            if (!ESPLikePointer(z2)) { continue; }
            if (ESPRead32(z2 + 0x20) != 0) { continue; }
            uint64_t source3 = ESPRead64(z2 + 0x10);
            if (!ESPLikePointer(source3)) { continue; }

            uint64_t elements3 = 0;
            uint32_t count3 = 0;
            if (!ESPReadArrayInfo(source3, 0x800, &elements3, &count3)) { continue; }

            for (uint32_t k = 0; k < count3; k++) {
                uint64_t obj = ESPRead64(elements3 + k * 8);
                if (!ESPLikePointer(obj)) { continue; }
                uint64_t klass = ESPRead64(obj);
                if (!ESPLikePointer(klass)) { continue; }

                if (!foundRoot || !fallbackRoot) {
                    for (int c = 0; c < 11; c++) {
                        if (candidates[c] == 0 || klass != candidates[c]) { continue; }
                        uint64_t v = ESPRead64(obj + kCandidateFieldOff[c]);
                        if (!ESPLikePointer(v)) { break; }
                        uint64_t w = ESPRead64(v);
                        if (w == r->P3 && r->P3 >= 0x1000001ull) {
                            if (!foundRoot) { foundRoot = v; }
                        } else if (w == r->P2 && r->P2 >= 0x1000001ull && !fallbackRoot) {
                            fallbackRoot = v;
                        }
                        break;
                    }
                }

                if (!cam) {
                    uint64_t a2 = ESPRead64(obj + 0x20);
                    if (ESPLikePointer(a2) && ESPRead64(a2) == r->P4) {
                        if (ESPClassNameIs(klass, 'l', 'o', 'a')) {
                            cam = a2;
                        } else if (!ESPClassNameIs(klass, 'q', 's', 't')) {
                            cam = a2;  // резерв: не «loa» и не «qst»
                        }
                    }
                }
            }
        }
    }

    r->camHolder = cam;

    uint64_t root = foundRoot ? foundRoot : fallbackRoot;
    if (!ESPLikePointer(root)) {
        if (r->lastFail == 0) { r->lastFail = 4; }
        return;
    }

    // check_27674: корень валиден, если [root] равен P3 или P2 (оба — heap).
    uint64_t w = ESPRead64(root);
    int w8 = (w != r->P3) ? 1 : (r->P3 < 0x1000001ull);
    if (w8 == 1 && w == r->P2 && r->P2 >= 0x1000001ull) {
        r->rootA = root;
        r->rootFlag = 1;
    } else if (w == r->P3 && r->P3 >= 0x1000001ull) {
        r->rootA = root;
        r->rootFlag = 0;
    } else {
        r->lastFail = 5;
    }
}

#pragma mark - Резолвер: игроки

// validate_275a4: объект — экземпляр класса игроков (klass == K1) и у него
// есть Transform.
static int ESPValidatePlayerObject(uint64_t obj)
{
    if (!ESPLikePointer(obj)) { return 0; }
    uint64_t klass = ESPRead64(obj);
    if (!ESPLikePointer(klass)) { return 0; }
    if (!ESPLikePointer(gResolver.K1) || klass != gResolver.K1) { return 0; }
    return ESPLikePointer(ESPRead64(obj + kOffTransform)) ? 1 : 0;
}

// Список игроков: owner = [rootA + (флаг ? 0x50 : 0x40)] — объект-список.
// Пробуем две вложенности: owner сам il2cpp-массив (вариант 1) или
// массив лежит по owner+0x20 (вариант 2). Далее фильтры оригинала:
// объект — K1, здоровье u32@(obj+0x90) ∈ [1..32], без дублей.
static int ESPBuildPlayerList(uint64_t *outObjects, int capacity)
{
    ESPResolver *r = &gResolver;
    if (!ESPLikePointer(r->rootA)) { return -1; }

    uint64_t owner = ESPRead64(r->rootA + (r->rootFlag ? 0x50 : 0x40));
    if (!ESPLikePointer(owner)) { return -2; }

    uint64_t elements = 0;
    uint32_t count = 0;
    int variant = 0;
    if (ESPReadArrayInfo(owner, 0x800, &elements, &count)) {
        variant = 1;
    } else {
        uint64_t inner = ESPRead64(owner + 0x20);
        if (ESPReadArrayInfo(inner, 0x800, &elements, &count)) {
            variant = 2;
        }
    }
    if (variant == 0) { return -3; }
    r->listVariant = variant;
    r->nEntries = count;

    uint32_t limit = count;
    if (limit > (uint32_t)capacity) { limit = (uint32_t)capacity; }

    int outCount = 0;
    uint32_t rejected = 0;
    uint64_t seen[64];
    int seenCount = 0;

    for (uint32_t i = 0; i < limit; i++) {
        uint64_t obj = ESPRead64(elements + i * 8);
        if (!ESPValidatePlayerObject(obj)) { rejected++; continue; }

        uint32_t health = ESPRead32(obj + kOffHealth);
        if (health < 1 || health > 32) { rejected++; continue; }

        int duplicate = 0;
        for (int s = 0; s < seenCount; s++) {
            if (seen[s] == obj) { duplicate = 1; break; }
        }
        if (duplicate) { continue; }
        if (seenCount < 64) { seen[seenCount++] = obj; }

        outObjects[outCount++] = obj;
    }

    r->nRejected = rejected;
    return outCount;
}

// Моя команда: u32@(u64@(u64@(rootA+0xC0)+0xB0)+0x13) — только для корня P3.
static uint32_t ESPMyTeam(void)
{
    if (gResolver.rootFlag != 0) { return 0; }
    uint64_t a = ESPRead64(gResolver.rootA + 0xC0);
    if (!ESPLikePointer(a)) { return 0; }
    uint64_t b = ESPRead64(a + 0xB0);
    if (!ESPLikePointer(b)) { return 0; }
    return ESPRead32(b + 0x13);
}

#pragma mark - Резолвер: позиция трансформа

// Валидации TRS-записи (48 байт: позиция, кватернион, масштаб) — как в оригинале.
static int ESPVecFinite1e5(const float *v)
{
    for (int i = 0; i < 3; i++) {
        if (!isfinite(v[i]) || fabsf(v[i]) > 1e5f) { return 0; }
    }
    return 1;
}

static int ESPQuatOk(const float *q)
{
    float sum = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    return (sum > 0.5f && sum < 1.5f) ? 1 : 0;
}

static int ESPScaleOk(const float *s)
{
    for (int i = 0; i < 3; i++) {
        if (!isfinite(s[i]) || fabsf(s[i]) > 100.0f) { return 0; }
    }
    return 1;
}

static void ESPRead48(uint64_t address, float out[12])
{
    uint8_t buffer[48];
    if (!ESPReadBulk(address, buffer, sizeof(buffer))) {
        memset(out, 0, 48);
        return;
    }
    memcpy(out, buffer, 48);
}

// Позиция мира из Transform (порт get_position_by_transform_with):
//   P = [transform+0x10]; ptrA = [P+0x28]; index = u32@(P+0x30);
//   ptrB = [ptrA+0x18] (TRS-записи по 48 байт), ptrC = [ptrA+0x20] (родители);
//   acc = своя позиция; далее ≤50 раз: acc = parent.pos + parent.quat ×
//   (parent.scale ⊙ acc); parent<0 — стоп.
static int ESPPositionFromTransform(uint64_t transform, float out[3])
{
    uint64_t p = ESPRead64(transform + 0x10);
    if (!ESPLikePointer(p)) { return 0; }

    uint64_t ptrA = ESPRead64(p + 0x28);
    uint32_t index = ESPRead32(p + 0x30);
    if (!ESPLikePointer(ptrA)) { return 0; }

    uint64_t ptrB = ESPRead64(ptrA + 0x18);
    uint64_t ptrC = ESPRead64(ptrA + 0x20);
    if (!ESPLikePointer(ptrB) || !ESPLikePointer(ptrC)) { return 0; }

    float entry[12];
    ESPRead48(ptrB + (uint64_t)index * 48, entry);
    if (!ESPVecFinite1e5(entry) || !ESPQuatOk(entry + 3)) { return 0; }

    float ax = entry[0], ay = entry[1], az = entry[2];
    uint32_t parent = ESPRead32(ptrC + (uint64_t)index * 4);

    for (int iter = 50; iter > 0 && (parent & 0x80000000u) == 0; iter--) {
        float e[12];
        ESPRead48(ptrB + (uint64_t)parent * 48, e);
        if (!ESPVecFinite1e5(e) || !ESPQuatOk(e + 3) || !ESPScaleOk(e + 7)) { return 0; }

        float px = e[0], py = e[1], pz = e[2];
        float qx = e[3], qy = e[4], qz = e[5], qw = e[6];
        float sx = e[7], sy = e[8], sz = e[9];
        float bx = ax * sx, by = ay * sy, bz = az * sz;

        float r00 = 1.0f - 2.0f * (qy * qy + qz * qz);
        float r01 = 2.0f * (qx * qy - qz * qw);
        float r02 = 2.0f * (qx * qz + qy * qw);
        float r10 = 2.0f * (qx * qy + qz * qw);
        float r11 = 1.0f - 2.0f * (qx * qx + qz * qz);
        float r12 = 2.0f * (qy * qz - qx * qw);
        float r20 = 2.0f * (qx * qz - qy * qw);
        float r21 = 2.0f * (qx * qw + qy * qz);
        float r22 = 1.0f - 2.0f * (qx * qx + qy * qy);

        ax = px + r00 * bx + r01 * by + r02 * bz;
        ay = py + r10 * bx + r11 * by + r12 * bz;
        az = pz + r20 * bx + r21 * by + r22 * bz;

        parent = ESPRead32(ptrC + (uint64_t)parent * 4);
    }

    out[0] = ax;
    out[1] = ay;
    out[2] = az;
    return 1;
}

#pragma mark - Резолвер: проекция

// Мир→экран по 4x4 матрице (column-major: элемент (row r, col c) = m[c*4+r]).
// Результат нормализован (0..1); невидимо за спиной камеры (w < 1e-4).
// w проекции — это расстояние вдоль взгляда камеры в метрах (1 юнит Unity
// = 1 м): отдаём его через outDepth, если он нужен (NULL — не нужен).
static int ESPWorldToScreen(const float m[16], const float pos[3],
                            CGPoint *outNormalized, float *outDepth)
{
    float w = m[3] * pos[0] + m[7] * pos[1] + m[11] * pos[2] + m[15];
    if (w < 1e-4f) { return 0; }
    float clipX = m[0] * pos[0] + m[4] * pos[1] + m[8]  * pos[2] + m[12];
    float clipY = m[1] * pos[0] + m[5] * pos[1] + m[9]  * pos[2] + m[13];
    outNormalized->x = 0.5f + 0.5f * (clipX / w);
    outNormalized->y = 0.5f - 0.5f * (clipY / w);
    if (outDepth != NULL) { *outDepth = w; }
    return 1;
}

#pragma mark - Основной проход

static void AscentESPTickOnce(void)
{
    if (AscentSharedNumber(@"cheat.esp") <= 0.5) {
        // Выключено: сбрасываем резолвер, чтобы при включении всё перечиталось.
        uint64_t keptBase = gResolver.base;
        memset(&gResolver, 0, sizeof(gResolver));
        gResolver.base = keptBase;
        AscentESPPublish(NULL, 0, NO, "esp выключен");
        return;
    }
    if (!AscentGameIsAttached()) {
        AscentESPPublish(NULL, 0, NO, "нет доступа к процессу игры");
        return;
    }

    ESPResolver *r = &gResolver;
    uint64_t now = ESPNowUs();

    if (r->base == 0) {
        r->base = AscentGameImageBase(@"UnityFramework");
        if (r->base == 0) {
            AscentESPPublish(NULL, 0, NO, "образ UnityFramework не найден");
            return;
        }
    }

    // 1) Статики: P1..P4, K1.
    if (r->lastScanUs == 0 || now - r->lastScanUs >= kScanIntervalUs) {
        r->lastScanUs = now;
        ESPScanStatics(r->base);
    }

    // 2) Корень и камера: полный поиск раз в 8 с; повтор через 3.1 с, пока корня нет.
    BOOL needRoots = (r->lastRootsUs == 0 || now - r->lastRootsUs >= kRootsIntervalUs ||
                      (!ESPLikePointer(r->rootA) && now - r->lastRootsUs >= kRootsRetryUs));
    if (needRoots) {
        r->lastRootsUs = now;
        ESPFindRoots();
    }

    // 3) Матрица камеры.
    if (!ESPUpdateMatrix()) {
        char status[256];
        snprintf(status, sizeof(status), "матрица камеры не читается (корень:%d)", r->lastFail);
        AscentESPPublish(NULL, 0, NO, status);
        return;
    }

    // 4) Список игроков.
    uint64_t objects[kAscentESPMaxPlayers];
    int count = ESPBuildPlayerList(objects, kAscentESPMaxPlayers);
    if (count < 0) {
        const char *why = "нет данных";
        if (count == -1) { why = "нет корня"; }
        else if (count == -2) { why = "корень без списка"; }
        else if (count == -3) { why = "структура списка не найдена"; }
        char status[256];
        snprintf(status, sizeof(status), "ESP: %s (scan fail=%d)", why, r->lastFail);
        AscentESPPublish(NULL, 0, NO, status);
        return;
    }

    // 5) Позиции и проекция.
    AscentESPPlayer players[kAscentESPMaxPlayers];
    memset(players, 0, sizeof(players));
    int playerCount = 0;
    uint32_t myTeam = ESPMyTeam();

    for (int i = 0; i < count && playerCount < kAscentESPMaxPlayers; i++) {
        uint64_t obj = objects[i];

        uint32_t team = ESPRead32(obj + kOffTeam);
        uint32_t health = ESPRead32(obj + kOffHealth);
        uint64_t transform = ESPRead64(obj + kOffTransform);

        float pos[3];
        if (!ESPPositionFromTransform(transform, pos)) { continue; }

        CGPoint feet;
        CGPoint headPoint;
        float depth = 0.0f;
        float headPos[3] = {pos[0], pos[1] + 1.8f, pos[2]};
        if (!ESPWorldToScreen(r->matrix, pos, &feet, &depth)) { continue; }
        if (!ESPWorldToScreen(r->matrix, headPos, &headPoint, NULL)) { continue; }

        float boxHeight = fabsf(feet.y - headPoint.y);
        if (boxHeight < 0.004f) { continue; }

        AscentESPPlayer *player = &players[playerCount];
        player->screen = CGPointMake((feet.x + headPoint.x) * 0.5f,
                                     (feet.y + headPoint.y) * 0.5f);
        player->boxHeight = boxHeight;
        player->health = (float)health * (100.0f / 32.0f);
        if (player->health > 100.0f) { player->health = 100.0f; }
        player->team = (myTeam != 0 && team == myTeam) ? 0 : 1;
        // Расстояние: w матрицы проекции = глубина вдоль взгляда камеры
        // (в метрах). Для подписи «N m» под боксом точности хватает.
        player->distance = (int)(depth + 0.5f);
        player->name[0] = 0;
        playerCount++;
    }

    r->nPlayers = (uint32_t)playerCount;

    char status[256];
    snprintf(status, sizeof(status),
             "ESP: корень ok (флаг %d), матр %s, список v%d, игроков %d (отбрано %u)",
             r->rootFlag, r->matrixSource == 1 ? "быстрая" : "A×B",
             r->listVariant, playerCount, r->nRejected);
    AscentESPPublish(players, playerCount, YES, status);

    // Периодический подробный лог для отладки на устройстве.
    if (now - r->lastLogUs >= 5000000ull) {
        r->lastLogUs = now;
        AscentHUDLog(@"[esp] base=0x%llx P1=0x%llx P2=0x%llx P3=0x%llx K1=0x%llx",
                     r->base, r->P1, r->P2, r->P3, r->K1);
        AscentHUDLog(@"[esp] root=0x%llx флаг=%d камера=0x%llx матр=%d записей=%u отбрано=%u игроков=%d",
                     r->rootA, r->rootFlag, r->camHolder, r->matrixSource,
                     r->nEntries, r->nRejected, playerCount);
    }
}

#pragma mark - Таймер

static void AscentESPStartTimer(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create("ascent.esp", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  66ull * NSEC_PER_MSEC,   // ~15 Гц
                                  10ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                AscentESPTickOnce();
            }
        });
        dispatch_resume(timer);
    });
}

#pragma mark - Внешний интерфейс

void AscentESPSyncFromState(void)
{
    AscentESPStartTimer();
}

// AscentGameTick (GameMemory.mm, таймер HUDApp) зовёт эту пару, чтобы ESP
// читал память только когда есть и тумблер, и task-порт. Само чтение тик
// включает/выключает по ключу cheat.esp из общего файла, поэтому здесь
// достаточно поднять цикл; останавливать его не нужно — без переключателя
// тик публикует «esp выключен» и сбрасывает резолвер.
void AscentESPSetEnabled(BOOL enabled)
{
    if (enabled) {
        AscentESPStartTimer();
    }
}

BOOL AscentESPIsEnabled(void)
{
    return AscentSharedNumber(@"cheat.esp") > 0.5;
}

void AscentESPRunProbe(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            uint64_t base = gResolver.base ? gResolver.base : AscentGameImageBase(@"UnityFramework");
            AscentHUDLog(@"[esp] probe: attached=%d base=0x%llx UnityFramework=%d",
                         AscentGameIsAttached(), base, base != 0);
            if (base == 0 || !AscentGameIsAttached()) {
                AscentHUDLog(@"[esp] probe: нет данных для проверки");
                return;
            }
            ESPResolver saved = gResolver;
            gResolver.base = base;
            ESPScanStatics(base);
            AscentHUDLog(@"[esp] probe: P1=0x%llx P2=0x%llx P3=0x%llx P4=0x%llx K1=0x%llx",
                         gResolver.P1, gResolver.P2, gResolver.P3, gResolver.P4, gResolver.K1);
            uint64_t savedRootA = gResolver.rootA;
            int savedFlag = gResolver.rootFlag;
            ESPFindRoots();
            AscentHUDLog(@"[esp] probe: корень=0x%llx флаг=%d fail=%d камера=0x%llx",
                         gResolver.rootA, gResolver.rootFlag, gResolver.lastFail, gResolver.camHolder);
            if (ESPLikePointer(gResolver.rootA) && ESPUpdateMatrix()) {
                uint64_t objects[kAscentESPMaxPlayers];
                int count = ESPBuildPlayerList(objects, kAscentESPMaxPlayers);
                AscentHUDLog(@"[esp] probe: матр ok (src=%d), список: %d (v%d, записей %u, отбрано %u)",
                             gResolver.matrixSource, count, gResolver.listVariant,
                             gResolver.nEntries, gResolver.nRejected);
            } else {
                AscentHUDLog(@"[esp] probe: матрица/корень не подтвердились");
            }
            // Восстанавливаем состояние рабочего прохода (кроме времён —
            // таймер сам перечитает по своим интервалам).
            gResolver.P1 = saved.P1; gResolver.P2 = saved.P2;
            gResolver.P3 = saved.P3; gResolver.P4 = saved.P4;
            gResolver.K1 = saved.K1;
            gResolver.rootA = savedRootA;
            gResolver.rootFlag = savedFlag;
        }
    });
}
