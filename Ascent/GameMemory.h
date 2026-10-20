//
//  GameMemory.h
//  Ascent
//
//  Доступ к памяти чужой игры (Standoff 2) из HUD-процесса.
//
//  Зачем это в отдельном процессе: task-порт чужого приложения берётся
//  только у процесса, который бежит от root и/или имеет право
//  task_for_pid-allow. Обычное приложение этого не может, а HUD-процесс —
//  может (он поднимается через posix_spawn с персоной root, см. HUDHelper).
//
//  Здесь только «фундамент»: найти процесс, взять task-порт, найти базу
//  главного модуля, читать/писать память и искать байтовые шаблоны.
//  Смещения конкретной игры задаются сверху — этот файл про них не знает.
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Найти PID процесса, в имени которого встречается `nameHint` (без регистра).
/// Возвращает -1, если не найден. Работает без прав: только sysctl.
int AscentGameFindProcess(NSString *nameHint);

/// Найти процесс и взять на него task-порт. Раскладывает базу/размер
/// главного модуля. YES — доступ есть.
BOOL AscentGameAttach(NSString *nameHint);

/// Отпустить task-порт.
void AscentGameDetach(void);

BOOL AscentGameIsAttached(void);
int AscentGamePid(void);
uint64_t AscentGameModuleBase(void);
uint64_t AscentGameModuleSize(void);

/// task-порт привязанного процесса (MACH_PORT_NULL, если не привязаны).
/// Нужен диагностике для перебора регионы памяти (vm_region_64). Снаружи им
/// пользоваться аккуратно: это «ключ» к чужому адресному пространству.
mach_port_t AscentGameTask(void);

/// Чтение/запись памяти удалённого процесса.
BOOL AscentGameRead(uint64_t address, void *buffer, size_t length);
BOOL AscentGameWrite(uint64_t address, const void *buffer, size_t length);

/// Поиск шаблона в диапазоне [start, start+length).
///
/// `mask` — строка той же длины, что и шаблон: 'x' — байт должен совпасть,
/// '?' — байт игнорируется (например "48 8b ?? 0d" -> "xx?x").
/// Возвращает адрес первого совпадения или 0.
uint64_t AscentGameScanPattern(uint64_t start, uint64_t length,
                               const void *pattern, const char *mask);

/// Статус человеческим языком (для меню и журнала).
NSString *AscentGameStatus(void);

/// Только доложить в журнал, запущен ли процесс (без взятия task-порта).
void AscentGameReportProcess(NSString *nameHint);

/// Найти процесс и взять task-порт, всё записать в журнал.
void AscentGameProbe(NSString *nameHint);

/// Периодическая работа: читает переключатели из общего файла оверлея
/// (cheat.esp / cheat.aimbot) и держит task-порт в
/// соответствии с ними. Вызывается таймером из HUD-процесса.
void AscentGameTick(void);

#ifdef __cplusplus
}
#endif
