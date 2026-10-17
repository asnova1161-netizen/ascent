#import <UIKit/UIKit.h>

/// Квадратик-триггер и панель мод-меню для HUD-процесса.
///
/// Раньше это был SwiftUI (UIHostingController), но в HUD-процессе SwiftUI не
/// рисовался: окно показывалось (диагностическая метка была видна), а контент
/// нет. Эталонные оверлеи (TrollSpeed, PastaWare) делают HUD на чистом UIKit —
/// так и здесь: никаких SwiftUI и никаких резолвов Swift-классов через runtime.
///
/// Вью вешается прямо на окно HUD-процесса (тот же путь, что и метка, которая
/// гарантированно рисовалась).
@interface HUDOverlayView : UIView

/// Создать оверлей на всё окно (размер берётся из окна, дальше — autoresizing).
+ (instancetype)overlayForWindow:(UIWindow *)window;

/// Единственный живой оверлей процесса (его же держит окно HUD). Нужен, чтобы
/// поток HID-событий (HUDApp.mm) мог отдать касание напрямую, минуя окно.
+ (instancetype)currentOverlay;

/// Касание из общего потока HID-событий. Accessibility-окно касаний от
/// window-сервера не получает, поэтому движение квадрата, панели и прокрутка
/// вкладки ведутся прямо от этих точек: на синтетических UITouch (KIF)
/// распознаватели движения срабатывают ненадёжно, а обычный тап работает.
- (void)handleRawTouchPhase:(UITouchPhase)phase
                 atLocation:(CGPoint)location
                   inWindow:(UIWindow *)window;

@end
