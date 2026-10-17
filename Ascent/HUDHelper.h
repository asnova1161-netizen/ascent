#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Запущен ли сейчас процесс-оверлей (HUD).
///
/// Проверяем напрямую по PID-файлу: `kill(pid, 0)` возвращает 0, если процесс
/// жив, и EPERM, если он жив, но принадлежит другому пользователю (HUD бежит
/// от root). Раньше проверка порождала вспомогательный процесс, и любая беда
/// с `posix_spawn` делала оверлей «неживым» даже когда он работал.
BOOL IsHUDEnabled(void);

/// Включить/выключить оверлей.
///
/// YES — поднять HUD-процесс (если он ещё не запущен, без дублей).
/// NO  — погасить HUD-процесс и удалить PID-файл.
void SetHUDEnabled(BOOL isEnabled);

NSUserDefaults *GetStandardUserDefaults(void);

/// Каталог общих файлов состояния оверлея (позиции квадрата/панели + журнал).
///
/// В главном процессе это контейнер приложения. В HUD-процессе (он бежит от
/// root, у него свой «дом») путь передаётся аргументом из главного процесса,
/// иначе root смотрел бы в /var/root и не нашёл бы общих файлов.
NSString *AscentStateDirectory(void);
void AscentSetStateDirectory(NSString *dir);

/// Путь к PID-файлу HUD-процесса.
NSString *AscentPIDFilePath(void);

/// Удалить PID-файл (перед выходом HUD-процесса).
void AscentRemovePIDFile(void);

/// PID процесса-оверлея из PID-файла (0, если файла нет или он пуст).
pid_t AscentHUDProcessID(void);

/// Состояние процесса-оверлея человеческим языком: «жив (состояние 2)»,
/// «ЗОМБИ — процесс уже завершился», «мёртв», «PID-файла нет».
///
/// Нужно потому, что `kill(pid, 0)` считает живым и зомби — процесс, который
/// уже завершился, но не был пойман родителем. Снаружи это выглядит как
/// работающий оверлей с пустым экраном.
NSString *AscentHUDProcessState(void);

#pragma mark - Журнал

/// Записать строку в журнал оверлея.
void AscentHUDLogMessage(NSString *message);
void AscentHUDLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// То же самое, но без форматирования/ObjC — пригодно для обработчиков
/// сигналов (падение HUD-процесса).
void AscentHUDLogRaw(const char *text);

/// Метка процесса в журнале: "[HUD] ", "[check] " и т.п.
void AscentSetLogPrefix(NSString *prefix);

/// Очистить журнал (перед новым запуском оверлея).
void AscentHUDLogReset(void);

/// Прочитать журнал целиком.
NSString *AscentHUDLogText(void);

/// Последние `maxLines` строк журнала.
NSString *AscentHUDLogTail(int maxLines);

#pragma mark - Диагностика запуска

/// В каком режиме запущен ЭТОТ процесс: "app", "-hud", "-check", "-exit".
NSString *AscentProcessMode(void);
void AscentSetProcessMode(NSString *mode);

/// Результат последнего posix_spawn (для отладочного окна).
int AscentLastSpawnReturnCode(void);
int AscentLastSpawnErrno(void);
pid_t AscentLastSpawnPID(void);
NSString *AscentLastSpawnMode(void);

/// Отчёт «какие приватные символы и классы резолвятся» (список ok/нет).
NSString *AscentProbeReport(void);
BOOL AscentProbeSymbol(const char *name);
BOOL AscentProbeClass(const char *name);

/// Какие entitlements реально лежат в подписи этого бинарника (или nil).
NSString *AscentOwnEntitlements(void);

#ifdef __cplusplus
}
#endif
