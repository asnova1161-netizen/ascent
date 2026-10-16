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
/// NO  — погасить HUD-процесс.
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

#pragma mark - Диагностика запуска оверлея

/// Записать строку в журнал оверлея (его читает главное приложение и
/// показывает, если HUD почему-то не поднялся).
void AscentHUDLogMessage(NSString *message);
void AscentHUDLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// То же самое, но без форматирования/ObjC — пригодно для обработчиков
/// сигналов (падение HUD-процесса).
void AscentHUDLogRaw(const char *text);

/// Очистить журнал (перед новым запуском оверлея).
void AscentHUDLogReset(void);

/// Прочитать журнал целиком.
NSString *AscentHUDLogText(void);

#ifdef __cplusplus
}
#endif
