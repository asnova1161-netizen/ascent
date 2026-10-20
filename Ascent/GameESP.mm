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

// Смещения полей игрока (из f_2840c / f_27ed0).
static const uint32_t kOffTeam       = 0x14;  // u8 команда
static const uint32_t kOffComponents = 0x28;  // u64 держатель компонентов
static const uint32_t kOffHealth     = 0x90;  // u8 здоровье (фильтр 1..32)

// Камера и компоненты (из f_282ac / f_2b854 / f_3c2ec).
static const uint32_t kOffCamView   = 0x70;  // view: 64 байта
static const uint32_t kOffCamProj   = 0xB0;  // proj: 64 байта
static const uint32_t kOffCamCached = 0xF0;  // готовая матрица proj×view (кэш)
static const uint32_t kOffNodeStride = 0x30; // размер TRS-записи
static const uint32_t kMaxComponents = 64;   // count компонентов ∈ [1,64]

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
    int      matrixSource;  // 1 = кэш cam+0xF0, 2 = proj × view

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

static uint8_t ESPRead8(uint64_t address)
{
    uint8_t value = 0;
    if (!ESPLikePointer(address)) { return 0; }
    if (!AscentGameRead(address, &value, sizeof(value))) { return 0; }
    return value;
}

static BOOL ESPReadBulk(uint64_t address, void *buffer, size_t length)
{
    if (!ESPLikePointer(address)) { return NO; }
    return AscentGameRead(address, buffer, length);
}

// Читает массив как readarray_2aee8: count = u32@(obj+0x18) ∈ [1,0x2000];
// элементы — obj+0x20, если u64@(obj+0x20) похож на выровненный указатель;
// иначе inner = u64@(obj+0x10): если count2 = u32@(inner+0x18) < 0x2001 и
// count2 ≥ count — элементы в inner+0x20, иначе снова obj+0x20.
static BOOL ESPReadArrayInfo(uint64_t obj, uint64_t *outElements, uint32_t *outCount)
{
    *outElements = 0;
    *outCount = 0;
    if (!ESPLikePointer(obj)) { return NO; }
    uint32_t count = ESPRead32(obj + 0x18);
    if (count < 1 || count > 0x2000) { return NO; }

    uint64_t elements = obj + 0x20;
    uint64_t first = ESPRead64(obj + 0x20);
    if (!(ESPLikePointer(first) && (first & 7) == 0)) {
        uint64_t inner = ESPRead64(obj + 0x10);
        if (inner >= 0x1000001ull) {
            uint32_t count2 = ESPRead32(inner + 0x18);
            if (count2 < 0x2001 && count2 >= count) {
                elements = inner + 0x20;
            }
        }
    }
    *outElements = elements;
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

// Валидация view (f_2b350): все элементы конечны и |v| ≤ 1e5; m33 ∈ [0.9,1.1];
// нормы первых трёх строк 3x3: |row0|² ≤ 4 и min(|row0|²,|row1|²) ≥ 0.25,
// |row2|² ∈ [0.25,4].
static int ESPViewValid(const float *v)
{
    for (int i = 0; i < 16; i++) {
        if (!isfinite(v[i]) || fabsf(v[i]) > 1e5f) { return 0; }
    }
    if (!(v[15] >= 0.9f && v[15] <= 1.1f)) { return 0; }
    float row0 = v[0] * v[0] + v[4] * v[4] + v[8] * v[8];
    float row1 = v[1] * v[1] + v[5] * v[5] + v[9] * v[9];
    float row2 = v[2] * v[2] + v[6] * v[6] + v[10] * v[10];
    if (!(row0 <= 4.0f)) { return 0; }
    if (!(fminf(row0, row1) >= 0.25f)) { return 0; }
    if (!(row2 >= 0.25f && row2 <= 4.0f)) { return 0; }
    return 1;
}

// Валидация проекции (f_2b350): все элементы конечны и |v| ≤ 1e5; m00 ∈ [0.1,10].
static int ESPProjValid(const float *p)
{
    for (int i = 0; i < 16; i++) {
        if (!isfinite(p[i]) || fabsf(p[i]) > 1e5f) { return 0; }
    }
    if (!(p[0] >= 0.1f && p[0] <= 10.0f)) { return 0; }
    return 1;
}

// Сырые view/proj камеры-ребёнка (f_2b350): 128 байт по camChild+0x70,
// первые 64 байта — view, вторые — proj.
static int ESPRawViewProj(uint64_t camChild, float view[16], float proj[16])
{
    uint8_t raw[128];
    if (!ESPReadBulk(camChild + kOffCamView, raw, sizeof(raw))) { return 0; }
    memcpy(view, raw, 64);
    memcpy(proj, raw + 64, 64);
    return ESPViewValid(view) && ESPProjValid(proj);
}

// Комбинированная матрица (f_2b218): быстрый кэш camChild+0xF0, иначе
// out = proj × view (column-major) с валидацией f_2b5d0.
static int ESPCombinedMatrix(uint64_t camChild, float out[16], int *source)
{
    uint8_t fast[64];
    if (ESPReadBulk(camChild + kOffCamCached, fast, sizeof(fast)) && ESPMatValid(fast)) {
        memcpy(out, fast, 64);
        if (source != NULL) { *source = 1; }
        return 1;
    }
    float view[16], proj[16];
    if (!ESPRawViewProj(camChild, view, proj)) { return 0; }
    ESPMatMul(out, proj, view);
    if (!ESPMatValid(out)) { return 0; }
    if (source != NULL) { *source = 2; }
    return 1;
}

// Обновление матрицы (f_282ac): camChild = u64@(camHolder+0x10) — обязательный
// хоп; свежий путь — гейт сырых view/proj и комбинированная матрица; иначе
// кэш прошлой камеры; при провале — сброс готовности.
static int ESPUpdateMatrix(void)
{
    ESPResolver *r = &gResolver;

    uint64_t camChild = ESPRead64(r->camHolder + 0x10);
    if (ESPLikePointer(camChild)) {
        float view[16], proj[16], out[16];
        int source = 0;
        if (ESPRawViewProj(camChild, view, proj) &&
            ESPCombinedMatrix(camChild, out, &source)) {
            r->camObj = camChild;
            r->matrixSource = source;
            memcpy(r->matrix, out, 64);
            r->matrixReady = 1;
            return 1;
        }
    }

    if (r->matrixReady && ESPLikePointer(r->camObj)) {
        float out[16];
        if (ESPCombinedMatrix(r->camObj, out, NULL)) {
            memcpy(r->matrix, out, 64);
            return 1;
        }
        r->matrixReady = 0;
        r->camObj = 0;
    }
    return 0;
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

// Имя класса (strcompare_2afa8): u64@(klass+0x10) — сырая C-строка; читаем
// 24 байта, [23] = 0, сравнение точное (имя целиком).
static int ESPClassNameIs(uint64_t klass, const char *name)
{
    uint64_t namePtr = ESPRead64(klass + 0x10);
    if (!ESPLikePointer(namePtr)) { return 0; }
    uint8_t buffer[24];
    memset(buffer, 0, sizeof(buffer));
    if (!ESPReadBulk(namePtr, buffer, sizeof(buffer))) { return 0; }
    buffer[23] = 0;
    return strncmp((const char *)buffer, name, sizeof(buffer)) == 0 ? 1 : 0;
}

// check_27674 (реализация ниже, нужна и поиску корня).
static int ESPCheckRoot(uint64_t root);

// Поиск «корня» списка игроков и камеры (порт f_270f0):
//   v1=[base+0xB80B2A0] → v2=[v1+0xB8] → v3=[v2] → массив1;
//   elem1 → z1=[elem1+0x10] → z2=[z1+0x18] → массив2;
//   elem2: u8@(elem2+0x20)==0 → u64@(elem2+0x10) → массив3;
//   elem3: klass=[elem3]; до 10 кандидатов (первый матч выигрывает, без break),
//   w=[v] == P3 → корень (флаг 0), w == P2 → запасной (флаг 1). Камера:
//   a2=[elem3+0x20] при [a2]==P4: имя «loa» → камера безусловно, «qst» —
//   пропуск, иначе — только если камеры ещё нет. Старые корень/камеру при
//   неудаче не затираем.
static void ESPFindRoots(void)
{
    ESPResolver *r = &gResolver;
    r->lastFail = 0;

    if (!ESPLikePointer(r->P3) && !ESPLikePointer(r->P2)) { r->lastFail = 1; return; }

    uint64_t candidates[10];
    for (int c = 0; c < 10; c++) {
        candidates[c] = ESPRead64(r->base + kCandidateRva[c]);
    }

    uint64_t v1 = ESPRead64(r->base + kRvaRootProbe);
    if (!ESPLikePointer(v1)) { r->lastFail = 2; return; }
    uint64_t v2 = ESPRead64(v1 + 0xB8);
    if (!ESPLikePointer(v2)) { r->lastFail = 2; return; }
    uint64_t v3 = ESPRead64(v2);
    if (!ESPLikePointer(v3)) { r->lastFail = 3; return; }

    uint64_t elements1 = 0;
    uint32_t count1 = 0;
    if (!ESPReadArrayInfo(v3, &elements1, &count1)) { r->lastFail = 3; return; }

    uint64_t foundRoot = 0;
    uint64_t fallbackRoot = 0;
    uint64_t cam = 0;

    for (uint32_t i = 0; i < count1; i++) {
        uint64_t elem1 = ESPRead64(elements1 + i * 8);
        if (!ESPLikePointer(elem1)) { continue; }
        uint64_t z1 = ESPRead64(elem1 + 0x10);
        if (!ESPLikePointer(z1)) { continue; }
        uint64_t z2 = ESPRead64(z1 + 0x18);

        uint64_t elements2 = 0;
        uint32_t count2 = 0;
        if (!ESPReadArrayInfo(z2, &elements2, &count2)) { continue; }

        for (uint32_t j = 0; j < count2; j++) {
            uint64_t elem2 = ESPRead64(elements2 + j * 8);
            if (!ESPLikePointer(elem2)) { continue; }
            if (ESPRead8(elem2 + 0x20) != 0) { continue; }   // ровно один байт
            uint64_t z3 = ESPRead64(elem2 + 0x10);

            uint64_t elements3 = 0;
            uint32_t count3 = 0;
            if (!ESPReadArrayInfo(z3, &elements3, &count3)) { continue; }

            for (uint32_t k = 0; k < count3; k++) {
                uint64_t elem3 = ESPRead64(elements3 + k * 8);
                if (!ESPLikePointer(elem3)) { continue; }
                uint64_t klass = ESPRead64(elem3);   // без проверки — как в оригинале

                if (!foundRoot) {
                    for (int c = 0; c < 10; c++) {
                        if (candidates[c] == 0 || klass != candidates[c]) { continue; }
                        uint64_t v = ESPRead64(elem3 + kCandidateFieldOff[c]);
                        if (!ESPLikePointer(v)) { continue; }
                        uint64_t w = ESPRead64(v);
                        if (w == r->P3 && ESPLikePointer(r->P3)) {
                            foundRoot = v;
                        } else if (w == r->P2 && ESPLikePointer(r->P2)) {
                            if (!fallbackRoot) { fallbackRoot = v; }
                        }
                    }
                }

                uint64_t a2 = ESPRead64(elem3 + 0x20);
                if (!ESPLikePointer(a2)) { continue; }
                if (ESPRead64(a2) == r->P4) {
                    if (ESPClassNameIs(klass, "loa")) {
                        cam = a2;                       // «loa» перезаписывает камеру
                    } else if (!ESPClassNameIs(klass, "qst")) {
                        if (!cam) { cam = a2; }
                    }
                }
            }
        }
    }

    uint64_t root = foundRoot ? foundRoot : fallbackRoot;

    if (ESPLikePointer(cam) && cam != r->camHolder) {
        r->camHolder = cam;
        r->camObj = 0;
        r->matrixReady = 0;
    }

    if (!ESPLikePointer(root)) {
        if (r->lastFail == 0) { r->lastFail = 4; }
        return;
    }
    if (root == r->rootA) { return; }

    // check_27674: [root] == P3 → флаг 0; иначе [root] == P2 → флаг 1.
    if (!ESPCheckRoot(root)) { r->lastFail = 5; return; }

    r->rootA = root;
    r->camObj = 0;
    r->matrixReady = 0;
}

#pragma mark - Резолвер: игроки

// check_27674: корень валиден по классу: [root] == P3 → флаг 0; иначе
// [root] == P2 → флаг 1; иначе/при невалидном статике — 0.
static int ESPCheckRoot(uint64_t root)
{
    ESPResolver *r = &gResolver;
    if (!ESPLikePointer(root)) { return 0; }
    uint64_t klass = ESPRead64(root);
    if (klass == r->P3 && ESPLikePointer(r->P3)) { r->rootFlag = 0; return 1; }
    if (klass == r->P2 && ESPLikePointer(r->P2)) { r->rootFlag = 1; return 1; }
    return 0;
}

// validate_275a4: цепочка списка игроков от корня:
//   owner = [root + (флаг ? 0x50 : 0x40)] → [owner+0x30] → [..+0x18] → [..+0x10];
//   годен, если не (countA ≤ countB и ((countA-1)|(countB-1)) ≥ 0x2000).
static int ESPValidateRoot(uint64_t root)
{
    ESPResolver *r = &gResolver;
    uint64_t t1 = ESPRead64(root + (r->rootFlag ? 0x50 : 0x40));
    if (!ESPLikePointer(t1)) { return 0; }
    uint64_t t2 = ESPRead64(t1 + 0x30);
    if (!ESPLikePointer(t2)) { return 0; }
    uint64_t t3 = ESPRead64(t2 + 0x18);
    if (!ESPLikePointer(t3)) { return 0; }
    uint64_t t4 = ESPRead64(t3 + 0x10);
    if (!ESPLikePointer(t4)) { return 0; }

    uint32_t countA = ESPRead32(t3 + 0x18);
    uint32_t countB = ESPRead32(t4 + 0x18);
    if (countA <= countB) {
        uint32_t merged = (countA - 1u) | (countB - 1u);
        if (merged >= 0x2000u) { return 0; }
    }
    return 1;
}

// Ежетиковая проверка кэшированного корня (f_update): check_27674 + validate_275a4.
static int ESPRootStillValid(void)
{
    if (!ESPLikePointer(gResolver.rootA)) { return 0; }
    if (!ESPCheckRoot(gResolver.rootA)) { return 0; }
    return ESPValidateRoot(gResolver.rootA);
}

// Список игроков (порт f_27ed0): owner = [rootA + (флаг ? 0x50 : 0x40)];
// t2 = [owner+0x30]; t3 = [t2+0x18]; items = [t3+0x10];
// count = u32@(t3+0x18) ∈ [1,0x800]; игрок = u64@(u64@(items+0x20+i*8)).
// Свои пропускаются по P1; если P1 нет — фильтр здоровья u8@(obj+0x90) ∈ [1,32];
// без дублей, не больше 64.
static int ESPBuildPlayerList(uint64_t *outObjects, int capacity)
{
    ESPResolver *r = &gResolver;
    if (!ESPLikePointer(r->rootA)) { return -1; }

    uint64_t owner = ESPRead64(r->rootA + (r->rootFlag ? 0x50 : 0x40));
    if (!ESPLikePointer(owner)) { return -2; }
    uint64_t t2 = ESPRead64(owner + 0x30);
    if (!ESPLikePointer(t2)) { return -2; }
    uint64_t t3 = ESPRead64(t2 + 0x18);
    if (!ESPLikePointer(t3)) { return -2; }
    uint64_t items = ESPRead64(t3 + 0x10);
    if (!ESPLikePointer(items)) { return -3; }
    uint32_t count = ESPRead32(t3 + 0x18);
    if (count < 1 || count > 0x800) { return -3; }

    r->listVariant = 1;
    r->nEntries = count;

    int outCount = 0;
    uint32_t rejected = 0;
    uint64_t seen[64];
    int seenCount = 0;

    for (uint32_t i = 0; i < count; i++) {
        uint64_t raw = ESPRead64(items + 0x20 + (uint64_t)i * 8);
        if (!ESPLikePointer(raw)) { rejected++; continue; }
        uint64_t obj = ESPRead64(raw);          // двойное разыменование
        if (!ESPLikePointer(obj)) { rejected++; continue; }

        if (ESPLikePointer(r->P1)) {
            if (obj == r->P1) { rejected++; continue; }
        } else {
            uint32_t health = ESPRead8(obj + kOffHealth);
            if (health < 1 || health > 32) { rejected++; continue; }
        }

        int duplicate = 0;
        for (int s = 0; s < seenCount; s++) {
            if (seen[s] == obj) { duplicate = 1; break; }
        }
        if (duplicate) { continue; }
        if (seenCount < 64) { seen[seenCount++] = obj; }

        outObjects[outCount++] = obj;
        if (outCount >= capacity || outCount >= 64) { break; }
    }

    r->nRejected = rejected;
    return outCount;
}

// Моя команда: u8@(u64@(u64@(rootA+0xC0)+0xB0)+0x13) — только для корня P3
// (флаг 0). При корне P2 фильтр команды выключен (selfTeam = 0).
static uint32_t ESPMyTeam(void)
{
    if (gResolver.rootFlag != 0) { return 0; }
    uint64_t a = ESPRead64(gResolver.rootA + 0xC0);
    if (!ESPLikePointer(a)) { return 0; }
    uint64_t b = ESPRead64(a + 0xB0);
    if (!ESPLikePointer(b)) { return 0; }
    return ESPRead8(b + 0x13);
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

// Проверка позиции (f_2b7cc): не (0,0,0), всё конечно, max(|x|,|y|,|z|) ≤ 20000.
static int ESPPosValid(const float p[3])
{
    if (p[0] == 0.0f && p[1] == 0.0f && p[2] == 0.0f) { return 0; }
    for (int i = 0; i < 3; i++) {
        if (!isfinite(p[i])) { return 0; }
    }
    float m = fabsf(p[0]);
    if (fabsf(p[1]) > m) { m = fabsf(p[1]); }
    if (fabsf(p[2]) > m) { m = fabsf(p[2]); }
    return m <= 20000.0f ? 1 : 0;
}

// Позиция мира из Transform (порт get_position_by_transform_with):
//   P = [transform+0x10]; arr = [P+0x28]; index = u32@(P+0x30);
//   nodes = [arr+0x18] (TRS-записи по 48 байт), parents = [arr+0x20] (индексы);
//   acc = своя позиция; далее ≤50 раз: acc = parent.pos + parent.quat ×
//   (parent.scale ⊙ acc); индекс < 0 — стоп.
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
    ESPRead48(ptrB + (uint64_t)index * kOffNodeStride, entry);
    if (!ESPVecFinite1e5(entry) || !ESPQuatOk(entry + 3) || !ESPScaleOk(entry + 7)) { return 0; }

    float ax = entry[0], ay = entry[1], az = entry[2];
    uint32_t parent = ESPRead32(ptrC + (uint64_t)index * 4);

    for (int iter = 50; iter > 0 && (parent & 0x80000000u) == 0; iter--) {
        float e[12];
        ESPRead48(ptrB + (uint64_t)parent * kOffNodeStride, e);
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

// Компоненты игрока (f_2b854): a = [obj+0x28]; b = [a+0x10];
// elements = [b+0x10]; count = u32@(b+0x18) ∈ [1,64].
static int ESPComponentElements(uint64_t obj, uint64_t *outElements, uint32_t *outCount)
{
    uint64_t a = ESPRead64(obj + kOffComponents);
    if (a < 0x1000001ull) { return 0; }
    uint64_t b = ESPRead64(a + 0x10);
    if (b < 0x1000001ull) { return 0; }
    uint64_t elements = ESPRead64(b + 0x10);
    if (elements < 0x1000001ull) { return 0; }
    uint32_t count = ESPRead32(b + 0x18);
    if (count < 1 || count > kMaxComponents) { return 0; }
    *outElements = elements;
    *outCount = count;
    return 1;
}

// Позиция по компоненту (f_2b6f8): трансформ по [comp+0x28], иначе по [comp+0x30].
static int ESPPositionFromComponent(uint64_t comp, float out[3])
{
    uint64_t t = ESPRead64(comp + 0x28);
    if (t >= 0x1000001ull && ESPPositionFromTransform(t, out) && ESPPosValid(out)) { return 1; }
    t = ESPRead64(comp + 0x30);
    if (t >= 0x1000001ull && ESPPositionFromTransform(t, out) && ESPPosValid(out)) { return 1; }
    return 0;
}

// Позиция игрока (порт f_2840c): сначала компонент с klass == K1 → трансформ
// из [comp+0x28] → обход родителей; затем любой компонент через f_2b6f8.
static int ESPPositionForPlayer(uint64_t obj, float out[3])
{
    uint64_t elements = 0;
    uint32_t count = 0;
    if (!ESPComponentElements(obj, &elements, &count)) { return 0; }

    if (ESPLikePointer(gResolver.K1)) {
        for (uint32_t i = 0; i < count; i++) {
            uint64_t comp = ESPRead64(elements + 0x20 + (uint64_t)i * 8);
            if (!ESPLikePointer(comp)) { continue; }
            if (ESPRead64(comp) != gResolver.K1) { continue; }
            uint64_t t = ESPRead64(comp + 0x28);
            if (!ESPLikePointer(t)) { continue; }
            if (ESPPositionFromTransform(t, out) && ESPPosValid(out)) { return 1; }
        }
    }

    for (uint32_t i = 0; i < count; i++) {
        uint64_t comp = ESPRead64(elements + 0x20 + (uint64_t)i * 8);
        if (!ESPLikePointer(comp)) { continue; }
        if (ESPPositionFromComponent(comp, out)) { return 1; }
    }
    return 0;
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
    double espSwitch = AscentSharedNumber(@"cheat.esp");

    // Диагностика в журнал: видно и тумблер, и доступ, и каталог состояния.
    // Пишем на первом проходе и дальше не чаще раза в 2 с.
    {
        static uint64_t sLastDiagUs = 0;
        uint64_t diagNow = ESPNowUs();
        if (sLastDiagUs == 0 || diagNow - sLastDiagUs >= 2000000ull) {
            sLastDiagUs = diagNow;
            AscentHUDLog(@"[esp] тик: cheat.esp=%.1f, attached=%d, base=0x%llx, каталог=%s",
                         espSwitch, AscentGameIsAttached(), gResolver.base,
                         AscentStateDirectory().UTF8String);
        }
    }

    if (espSwitch <= 0.5) {
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

    // 2) Корень и камера. Каждый тик кэшированный корень перепроверяется
    // (f_update: check_27674 + validate_275a4); при провале — полный поиск.
    if (ESPLikePointer(r->rootA) && !ESPRootStillValid()) {
        r->rootA = 0;
        r->camObj = 0;
        r->matrixReady = 0;
    }
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

        float pos[3];
        if (!ESPPositionForPlayer(obj, pos)) { continue; }

        uint32_t team = ESPRead8(obj + kOffTeam);
        uint32_t health = ESPRead8(obj + kOffHealth);

        CGPoint feet;
        CGPoint headPoint;
        float depth = 0.0f;
        float headPos[3] = {pos[0], pos[1] + 1.75f, pos[2]};
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
             r->rootFlag, r->matrixSource == 1 ? "быстрая" : "P×V",
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
