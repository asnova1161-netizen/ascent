#import <Foundation/Foundation.h>

/// Запущен ли сейчас процесс-оверлей (HUD).
BOOL IsHUDEnabled(void);

/// Включить/выключить оверлей.
///
/// YES — поднять HUD-процесс (если он ещё не запущен, без дублей).
/// NO  — погасить HUD-процесс.
void SetHUDEnabled(BOOL isEnabled);

NSUserDefaults *GetStandardUserDefaults(void);

/// Каталог общих файлов состояния оверлея (PID и позиции квадрата/панели).
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
