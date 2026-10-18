#import "HUDOverlayView.h"
#import "HUDHelper.h"
#import "GameMemory.h"
#import "GameESP.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <math.h>
#import <string.h>

#pragma mark - Общий файл оверлея (тот же, что пишет приложение)

static NSString *const kHUDOverlayFile = @"ascent.overlay.plist";

static NSString *HUDOverlayPath(void)
{
    NSString *dir = AscentStateDirectory();
    if (dir.length == 0) { dir = NSTemporaryDirectory(); }
    return [dir stringByAppendingPathComponent:kHUDOverlayFile];
}

static NSMutableDictionary *HUDOverlayDict(void)
{
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:HUDOverlayPath()];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static void HUDOverlayWrite(NSMutableDictionary *dict)
{
    NSString *path = HUDOverlayPath();
    [dict writeToFile:path atomically:YES];
    chmod([path fileSystemRepresentation], 0666);
}

static double HUDOverlayNumber(NSString *key, double fallback)
{
    NSNumber *value = HUDOverlayDict()[key];
    return [value isKindOfClass:[NSNumber class]] ? value.doubleValue : fallback;
}

static void HUDOverlaySetNumber(NSString *key, double value)
{
    NSMutableDictionary *dict = HUDOverlayDict();
    dict[key] = @(value);
    HUDOverlayWrite(dict);
}

static BOOL HUDOverlayFlag(NSString *key, BOOL fallback)
{
    return HUDOverlayNumber(key, fallback ? 1 : 0) > 0.5;
}

/// Значение по умолчанию для строки меню. У опций ESP, включённых по умолчанию,
/// fallback YES — иначе меню показывало бы «выключено», а холст ESP рисовал бы
/// боксы: переключатель и картинка разошлись бы.
static BOOL HUDSwitchDefault(NSString *key)
{
    if ([key isEqualToString:@"esp.box"] ||
        [key isEqualToString:@"esp.health"] ||
        [key isEqualToString:@"esp.name"] ||
        [key isEqualToString:@"esp.distance"]) {
        return YES;
    }
    return NO;
}

static void HUDOverlaySetFlag(NSString *key, BOOL value)
{
    HUDOverlaySetNumber(key, value ? 1 : 0);
}

#pragma mark - Оформление

static UIColor *HUDColor(double r, double g, double b)
{
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

static UIColor *HUDFill(void)      { return HUDColor(0.145, 0.145, 0.160); }
static UIColor *HUDCard(void)      { return HUDColor(0.075, 0.075, 0.085); }
static UIColor *HUDAccent(void)    { return HUDColor(0.91, 0.17, 0.19); }
static UIColor *HUDLine(void)      { return [UIColor colorWithWhite:1.0 alpha:0.12]; }
static UIColor *HUDDim(void)       { return [UIColor colorWithWhite:1.0 alpha:0.55]; }
static UIColor *HUDGray(void)      { return HUDColor(0.36, 0.36, 0.40); }

// Зелёный для «своих» в ESP и для полоски здоровья.
static UIColor *HUDGreen(void)     { return HUDColor(0.22, 0.78, 0.36); }

static UILabel *HUDLabel(NSString *text, CGFloat size, UIFontWeight weight)
{
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor clearColor];
    return label;
}

static UIView *HUDRoundedBox(CGFloat radius, UIColor *fill)
{
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = fill;
    view.layer.cornerRadius = radius;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = HUDLine().CGColor;
    return view;
}

/// Иконка квадратика. Размер/вес ровно как у SwiftUI-версии в приложении
/// (`.font(.system(size: 20, weight: .bold))`), иначе при передаче эстафеты от
/// квадрата в приложении к квадрату HUD иконка «толстела/худела» на глазах.
static UIImage *HUDTriggerImage(BOOL open)
{
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightBold];
    return [UIImage systemImageNamed:(open ? @"xmark" : @"slider.horizontal.3") withConfiguration:config];
}

#pragma mark - Ориентация

// Окно HUD всегда портретное (см. HUDRootViewController.supportedInterfaceOrientations).
// Чтобы квадрат и панель стояли «ровно» при любом положении устройства, весь
// контент лежит в отдельном слое _stage, который мы сами поворачиваем — так же
// делает TrollSpeed.
static CGFloat HUDOrientationAngle(UIInterfaceOrientation orientation)
{
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown: return M_PI;
        case UIInterfaceOrientationLandscapeLeft:      return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:     return M_PI_2;
        default:                                       return 0;
    }
}

static CGRect HUDOrientationBounds(UIInterfaceOrientation orientation, CGRect bounds)
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return CGRectMake(0, 0, bounds.size.height, bounds.size.width);
        default:
            return bounds;
    }
}

/// Приватный FBSOrientationObserver. Заголовков у нас нет, поэтому объявляем
/// только то, что вызываем; ориентацию из апдейта читаем через KVC.
@protocol HUDOrientationObserving <NSObject>
- (void)setHandler:(void (^)(id update))handler;
- (void)invalidate;
@end

#pragma mark - Оверлей

static const CGFloat kTriggerSide    = 54.0;
// Меню ГОРИЗОНТАЛЬНОЕ: расходится влево-вправо, ширина больше высоты. Габарит
// задаём ДИАПАЗОНОМ, а не жёстко: в ландшафте высота сцены всего ≈375 pt минус
// безопасные зоны, поэтому высокая панель уходила за верх экрана. Фактический
// размер считает panelSizeForArea: — он же держит пропорцию горизонтальной.
static const CGFloat kPanelWidthMax  = 340.0;   // ширина меню
static const CGFloat kPanelHeightMax = 240.0;   // высота меню (влезает и в ландшафт)
static const CGFloat kHeaderHeight   = 46.0;

// Тайминги жеста. AX/HID-поток на iOS 15 часто теряет событие «подъём», и без
// жёсткого контроля старое начало жеста оставалось бы висеть навсегда: следующее
// движение считалось протяжкой ОТ старой точки, и квадрат/панель прыгали назад —
// ровно на то место, где они появились. Жест жив, только пока по нему идут
// события и только ограниченное время.
static const NSTimeInterval kRawGestureStale    = 0.40;  // пауза, после которой жест протух
static const NSTimeInterval kRawGestureLifetime = 2.50;  // предельная длина одного жеста
static const NSTimeInterval kRawTapDebounce     = 0.12;  // гасит повторный «подъём» одного тапа
// Предел одного шага пальца между событиями, в точках. Поток HID иногда
// присылает событие движения с координатами ЧУЖОГО касания (остаток прошлого
// жеста) — это скачок на сотни точек за один кадр. Настоящий палец столько не
// проходит (120 pt за 16 мс — это 7500 pt/с), поэтому такой шаг считается
// мусором: элемент не двигается, жест просто перебазируется.
static const CGFloat kRawJumpLimit = 120.0;
// ПЕРЕНОС квадрата и панели. Раньше он ждал 0.25 с и перебазировался на точку
// старта — из-за этого элемент таскался «с задержкой» и отставал от пальца.
// Теперь удержание короткое, а перенос ведётся строго за пальцем один к одному.
// Перенос включается, если палец задержался на kRawDragHold ИЛИ сразу ушёл на
// kRawDragArmMove: нажатие короткое и почти без движения, поэтому переносом не
// становится.
static const NSTimeInterval kRawDragHold   = 0.10;
static const CGFloat kRawDragArmMove       = 18.0;
// Если за весь жест палец прошёл меньше этого, жест считается НАЖАТИЕМ:
// элемент возвращается ровно на место, где был в момент нажатия.
static const CGFloat kRawTapSlop           = 14.0;

// Раскладка панели в стиле «карточки»: слева колонка вкладок, справа тёмная
// карточка содержимого с заголовком раздела. Числа одни и те же для сборки и
// раскладки, поэтому они — константы. Вкладки держим плотными, как на макете.
static const CGFloat kSidebarWidth   = 60.0;    // ширина колонки вкладок
static const CGFloat kTabRowHeight   = 31.0;    // высота строки вкладки
static const CGFloat kCardInset      = 8.0;     // отступ карточки от края панели
static const CGFloat kSectionTop     = 32.0;    // высота полосы заголовка раздела
static const CGFloat kMargin         = 10.0;
static const CGFloat kTriggerInset   = 14.0;

// Высота вкладок: строка переключателя, строка слайдера и содержимое вкладки
// «combot». Держим константами, потому что одни и те же числа нужны и сборке
// строк, и раскладке, и размеру прокручиваемой области.
static const CGFloat kSwitchRowHeight  = 40.0;
static const CGFloat kSwitchRowGap     = 8.0;
static const CGFloat kSliderGroupHeight = 40.0;
static const CGFloat kSliderGroupGap   = 6.0;

// Что тянет палец в потоке касаний (см. handleRawTouchPhase:...).
typedef NS_ENUM(NSInteger, HUDRawDragTarget) {
    HUDRawDragNone = 0,
    HUDRawDragTrigger,
    HUDRawDragPanel,
    HUDRawDragScroll,
    // Управляемый элемент (кнопка, строка переключателя, слайдер, вкладка):
    // пока палец почти не сдвинулся — это ТАП, и только при явной протяжке
    // жест превращается в прокрутку. Без этого порога дрожь руки при нажатии
    // уводила бы содержимое, и кнопки «не нажимались».
    HUDRawDragControl,
};

// Единственный живой оверлей процесса (см. +currentOverlay). Ссылку держим
// статиком: владеет оверлеем окно HUD, а статик нужен лишь чтобы поток
// HID-событий мог найти оверлей, не перебирая окна. Процесс одноразовый, так
// что держать оверлей до конца жизни процесса можно.
static HUDOverlayView *_hudCurrentOverlay = nil;

#pragma mark - Рисование ESP

// Холст для ESP: лежит в _stage ПОД квадратом и панелью, поэтому боксы игроков
// не перекрывают меню и поворачиваются вместе с экраном. Память игры читает
// отдельный поток (GameESP.mm) — здесь только снимок кадра и краска.
@interface AscentESPHostView : UIView
@end

@implementation AscentESPHostView
{
    NSTimer *_timer;
    int      _lastFrameId;
    BOOL     _lastLive;
    // Переключатели рисования. Кэшируем: файл читаем раз в полсекунды, а не
    // на каждом кадре, иначе прокрутка/рисование заметно подрагивают.
    BOOL     _drawBox;
    BOOL     _drawHealth;
    BOOL     _drawName;
    BOOL     _drawDistance;
    BOOL     _drawSnapline;
    BOOL     _drawTeammates;
    NSTimeInterval _optionsTime;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self == nil) { return nil; }
    self = [super initWithFrame:frame];
    if (self == nil) { return nil; }

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    // Холст не должен ловить касания: иначе ESP-слой перехватывал бы тапы,
    // предназначенные квадрату и панели.
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self reloadOptions];

    // 15 раз в секунду — столько же кадров читает GameESP; лишние setNeedsDisplay
    // отсекаем по номеру кадра.
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15.0
                                              target:self
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (void)dealloc
{
    [_timer invalidate];
}

/// Переключатели ESP лежат в общем plist — те же ключи, что пишет меню.
- (void)reloadOptions
{
    _drawBox      = HUDOverlayNumber(@"esp.box", 1) > 0.5;
    _drawHealth   = HUDOverlayNumber(@"esp.health", 1) > 0.5;
    _drawName     = HUDOverlayNumber(@"esp.name", 1) > 0.5;
    _drawDistance  = HUDOverlayNumber(@"esp.distance", 1) > 0.5;
    _drawSnapline = HUDOverlayNumber(@"esp.snapline", 0) > 0.5;
    _drawTeammates = HUDOverlayNumber(@"esp.teammates", 0) > 0.5;
}

- (void)tick
{
    // Видимость ESP зависит от переключателя в меню: прячем холст целиком,
    // чтобы не тратить рисование, когда чит выключен.
    BOOL enabled = HUDOverlayNumber(@"cheat.esp", 0) > 0.5;
    if (!enabled) {
        if (self.hidden == NO && self.alpha > 0.0f) {
            self.hidden = YES;
        }
        return;
    }
    if (self.hidden) {
        self.hidden = NO;
    }

    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (now - _optionsTime > 0.5) {
        _optionsTime = now;
        [self reloadOptions];
    }

    AscentESPFrame info;
    memset(&info, 0, sizeof(info));
    AscentESPGetFrame(NULL, 0, &info);

    // Перерисовываем только когда пришёл новый кадр — иначе таймер гонял бы
    // drawRect впустую и грел экран.
    if (info.frameId != _lastFrameId || info.live != _lastLive) {
        _lastFrameId = info.frameId;
        _lastLive = info.live;
        [self setNeedsDisplay];
    }
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == nil) { return; }

    AscentESPPlayer players[kAscentESPMaxPlayers];
    AscentESPFrame info;
    memset(&info, 0, sizeof(info));
    int count = AscentESPGetFrame(players, kAscentESPMaxPlayers, &info);
    if (count <= 0 || !info.live) { return; }

    CGRect bounds = self.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    if (width <= 1.0 || height <= 1.0) { return; }

    UIFont *font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];

    for (int i = 0; i < count; i++) {
        AscentESPPlayer player = players[i];
        if (player.screen.x < -0.5f || player.screen.y < -0.5f) { continue; }
        if (player.screen.x < -0.15f || player.screen.x > 1.15f ||
            player.screen.y < -0.15f || player.screen.y > 1.15f) {
            continue;
        }

        // Своих не подсвечиваем, если переключатель выключен.
        BOOL teammate = (info.pid > 0) && (player.team == 0);
        if (teammate && !_drawTeammates) { continue; }

        CGFloat centerX = bounds.origin.x + player.screen.x * width;
        CGFloat centerY = bounds.origin.y + player.screen.y * height;

        CGFloat boxH = player.boxHeight * height;
        if (boxH < 12.0) { boxH = 12.0; }
        if (boxH > height * 0.8) { boxH = height * 0.8; }
        CGFloat boxW = boxH * 0.45;

        CGRect box = CGRectMake(centerX - boxW / 2.0, centerY - boxH / 2.0, boxW, boxH);

        // Цвет: враг красный, свой зелёный. Если команды не прочитали —
        // считаем врагом, ESP для врагов и сделан.
        UIColor *lineColor = teammate ? HUDGreen() : HUDAccent();

        if (_drawSnapline) {
            CGContextSetStrokeColorWithColor(context, lineColor.CGColor);
            CGContextSetLineWidth(context, 1.0);
            CGContextMoveToPoint(context, bounds.origin.x + width / 2.0, bounds.origin.y + height);
            CGContextAddLineToPoint(context, centerX, CGRectGetMaxY(box));
            CGContextStrokePath(context);
        }

        if (_drawBox) {
            CGContextSetStrokeColorWithColor(context, lineColor.CGColor);
            CGContextSetLineWidth(context, 1.5);
            // Тень даёт читаемость на светлой карте: обводка всегда видна.
            CGContextSetShadowWithColor(context, CGSizeMake(0, 0), 2.0,
                                        [UIColor colorWithWhite:0 alpha:0.85].CGColor);
            CGContextStrokeRect(context, box);
            CGContextSetShadowWithColor(context, CGSizeZero, 0, [UIColor clearColor].CGColor);
        }

        // Полоска здоровья слева от бокса.
        if (_drawHealth && player.health >= 0.0f) {
            CGFloat ratio = player.health / 100.0f;
            if (ratio > 1.0f) { ratio = 1.0f; }
            if (ratio < 0.0f) { ratio = 0.0f; }

            CGRect track = CGRectMake(CGRectGetMinX(box) - 5.0, CGRectGetMinY(box),
                                      3.0, boxH);
            CGRect fill = CGRectMake(CGRectGetMinX(box) - 5.0,
                                     CGRectGetMaxY(box) - boxH * ratio,
                                     3.0, boxH * ratio);

            CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
            CGContextFillRect(context, track);
            CGContextSetFillColorWithColor(context, HUDGreen().CGColor);
            CGContextFillRect(context, fill);
        }

        if (_drawName && player.name[0] != '\0') {
            NSString *name = [NSString stringWithUTF8String:player.name];
            if (name.length > 0) {
                NSDictionary *attributes = @{
                    NSFontAttributeName: font,
                    NSForegroundColorAttributeName: [UIColor whiteColor]
                };
                CGSize size = [name sizeWithAttributes:attributes];
                CGPoint origin = CGPointMake(centerX - size.width / 2.0,
                                             CGRectGetMinY(box) - size.height - 2.0);
                NSDictionary *shadow = @{
                    NSFontAttributeName: font,
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:0 alpha:0.85]
                };
                [name drawAtPoint:CGPointMake(origin.x, origin.y + 1) withAttributes:shadow];
                [name drawAtPoint:origin withAttributes:attributes];
            }
        }

        if (_drawDistance && player.distance >= 0) {
            NSString *text = [NSString stringWithFormat:@"%d m", player.distance];
            NSDictionary *attributes = @{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: HUDAccent()
            };
            CGSize size = [text sizeWithAttributes:attributes];
            CGPoint origin = CGPointMake(centerX - size.width / 2.0, CGRectGetMaxY(box) + 2.0);
            [text drawAtPoint:origin withAttributes:attributes];
        }
    }
}

@end

// Делегат прокрутки нужен только ради журнала: по нему видно, начиналась ли
// прокрутка меню и дожила ли она до конца.
@interface HUDOverlayView () <UIScrollViewDelegate>
@end

@implementation HUDOverlayView
{
    // Слой, который поворачивается вслед за устройством: в нём лежат квадрат и
    // панель. Само вью оверлея остаётся ровным контейнером на всё окно.
    UIView *_stage;
    // Холст ESP: первый в _stage, поэтому боксы игроков лежат ПОД квадратом и
    // панелью и не мешают меню.
    AscentESPHostView *_espView;
    UIInterfaceOrientation _orientation;
    id<HUDOrientationObserving> _orientationObserver;
    BOOL _usesDeviceOrientationFallback;

    // Квадратик-триггер
    UIView *_trigger;
    UIImageView *_triggerIcon;
    CAGradientLayer *_triggerGradient;
    CGSize _triggerOffset;          // сохранённое смещение от базовой позиции

    // Панель
    UIView *_panel;
    UIView *_panelHeader;
    UILabel *_panelTitle;
    NSMutableArray<UIButton *> *_tabButtons;
    UIView *_tabIndicator;        // красная полоска у выбранной вкладки
    UIView *_contentCard;         // тёмная карточка справа
    UILabel *_sectionTitle;       // заголовок раздела внутри карточки
    UIScrollView *_scroll;
    UIButton *_unloadButton;
    UILabel *_gameProcLabel;
    UILabel *_miscCaption;
    UILabel *_configCaption;
    NSMutableArray<UISwitch *> *_switches;
    NSMutableArray<UISlider *> *_sliders;
    NSMutableDictionary<NSString *, UILabel *> *_sliderValueLabels;
    // Статус чтения игры на вкладке ESP и таймер, его обновляющий.
    UILabel *_espStatusLabel;
    NSTimer *_espStatusTimer;
    CGSize _panelOffset;
    BOOL _panelOpen;
    NSInteger _tab;

    // Перетаскивание/прокрутка прямо от потока касаний (тап работает и через
    // синтетические UITouch, а движение — только так).
    HUDRawDragTarget _rawTarget;
    CGPoint _rawStart;          // точка начала переноса (НЕ сдвигается: за счёт
                                // этого элемент идёт за пальцем один к одному)
    CGPoint _rawLastPoint;      // точка предыдущего события потока (для отсева скачков)
    CGPoint _rawPressPoint;     // точка нажатия — по ней решаем, тап это или перенос
    CGPoint _rawPressCenter;    // положение элемента в момент нажатия (для возврата)
    CGPoint _rawStartCenter;    // позиция квадрата/панели на момент начала
    CGPoint _rawStartOffset;    // contentOffset на момент начала
    BOOL _rawMoved;             // палец реально сдвинулся (а не просто тап)
    BOOL _rawArmed;             // удержание прошло — жест стал переносом
    BOOL _rawHoldable;          // удержание здесь вообще разрешено (см. ниже)
    BOOL _rawTapFired;          // тап уже отработан этим жестом (не дважды)
    BOOL _dragging;             // жест сейчас владеет позицией квадрата/панели
    CGFloat _rawThreshold;      // порог «это уже протяжка, а не тап»
    NSTimeInterval _rawLastTime; // время последнего события потока
    NSTimeInterval _rawStartTime; // момент начала жеста (для контроля длины)
    NSTimeInterval _rawLastTapTime; // последний отработанный тап (для гашения
                                    // повторного «подъёма» одного и того же касания)
    CGPoint _rawLastTapPoint;
}

#pragma mark - Создание

+ (instancetype)currentOverlay
{
    // Оверлей лежит в окне HUD, а окно держится делегатом приложения процесс;
    // искать его заново по иерархии окон не нужно (и окна доступны не всегда).
    return _hudCurrentOverlay;
}

+ (instancetype)overlayForWindow:(UIWindow *)window
{
    HUDOverlayView *overlay = [[HUDOverlayView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _hudCurrentOverlay = overlay;
    return overlay;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil) { return nil; }

    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _orientation = UIInterfaceOrientationPortrait;

    _stage = [[UIView alloc] initWithFrame:self.bounds];
    _stage.backgroundColor = [UIColor clearColor];
    [self addSubview:_stage];

    // Холст ESP добавляем ПЕРВЫМ: он должен лежать под квадратом и панелью.
    _espView = [[AscentESPHostView alloc] initWithFrame:_stage.bounds];
    _espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _espView.hidden = YES;
    [_stage addSubview:_espView];

    _triggerOffset = CGSizeMake(HUDOverlayNumber(@"trigger.x", 0),
                                HUDOverlayNumber(@"trigger.y", 0));
    _panelOffset = CGSizeMake(HUDOverlayNumber(@"hud.panel.x", 0),
                              HUDOverlayNumber(@"hud.panel.y", 0));
    _tab = 0;

    // Читы по умолчанию ВЫКЛЮЧЕНЫ. В общем файле значения переживают
    // перезапуск, поэтому меню открывалось со всем включённым — сбрасываем
    // переключатели при каждом подъёме оверлея. Позиции квадрата и панели при
    // этом сохраняются.
    HUDOverlaySetFlag(@"cheat.esp", NO);
    HUDOverlaySetFlag(@"cheat.aimbot", NO);
    HUDOverlaySetFlag(@"cheat.trigger", NO);

    [self buildTrigger];
    [self buildPanel];
    [self startOrientationObserver];

    // Сообщаем приложению, что квадрат рисует HUD и дублировать его в app не
    // нужно. Приложение покажет свой запасной квадрат, только если этой метки
    // нет (то есть HUD-оверлей не поднялся).
    HUDOverlaySetFlag(@"hud.overlay", YES);

    _trigger.hidden = NO;
    _trigger.layer.opacity = 1.0f;

    AscentHUDLog(@"HUD: UIKit-оверлей создан (сборка 5), bounds=%@", NSStringFromCGRect(frame));
    return self;
}

#pragma mark - Касания из потока HID (перетаскивание и прокрутка)

/// Управляемый элемент: кнопка, крестик, вкладка, строка переключателя или
/// группа слайдера. Отдельная категория нужна, чтобы НАЖАТИЕ на кнопку не
/// превращалось в прокрутку: управляющим элементам даём большой порог
/// «протяжки», и дрожь руки при нажатии остаётся тапом.
- (BOOL)isInteractiveView:(UIView *)view
{
    if (view == nil) { return NO; }
    UIView *cursor = view;
    while (cursor != nil && cursor != _stage && cursor != _panel) {
        if ([cursor isKindOfClass:[UIControl class]]) { return YES; }
        if (cursor == _gameProcLabel) { return YES; }
        if ([self switchInRow:cursor] != nil) { return YES; }
        if ([self sliderInGroup:cursor] != nil) { return YES; }
        cursor = cursor.superview;
    }
    return NO;
}

/// Кто под пальцем. Считаем по своей иерархии (а не по окну): окно
/// accessibility-оверлея от системы касаний не получает, но hitTest по нашим
/// же вью работает всегда.
- (HUDRawDragTarget)rawDragTargetAtPoint:(CGPoint)point
{
    UIView *hit = [self hitTest:point withEvent:nil];
    if (hit == nil) { return HUDRawDragNone; }

    // Квадрат: нажатие открывает меню, а перенос идёт только по УДЕРЖАНИЮ
    // (см. kRawDragHold). Дрожь руки при нажатии его не сдвинет.
    if (hit == _trigger || [hit isDescendantOfView:_trigger]) { return HUDRawDragTrigger; }
    // Управляющие элементы проверяем ДО шапки и карточки: вкладки, переключатели
    // и слайдеры лежат в панели, и без этого порядка их нажатие превращалось бы
    // в перетаскивание панели.
    if ([self isInteractiveView:hit]) { return HUDRawDragControl; }
    // Шапка панели — штатное место переноса меню, как заголовок окна.
    if (hit == _panelHeader || [hit isDescendantOfView:_panelHeader]) { return HUDRawDragPanel; }
    if (hit == _scroll || [hit isDescendantOfView:_scroll]) { return HUDRawDragScroll; }
    // Полоса заголовка раздела и поля вокруг стека — тоже перенос панели, чтобы
    // меню можно было утащить не только за шапку.
    if (hit == _contentCard || [hit isDescendantOfView:_contentCard]) { return HUDRawDragPanel; }
    if (hit == _panel) { return HUDRawDragPanel; }
    return HUDRawDragNone;
}

/// Порог протяжки для ПРОКРУТКИ содержимого вкладки, в точках. Квадрат и панель
/// переносятся не порогом, а УДЕРЖАНИЕМ (kRawDragHold): порог не спасал —
/// дрожь руки при нажатии легко даёт 10-15 pt, и элементы сдвигались прямо во
/// время нажатия. Здесь порог нужен только для того, чтобы протяжка по строке
/// не сбивала нажатие на неё.
- (CGFloat)rawThresholdForTarget:(HUDRawDragTarget)target
{
    switch (target) {
        case HUDRawDragTrigger: return 24.0;
        case HUDRawDragPanel:   return 30.0;
        case HUDRawDragControl: return 48.0;
        default:                return 30.0;
    }
}

/// Начинает (или заново подхватывает после паузы) жест от указанной точки.
/// Координаты — точка в своей иерархии (для hitTest) и точка в слое _stage (для
/// смещения с учётом поворота экрана).
- (void)beginRawDragAtPoint:(CGPoint)point stagePoint:(CGPoint)stagePoint
{
    _rawTarget = [self rawDragTargetAtPoint:point];
    _rawThreshold = [self rawThresholdForTarget:_rawTarget];
    _rawStart = stagePoint;
    _rawLastPoint = stagePoint;
    _rawPressPoint = stagePoint;
    _rawStartCenter = (_rawTarget == HUDRawDragTrigger) ? _trigger.center : _panel.center;
    _rawPressCenter = _rawStartCenter;
    _rawStartOffset = _scroll.contentOffset;
    _rawMoved = NO;
    _rawArmed = NO;
    // Где удержание вообще разрешено. Квадрат и панель — всегда. Управляющие
    // элементы — только ВНЕ области прокрутки (кнопки вкладок): внутри неё
    // удержание оставляем прокрутке, иначе медленная протяжка по строке
    // превращалась бы в перенос меню вместо прокрутки списка ESP.
    UIView *hit = [self hitTest:point withEvent:nil];
    BOOL insideScroll = (hit != nil && [hit isDescendantOfView:_scroll]);
    _rawHoldable = (_rawTarget == HUDRawDragTrigger ||
                    _rawTarget == HUDRawDragPanel ||
                    (_rawTarget == HUDRawDragControl && !insideScroll));
    _rawTapFired = NO;
    _dragging = YES;
    _rawStartTime = [[NSProcessInfo processInfo] systemUptime];
    _rawLastTime = _rawStartTime;
}

- (void)handleRawTouchPhase:(UITouchPhase)phase
                 atLocation:(CGPoint)location
                   inWindow:(UIWindow *)window
{
    if (window == nil || _stage == nil) { return; }

    // И квадрат, и панель лежат в повёрнутом слое _stage, поэтому смещение
    // считаем в его координатах: в ландшафте панель тогда идёт за пальцем, а не
    // «поперёк» экрана.
    CGPoint point = [self convertPoint:location fromView:window];
    CGPoint stagePoint = [_stage convertPoint:location fromView:window];

    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];

    if (phase == UITouchPhaseBegan) {
        [self beginRawDragAtPoint:point stagePoint:stagePoint];
        return;
    }

    if (phase == UITouchPhaseStationary) { return; }

    // Жест жив, только пока по нему идут события и только ограниченное время.
    //
    // Это главный ремонт «телепорта». AX/HID-поток на iOS 15 нередко теряет
    // событие «подъём»: тогда старое начало жеста висело бы навсегда, и
    // СЛЕДУЮЩЕЕ движение считалось бы протяжкой от устаревшей точки. Квадрат и
    // панель при этом прыгали назад — ровно на то место, где они появились
    // (у квадрата — где он оказался после Start, у панели — где она открылась).
    //
    // Раньше проверялась только пауза между событиями, и она не ловила главный
    // случай: _rawLastTime обновлялся на КАЖДОМ событии, поэтому пока палец
    // водит по экрану, залипший жест никогда не «протухал». Теперь добавлен
    // контроль общей длины жеста (kRawGestureLifetime), и залипшее состояние в
    // любом случае переподхватывается заново — БЕЗ движения элементов: только
    // перебазируется начало, поэтому квадрат и панель остаются на месте.
    // Начатый перенос (после удержания) протухшим НЕ считаем: палец может вести
    // меню дольше предельной длины жеста, и обрывать его на полпути нельзя.
    // Ограничение нужно только для НЕначатого жеста — чтобы залипшее состояние
    // не тянулось через следующие касания.
    BOOL dead = (_rawTarget == HUDRawDragNone) ||
                (!_rawArmed && (((now - _rawLastTime) > kRawGestureStale) ||
                                ((now - _rawStartTime) > kRawGestureLifetime)));
    _rawLastTime = now;

    if (dead && _rawTarget != HUDRawDragNone) {
        AscentHUDLog(@"[gesture] жест протух — переподхватываю от текущей точки");
        [self beginRawDragAtPoint:point stagePoint:stagePoint];
        if (phase == UITouchPhaseEnded) {
            [self fireRawTapAtPoint:point now:now];
        }
        [self endRawGesture];
        return;
    }

    if (_rawTarget == HUDRawDragNone) {
        // Жеста нет: «подъём» уже обработан, либо Began до оверлея не доехал.
        // Тап берём ОТ ТЕКУЩЕЙ ТОЧКИ: запомненная точка нажатия к этому моменту
        // устарела бы и указывала на чужой элемент. Повторный «подъём» того же
        // касания гасит debounce внутри fireRawTapAtPoint:now:.
        if (phase == UITouchPhaseEnded) {
            [self fireRawTapAtPoint:point now:now];
        }
        return;
    }

    if (phase == UITouchPhaseMoved) {
        // Отсев скачков. Шаг от ПРЕДЫДУЩЕГО события больше предела — это не
        // палец, а мусорное событие с координатами чужого касания. Раньше
        // такой шаг сразу пробивал порог и элемент уезжал на сотни точек за
        // один кадр — это и был «телепорт». Теперь событие игнорируется, а
        // жест просто перебазируется на текущую точку.
        CGFloat stepX = stagePoint.x - _rawLastPoint.x;
        CGFloat stepY = stagePoint.y - _rawLastPoint.y;
        _rawLastPoint = stagePoint;
        CGFloat stepLen = sqrt(stepX * stepX + stepY * stepY);
        if (stepLen > kRawJumpLimit) {
            AscentHUDLog(@"[gesture] скачок %.0f pt — мусорное событие, элемент не двигаю", stepLen);
            _rawStart = stagePoint;
            _rawStartOffset = _scroll.contentOffset;
            _rawStartCenter = (_rawTarget == HUDRawDragTrigger) ? _trigger.center : _panel.center;
            // Скачок обрывает уже начатый перенос: вести элемент по мусорным
            // координатам нельзя. Нажатие при этом не теряется — точку нажатия
            // мы помним отдельно (_rawPressPoint).
            _rawMoved = NO;
            _rawArmed = NO;
            return;
        }

        CGPoint delta = CGPointMake(stagePoint.x - _rawStart.x, stagePoint.y - _rawStart.y);

        // ПЕРЕНОС квадрата и панели — строго ЗА ПАЛЬЦЕМ, один к одному:
        // положение = положение на момент нажатия + весь путь пальца. Никаких
        // порогов, перебазирований и «догоняний» — именно из-за них перенос
        // отставал от пальца. Начало отсчёта не сдвигается ни на точку, поэтому
        // смещение элемента всегда равно смещению пальца.
        if (_rawHoldable) {
            if (!_rawArmed) {
                // Включаем перенос либо по очень короткому удержанию, либо
                // сразу, если палец успел уйти далеко. Нажатие короткое и почти
                // без движения, поэтому переносом не становится.
                CGFloat len = sqrt(delta.x * delta.x + delta.y * delta.y);
                if ((now - _rawStartTime) < kRawDragHold && len < kRawDragArmMove) { return; }
                _rawArmed = YES;
                // Удержание на кнопке вкладки тоже переносит панель — так меню
                // можно утащить не только за шапку.
                if (_rawTarget == HUDRawDragControl) { _rawTarget = HUDRawDragPanel; }
                AscentHUDLog(@"[gesture] перенос %@ (%.0f мс)",
                             _rawTarget == HUDRawDragTrigger ? @"квадрата" : @"панели",
                             (now - _rawStartTime) * 1000.0);
            }
            _rawMoved = YES;
            [self applyRawDragDelta:delta];
            return;
        }

        // Прокрутка содержимого вкладки: здесь порог нужен, чтобы протяжка не
        // сбивала нажатие на строку.
        CGFloat limit = _rawThreshold > 0 ? _rawThreshold : 6.0;
        if (!_rawMoved && (delta.x * delta.x + delta.y * delta.y) < limit * limit) { return; }
        if (!_rawMoved) {
            _rawMoved = YES;
            // Здесь перебазирование нужно: содержимое не должно «прыгнуть» на
            // величину порога в один кадр.
            _rawStart = stagePoint;
            _rawStartOffset = _scroll.contentOffset;
            delta = CGPointZero;
            AscentHUDLog(@"[gesture] поток: тяну содержимое вкладки");
        }
        [self applyRawDragDelta:delta];
        return;
    }

    // Ended / Cancelled: фиксируем результат (позицию или смещение прокрутки).
    if (_rawMoved && _rawHoldable) {
        // Смотрим ВЕСЬ путь пальца от точки нажатия. Если он крошечный — это
        // всё-таки нажатие, а не перенос: возвращаем элемент ровно туда, где он
        // был в момент нажатия, и обрабатываем как тап. Без этого медленное
        // нажатие с дрожью руки съедало бы нажатие, а элемент оставался
        // сдвинутым на пару точек.
        CGFloat pathX = stagePoint.x - _rawPressPoint.x;
        CGFloat pathY = stagePoint.y - _rawPressPoint.y;
        if ((pathX * pathX + pathY * pathY) < kRawTapSlop * kRawTapSlop) {
            if (_rawTarget == HUDRawDragTrigger) {
                _trigger.center = _rawPressCenter;
                CGPoint base = [self triggerBaseCenter];
                _triggerOffset = CGSizeMake(_rawPressCenter.x - base.x, _rawPressCenter.y - base.y);
            } else if (_rawTarget == HUDRawDragPanel) {
                _panel.center = _rawPressCenter;
                _panelOffset = [self panelOffsetForCenter:_rawPressCenter size:_panel.bounds.size];
            }
            [self endRawGesture];
            if (phase == UITouchPhaseEnded) { [self fireRawTapAtPoint:point now:now]; }
            return;
        }
    }

    if (_rawMoved) {
        [self commitRawDrag];
    } else if (phase == UITouchPhaseEnded) {
        // Палец не сдвинулся — это тап. Обрабатываем его САМИ прямо от потока
        // касаний: на синтетических UITouch распознаватели жестов срабатывают
        // ненадёжно (за них конкурирует pan-скролл, и Began/Ended местами
        // теряется), из-за чего кнопки «не нажимались». Точка — та, где палец
        // сошёл вверх: от неё и выбираем, что именно нажали.
        [self fireRawTapAtPoint:point now:now];
    }
    [self endRawGesture];
}

/// Завершает жест, сбрасывая всё его состояние. Без этого следующее касание
/// продолжало бы старый жест и двигало элементы от устаревшей стартовой точки.
- (void)endRawGesture
{
    _rawTarget = HUDRawDragNone;
    _rawMoved = NO;
    _rawArmed = NO;
    _rawTapFired = NO;
    _dragging = NO;
}

/// Тап с гашением повторного «подъёма» одного и того же касания: AX/HID-поток
/// иногда присылает «подъём» дважды, и без этого одно нажатие переключало бы
/// дважды (включил — тут же выключил). Гасим только похожий повтор: настоящий
/// второй тап по тому же месту отличается по времени.
- (void)fireRawTapAtPoint:(CGPoint)point now:(NSTimeInterval)now
{
    if (now - _rawLastTapTime < kRawTapDebounce) {
        CGFloat dx = point.x - _rawLastTapPoint.x;
        CGFloat dy = point.y - _rawLastTapPoint.y;
        if (dx * dx + dy * dy < 60.0 * 60.0) { return; }
    }
    _rawTapFired = YES;
    _rawLastTapTime = now;
    _rawLastTapPoint = point;
    [self performTapAtPoint:point];
}

/// Попадание в вью ГЕОМЕТРИЧЕСКИ, независимо от того, интерактивно ли оно и что
/// вернул hitTest. Переключатели и слайдеры намеренно неинтерактивны (их
/// состояние двигает только наш жест), а строки лежат внутри скролла — hitTest
/// в этом случае возвращает сам скролл, и нажатие «не находило» переключатель.
/// Именно поэтому нажатие на Enable на вкладке ESP ничего не делало.
- (BOOL)point:(CGPoint)point insideView:(UIView *)view
{
    if (view == nil || view.hidden || view.alpha < 0.01) { return NO; }
    CGPoint local = [view convertPoint:point fromView:self];
    return CGRectContainsPoint(view.bounds, local);
}

/// Строка видна внутри прокрутки и точка попадает в неё. Строки ниже видимой
/// части обрезаны скроллом — нажиматься они не должны.
- (BOOL)pointIsOnScrollRow:(CGPoint)point row:(UIView *)row
{
    if (_scroll == nil || row == nil || row.hidden) { return NO; }
    CGPoint inScroll = [_scroll convertPoint:point fromView:self];
    // bounds скролла в его же координатах начинаются с contentOffset — здесь
    // это ровно проверка «строка сейчас видна на экране».
    if (!CGRectContainsPoint(_scroll.bounds, inScroll)) { return NO; }
    return CGRectContainsPoint(row.frame, inScroll);
}

/// Тап прямо от потока касаний: попадаем в вид под точкой и выполняем его
/// действие (те же обработчики, что вешаны на target'ы UIControls).
- (void)performTapAtPoint:(CGPoint)point
{
    UIView *hit = [self hitTest:point withEvent:nil];

    // Квадратик-триггер: нажатие только открывает/закрывает меню и никогда не
    // двигает квадрат.
    if (hit != nil && (hit == _trigger || [hit isDescendantOfView:_trigger])) { [self togglePanel]; return; }

    // Шапка панели ничего не делает — панель не таскается.
    if (hit != nil && (hit == _panelHeader || [hit isDescendantOfView:_panelHeader])) { return; }

    // Подпись «процесс игры».
    if (hit != nil && (hit == _gameProcLabel || [hit isDescendantOfView:_gameProcLabel])) {
        [self refreshGameProcess];
        return;
    }

    // Кнопки вкладок лежат прямо в панели (tag = 100 + индекс).
    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        UIButton *tab = _tabButtons[i];
        if (hit != nil && (hit == tab || [hit isDescendantOfView:tab])) { [self selectTab:i]; return; }
    }

    // Кнопка unload.
    if (hit != nil && _unloadButton != nil &&
        (hit == _unloadButton || [hit isDescendantOfView:_unloadButton])) {
        [self unloadTapped];
        return;
    }

    // Строки переключателей и группы слайдеров ищем ГЕОМЕТРИЧЕСКИ, а не по
    // hitTest: только так нажатие находит переключатель под строкой.
    for (UISwitch *toggle in _switches) {
        UIView *row = toggle.superview;
        if (![self pointIsOnScrollRow:point row:row]) { continue; }
        toggle.on = !toggle.on;
        AscentHUDLog(@"[gesture] %@ -> %d", toggle.accessibilityIdentifier, (int)toggle.on);
        [self switchChanged:toggle];
        return;
    }

    for (UISlider *slider in _sliders) {
        UIView *group = slider.superview;
        if (![self pointIsOnScrollRow:point row:group]) { continue; }
        CGPoint local = [slider convertPoint:point fromView:self];
        [self applyTapToSlider:slider atPoint:local];
        return;
    }

    AscentHUDLog(@"[gesture] тап ни по чему не пришёлся (%.0f, %.0f)", point.x, point.y);
}

/// Значение слайдера из точки тапа (слайдер сам касания не обрабатывает).
- (void)applyTapToSlider:(UISlider *)slider atPoint:(CGPoint)point
{
    CGFloat width = MAX(slider.bounds.size.width, 1.0);
    CGFloat ratio = MIN(MAX(point.x / width, 0.0), 1.0);
    slider.value = slider.minimumValue + (float)(ratio * (slider.maximumValue - slider.minimumValue));
    [self updateSliderLabel:slider.accessibilityIdentifier];
    [self sliderChanged:slider];
    AscentHUDLog(@"[gesture] %@ = %.2f (тап)", slider.accessibilityIdentifier, slider.value);
}

- (void)applyRawDragDelta:(CGPoint)delta
{
    if (_rawTarget == HUDRawDragTrigger) {
        CGPoint center = CGPointMake(_rawStartCenter.x + delta.x, _rawStartCenter.y + delta.y);
        center = [self clampTriggerCenter:center];
        _trigger.center = center;
        CGPoint base = [self triggerBaseCenter];
        _triggerOffset = CGSizeMake(center.x - base.x, center.y - base.y);
        return;
    }

    if (_rawTarget == HUDRawDragPanel) {
        CGSize panelSize = _panel.bounds.size;
        CGPoint center = CGPointMake(_rawStartCenter.x + delta.x, _rawStartCenter.y + delta.y);
        center = [self clampPanelCenter:center size:panelSize];
        _panel.center = center;
        _panelOffset = [self panelOffsetForCenter:center size:panelSize];
        return;
    }

    if (_rawTarget == HUDRawDragScroll || _rawTarget == HUDRawDragControl) {
        CGFloat minY = -_scroll.contentInset.top;
        CGFloat maxY = MAX(_scroll.contentSize.height - _scroll.bounds.size.height +
                           _scroll.contentInset.bottom, minY);
        CGFloat y = _rawStartOffset.y - delta.y;
        _scroll.contentOffset = CGPointMake(_scroll.contentOffset.x, MIN(MAX(y, minY), maxY));
    }
}

- (void)commitRawDrag
{
    if (_rawTarget == HUDRawDragTrigger) {
        CGPoint base = [self triggerBaseCenter];
        CGPoint center = [self clampTriggerCenter:_trigger.center];
        _triggerOffset = CGSizeMake(center.x - base.x, center.y - base.y);
        HUDOverlaySetNumber(@"trigger.x", _triggerOffset.width);
        HUDOverlaySetNumber(@"trigger.y", _triggerOffset.height);
        AscentHUDLog(@"[gesture] квадрат: перетаскивание закончилось, смещение=(%.0f, %.0f)",
                     _triggerOffset.width, _triggerOffset.height);
        return;
    }

    if (_rawTarget == HUDRawDragPanel) {
        CGSize panelSize = _panel.bounds.size;
        CGPoint center = [self clampPanelCenter:_panel.center size:panelSize];
        _panelOffset = [self panelOffsetForCenter:center size:panelSize];
        HUDOverlaySetNumber(@"hud.panel.x", _panelOffset.width);
        HUDOverlaySetNumber(@"hud.panel.y", _panelOffset.height);
        AscentHUDLog(@"[gesture] панель: перетаскивание закончилось, смещение=(%.0f, %.0f)",
                     _panelOffset.width, _panelOffset.height);
        return;
    }

    if (_rawTarget == HUDRawDragScroll || _rawTarget == HUDRawDragControl) {
        AscentHUDLog(@"[gesture] прокрутка вкладки: y=%.0f", _scroll.contentOffset.y);
    }
}

#pragma mark - Куда пускать касания

// Пустые места оверлея касаний не забирают: если под пальцем нет ни квадрата,
// ни панели, окно отдаёт касание приложению под ним. Слой _stage сам по себе
// тоже не интерактивен — иначе он перехватывал бы всё.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == _stage) { return nil; }
    return hit;
}

#pragma mark - Раскладка

- (void)layoutSubviews
{
    [super layoutSubviews];

    [self layoutStage];
    // layoutTrigger/layoutPanel пересчитывают позицию из сохранённого смещения
    // и клампа — то же самое, что расставляет жест во время перетаскивания.
    // Поэтому их можно вызывать всегда: раскладка идемпотентна, ничего не
    // «откатывается» и панель с квадратом никогда не выезжают за край.
    [self layoutTrigger];
    [self layoutPanel];
}

/// Поворачиваем слой с контентом под текущую ориентацию. Окно остаётся
/// портретным, поэтому в ландшафте слой разворачивается на ±90° и его bounds
/// меняются местами (ширина <-> высота).
- (void)layoutStage
{
    CGRect screen = self.bounds;
    _stage.bounds = HUDOrientationBounds(_orientation, screen);
    _stage.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
    _stage.transform = CGAffineTransformMakeRotation(HUDOrientationAngle(_orientation));
}

- (CGRect)stageBounds
{
    return _stage.bounds;
}

// Отступы считаем ТОЧНО так же, как запасной квадрат внутри приложения
// (LoaderView: top = max(safeArea.top, 44), bottom = max(safeArea.bottom, 16)).
// Иначе базовые позиции квадрата app и квадрата HUD разъезжаются на 20+ точек,
// и в момент «передачи эстафеты» после Start на секунду видно ДВА квадрата.
- (CGFloat)safeTop
{
    return MAX(self.safeAreaInsets.top, 44.0);
}

- (CGFloat)safeBottom
{
    return MAX(self.safeAreaInsets.bottom, 16.0);
}

- (CGPoint)triggerBaseCenter
{
    CGFloat side = kTriggerSide;
    CGRect stage = [self stageBounds];
    CGPoint center;
    center.x = stage.size.width - side - kTriggerInset + side / 2.0;
    center.y = [self safeTop] + kTriggerInset + side / 2.0;
    return center;
}

- (CGRect)triggerArea
{
    CGRect stage = [self stageBounds];
    return CGRectMake(kMargin,
                      [self safeTop] + kMargin,
                      MAX(stage.size.width - kMargin * 2.0, 0),
                      MAX(stage.size.height - [self safeTop] - [self safeBottom] - kMargin * 2.0, 0));
}

- (CGPoint)clampTriggerCenter:(CGPoint)center
{
    CGRect area = [self triggerArea];
    CGFloat half = kTriggerSide / 2.0;
    CGFloat minX = area.origin.x + half;
    CGFloat maxX = MAX(area.origin.x + area.size.width - half, minX);
    CGFloat minY = area.origin.y + half;
    CGFloat maxY = MAX(area.origin.y + area.size.height - half, minY);
    center.x = MIN(MAX(center.x, minX), maxX);
    center.y = MIN(MAX(center.y, minY), maxY);
    return center;
}

- (void)layoutTrigger
{
    // Пока палец тянет квадрат, его позицией владеет жест (applyRawDragDelta):
    // раскладка не должна откатывать его к сохранённому смещению — иначе
    // перетаскивание «дёргалось», а после него квадрат телепортировался обратно
    // на стартовую точку при первом же layout (например, при открытии панели).
    if (_dragging && _rawTarget == HUDRawDragTrigger) { return; }
    CGPoint base = [self triggerBaseCenter];
    CGPoint center = CGPointMake(base.x + _triggerOffset.width, base.y + _triggerOffset.height);
    _trigger.bounds = CGRectMake(0, 0, kTriggerSide, kTriggerSide);
    _trigger.center = [self clampTriggerCenter:center];
    _triggerGradient.frame = _trigger.bounds;
    _triggerIcon.frame = _trigger.bounds;
    _trigger.layer.cornerRadius = 17.0;
}

#pragma mark - Квадратик

- (void)buildTrigger
{
    _trigger = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTriggerSide, kTriggerSide)];
    _trigger.backgroundColor = [UIColor clearColor];
    _trigger.layer.cornerRadius = 17.0;
    _trigger.layer.masksToBounds = YES;
    _trigger.layer.borderWidth = 1.0;
    _trigger.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;

    _triggerGradient = [CAGradientLayer layer];
    _triggerGradient.colors = @[ (id)HUDColor(0.52, 0.52, 0.56).CGColor,
                                 (id)HUDColor(0.29, 0.29, 0.33).CGColor ];
    _triggerGradient.startPoint = CGPointMake(0.5, 0.0);
    _triggerGradient.endPoint = CGPointMake(0.5, 1.0);
    [_trigger.layer insertSublayer:_triggerGradient atIndex:0];

    _triggerIcon = [[UIImageView alloc] init];
    _triggerIcon.image = HUDTriggerImage(NO);
    _triggerIcon.tintColor = [UIColor whiteColor];
    _triggerIcon.contentMode = UIViewContentModeCenter;
    [_trigger addSubview:_triggerIcon];

    // Распознаватель тапа квадрату НЕ нужен и вреден: касания оверлея идут
    // через поток HID (handleRawTouchPhase:...), и когда рядом висел ещё и
    // UITapGestureRecognizer, одно нажатие обрабатывалось ДВАЖДЫ — панель
    // успевала открыться и тут же закрыться, а квадрат при этом дёргался.
    // Тап квадрата целиком ведёт performTapAtPoint:.

    [_stage addSubview:_trigger];
}

- (void)triggerTapped:(UITapGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self togglePanel];
    }
}

- (void)updateTriggerIcon
{
    _triggerIcon.image = HUDTriggerImage(_panelOpen);
}

#pragma mark - Открытие/закрытие панели

- (void)togglePanel
{
    _panelOpen = !_panelOpen;
    AscentHUDLog(@"HUD: панель %@", _panelOpen ? @"открыта" : @"закрыта");
    if (_panelOpen) {
        [self reloadCheatControls];
        [self selectTab:_tab];
        _panel.hidden = NO;
    } else {
        _panel.hidden = YES;
    }
    [self updateTriggerIcon];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    // Геометрия в журнал: по ней сразу видно, попадает ли панель на экран и
    // не «уплыл» ли квадрат (смещение хранится отдельно от центра).
    AscentHUDLog(@"HUD: панель frame=%@, stage=%@, панель.смещение=(%.0f, %.0f), квадрат center=%@ смещение=(%.0f, %.0f)",
                 NSStringFromCGRect(_panel.frame), NSStringFromCGRect([self stageBounds]),
                 _panelOffset.width, _panelOffset.height, NSStringFromCGPoint(_trigger.center),
                 _triggerOffset.width, _triggerOffset.height);
}

- (UIButton *)makeFlatButton:(NSString *)title
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    return button;
}

#pragma mark - Панель (сборка)

- (void)buildPanel
{
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidthMax, kPanelHeightMax)];
    _panel.backgroundColor = HUDFill();
    _panel.layer.cornerRadius = 20.0;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = HUDLine().CGColor;
    _panel.hidden = YES;

    // Шапка: за неё таскаем панель. Кнопки-крестика больше нет — панель
    // закрывается тапом по квадрату (как и было задумано).
    _panelHeader = [[UIView alloc] initWithFrame:CGRectZero];
    _panelHeader.backgroundColor = [UIColor clearColor];
    [_panel addSubview:_panelHeader];

    _panelTitle = HUDLabel(@"@ascentios", 15, UIFontWeightHeavy);
    _panelTitle.textColor = HUDAccent();
    [_panelHeader addSubview:_panelTitle];

    UILabel *headerLine = [[UILabel alloc] initWithFrame:CGRectZero];
    headerLine.backgroundColor = HUDLine();
    headerLine.tag = 0;
    [_panel addSubview:headerLine];

    // Колонка вкладок слева. Выбранная — красным текстом плюс красная
    // полоска у правого края колонки (как в эталонном меню).
    _tabButtons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[ @"Esp", @"Aim", @"Misc", @"Config" ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *button = [self makeFlatButton:titles[i]];
        // Колонка вкладок сужена до 64 pt (меню вертикальное), поэтому отступ
        // подписи уменьшаем: иначе «Config» не влезало в 44 pt текста.
        button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
        button.tag = 100 + i;
        button.layer.cornerRadius = 0.0;
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addTapGesture:button action:@selector(panelControlTapped:)];
        [_panel addSubview:button];
        [_tabButtons addObject:button];
    }

    _tabIndicator = [[UIView alloc] initWithFrame:CGRectZero];
    _tabIndicator.backgroundColor = HUDAccent();
    _tabIndicator.layer.cornerRadius = 1.5;
    [_panel addSubview:_tabIndicator];

    // Тёмная карточка содержимого справа: заголовок раздела и прокрутка.
    _contentCard = [[UIView alloc] initWithFrame:CGRectZero];
    _contentCard.backgroundColor = HUDCard();
    _contentCard.layer.cornerRadius = 14.0;
    _contentCard.layer.borderWidth = 1.0;
    _contentCard.layer.borderColor = HUDLine().CGColor;
    _contentCard.clipsToBounds = YES;
    [_panel addSubview:_contentCard];

    _sectionTitle = HUDLabel(@"", 13, UIFontWeightSemibold);
    _sectionTitle.textColor = [UIColor whiteColor];
    [_contentCard addSubview:_sectionTitle];

    // Прокручиваемая область содержимого — вкладки разной длины.
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    // Без задержки касаний для содержимого: жесты на кнопках/строках вкладок
    // срабатывают мгновенно, а не через долю секунды после касания.
    _scroll.delaysContentTouches = NO;
    _scroll.delegate = self;
    // Прокрутку ведём сами от потока касаний (см. handleRawTouchPhase:...):
    // на синтетических UITouch UIScrollView панораму не распознаёт, и если
    // оставить её включённой, содержимое поедет дважды.
    _scroll.panGestureRecognizer.enabled = NO;
    [_contentCard addSubview:_scroll];

    [self buildContent];

    [_stage addSubview:_panel];
}

/// Собираем всё содержимое вкладок сразу, а какие элементы видны — решает
/// раскладка по активной вкладке (см. layoutContentForTab:). Элементы лежат в
/// _scroll одним стеком и просто переставляются при смене вкладки.
- (void)buildContent
{
    _switches = [NSMutableArray array];
    // Первые три — главные переключатели (esp / aimbot / triggerbot). Дальше —
    // что именно рисовать в ESP: эти ключи читает холст AscentESPHostView.
    // Порядок важен: layoutContentForTab: обращается к элементам по индексу.
    NSArray<NSString *> *switchKeys = @[ @"cheat.esp",
                                         @"cheat.aimbot",
                                         @"cheat.trigger",
                                         @"esp.box",
                                         @"esp.health",
                                         @"esp.name",
                                         @"esp.distance",
                                         @"esp.snapline" ];
    NSArray<NSString *> *switchTitles = @[ @"Enable",
                                           @"Aimbot",
                                           @"Triggerbot",
                                           @"Boxes",
                                           @"Health",
                                           @"Names",
                                           @"Distance",
                                           @"Snapline" ];
    for (NSInteger i = 0; i < (NSInteger)switchKeys.count; i++) {
        UIView *row = HUDRoundedBox(12.0, [UIColor colorWithWhite:1.0 alpha:0.07]);
        // Шрифт 12 (а не 13): карточка содержимого сузилась до 158 pt, чтобы
        // панель стала вертикальной, и «Distance» при 13 упиралось в край.
        UILabel *label = HUDLabel(switchTitles[i], 12, UIFontWeightMedium);
        // Кадр подписи задаёт раскладка строки (см. layoutSwitchRow:). Здесь
        // только запрещаем autoresizing: строка рождается нулевой, и «тянущаяся»
        // высота раздувала подпись вдвое — текст уезжал ниже середины строки.
        label.autoresizingMask = UIViewAutoresizingNone;
        [row addSubview:label];

        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        toggle.accessibilityIdentifier = switchKeys[i];
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        // Переключатель сам касания не обрабатывает (иначе они воюют с жестом
        // на строке и получается двойное переключение) — состояние двигает только
        // наш жест, а сам переключатель остаётся индикатором.
        toggle.userInteractionEnabled = NO;
        [row addSubview:toggle];

        [self addTapGesture:row action:@selector(switchRowTapped:)];
        [_scroll addSubview:row];
        [_switches addObject:toggle];
    }

    _sliders = [NSMutableArray array];
    _sliderValueLabels = [NSMutableDictionary dictionary];
    NSArray<NSString *> *sliderKeys = @[ @"cheat.fov", @"cheat.smooth", @"cheat.delay" ];
    NSArray<NSString *> *sliderTitles = @[ @"fov", @"smooth", @"delay" ];
    for (NSInteger i = 0; i < (NSInteger)sliderKeys.count; i++) {
        UIView *group = [[UIView alloc] initWithFrame:CGRectZero];

        UILabel *caption = HUDLabel(sliderTitles[i], 12, UIFontWeightRegular);
        caption.textColor = HUDDim();
        caption.tag = 1;
        [group addSubview:caption];

        UILabel *value = HUDLabel(@"", 12, UIFontWeightSemibold);
        value.textAlignment = NSTextAlignmentRight;
        value.tag = 2;
        [group addSubview:value];
        _sliderValueLabels[sliderKeys[i]] = value;

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
        slider.accessibilityIdentifier = sliderKeys[i];
        slider.minimumTrackTintColor = HUDAccent();
        slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        // Явно задаём иконку ползунка: системный thumb меняет размер при
        // разных кадрах (иногда кажется «толстым» в момент первого показа),
        // а кастомный круглый даёт одинаковую толщину сразу и после раскладки.
        CGSize thumbSize = CGSizeMake(16.0, 16.0);
        UIGraphicsBeginImageContextWithOptions(thumbSize, NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx != NULL) {
            CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, thumbSize.width, thumbSize.height));
        }
        UIImage *thumbImg = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (thumbImg != nil) {
            [slider setThumbImage:thumbImg forState:UIControlStateNormal];
            [slider setThumbImage:thumbImg forState:UIControlStateHighlighted];
        }
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        // Слайдер двигает только жест по строке (см. комментарий про переключатель):
        // значение считаем из точки касания, минуя обработку касаний самим UISlider.
        // Жест только ТАП — иначе он воюет со скроллом вкладки за pan-жест.
        slider.userInteractionEnabled = NO;
        [group addSubview:slider];

        [self addTapGesture:group action:@selector(sliderRowTouched:)];

        [_scroll addSubview:group];
        [_sliders addObject:slider];
    }

    _gameProcLabel = HUDLabel(@"проверить процесс игры", 11.5, UIFontWeightMedium);
    _gameProcLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    _gameProcLabel.textAlignment = NSTextAlignmentCenter;
    _gameProcLabel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    _gameProcLabel.layer.cornerRadius = 10.0;
    _gameProcLabel.layer.borderWidth = 1.0;
    _gameProcLabel.layer.borderColor = HUDLine().CGColor;
    _gameProcLabel.userInteractionEnabled = YES;
    _gameProcLabel.tag = 3;
    [_scroll addSubview:_gameProcLabel];

    _unloadButton = [self makeFlatButton:@"unload"];
    _unloadButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightHeavy];
    _unloadButton.backgroundColor = HUDGray();
    _unloadButton.layer.cornerRadius = 12.0;
    [_unloadButton addTarget:self action:@selector(unloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addTapGesture:_unloadButton action:@selector(panelControlTapped:)];
    [_scroll addSubview:_unloadButton];

    _miscCaption = HUDLabel(@"стоп лоадера, меню остаётся", 11.5, UIFontWeightRegular);
    _miscCaption.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    [_scroll addSubview:_miscCaption];

    _configCaption = HUDLabel(@"память игры читает HUD-процесс: переключатели выше только включают доступ к ней",
                              10.5, UIFontWeightRegular);
    _configCaption.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    _configCaption.numberOfLines = 0;
    [_scroll addSubview:_configCaption];

    // Статус чтения ESP. Обновляется таймером: сообщение меняется само —
    // процесс появился, список наполнился, смещения поправили.
    _espStatusLabel = HUDLabel(@"esp: выключен", 10.5, UIFontWeightRegular);
    _espStatusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    _espStatusLabel.numberOfLines = 2;
    [_scroll addSubview:_espStatusLabel];

    _espStatusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                       target:self
                                                     selector:@selector(refreshESPStatus)
                                                     userInfo:nil
                                                      repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_espStatusTimer forMode:NSRunLoopCommonModes];
}

/// Показываем, что именно делает ESP прямо сейчас. Это главное окно отладки:
/// по одной строке видно, найден ли процесс и какие смещения не так.
- (void)refreshESPStatus
{
    if (_espStatusLabel == nil) { return; }

    BOOL enabled = HUDOverlayNumber(@"cheat.esp", 0) > 0.5;
    if (!enabled) {
        _espStatusLabel.text = @"esp: выключен";
        _espStatusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        return;
    }

    AscentESPFrame info;
    memset(&info, 0, sizeof(info));
    AscentESPGetFrame(NULL, 0, &info);

    NSString *text = info.status[0] != '\0'
        ? [NSString stringWithUTF8String:info.status]
        : @"читаю память игры…";
    _espStatusLabel.text = text;
    _espStatusLabel.textColor = (info.count > 0) ? HUDGreen() : HUDDim();
}

#pragma mark - Панель (раскладка)

/// Размер панели под фактическую площадь сцены. Ширина ограничена константой,
/// высота — и константой, и площадью: в ландшафте сцена всего ≈375 pt, поэтому
/// высокая панель уходила за верх экрана. Пропорцию держим ГОРИЗОНТАЛЬНОЙ —
/// меню должно расходиться влево-вправо, а не вверх.
- (CGSize)panelSizeForArea:(CGRect)area
{
    CGFloat width = MIN(MAX(area.size.width - 44.0, 0), kPanelWidthMax);
    CGFloat height = MIN(kPanelHeightMax, MAX(area.size.height, 0));

    // Меню горизонтальное: ширина обязана быть заметно больше высоты. Если
    // площадь узкая, режем высоту вместе с шириной, иначе пропорция
    // «перевернётся» обратно в вертикаль.
    CGFloat limit = floor(width / 1.25);
    if (height > limit) {
        height = MAX(limit, 150.0);
    }
    return CGSizeMake(width, height);
}

/// Держим панель внутри безопасной зоны. Считается всегда — и во время
/// перетаскивания тоже: уехать за край экрана панель не может в принципе, а
/// любой повторный расчёт раскладки даёт ровно ту же точку (перетаскивание
/// двигало панель «рывками» именно потому, что раскладка откатывала её назад).
- (CGPoint)clampPanelCenter:(CGPoint)center size:(CGSize)panelSize
{
    CGRect area = [self triggerArea];
    CGFloat halfW = panelSize.width / 2.0;
    CGFloat halfH = panelSize.height / 2.0;
    CGFloat minX = area.origin.x + halfW;
    CGFloat maxX = MAX(area.origin.x + area.size.width - halfW, minX);
    CGFloat minY = area.origin.y + halfH;
    CGFloat maxY = MAX(area.origin.y + area.size.height - halfH, minY);
    center.x = MIN(MAX(center.x, minX), maxX);
    center.y = MIN(MAX(center.y, minY), maxY);
    return center;
}

/// Смещение панели от базовой позиции — то, что сохраняется в общий файл.
- (CGSize)panelOffsetForCenter:(CGPoint)center size:(CGSize)panelSize
{
    CGRect stage = [self stageBounds];
    CGFloat baseX = (stage.size.width - panelSize.width) / 2.0;
    CGFloat baseY = stage.size.height * 0.74 - panelSize.height / 2.0;
    return CGSizeMake(center.x - (baseX + panelSize.width / 2.0),
                      center.y - (baseY + panelSize.height / 2.0));
}

- (void)layoutPanel
{
    if (_panel == nil) { return; }
    // Во время любой протяжки панель либо едет самим жестом, либо стоит
    // неподвижно — пересчитывать её раскладку на каждый кадр незачем (на старых
    // устройствах это и давало «лаг» при перетаскивании). Раскладка вернётся
    // сразу, как только палец отпущен, и при тапе (там _rawMoved = NO), чтобы
    // панель успела открыться на своём месте.
    if (_dragging && _rawMoved) { return; }

    CGRect stage = [self stageBounds];
    CGSize panelSize = [self panelSizeForArea:[self triggerArea]];
    CGFloat baseX = (stage.size.width - panelSize.width) / 2.0;
    CGFloat baseY = stage.size.height * 0.74 - panelSize.height / 2.0;

    CGPoint center = CGPointMake(baseX + panelSize.width / 2.0 + _panelOffset.width,
                                 baseY + panelSize.height / 2.0 + _panelOffset.height);
    center = [self clampPanelCenter:center size:panelSize];

    _panel.bounds = CGRectMake(0, 0, panelSize.width, panelSize.height);
    _panel.center = center;
    _panel.layer.cornerRadius = 20.0;
    _panel.layer.masksToBounds = YES;

    CGFloat w = panelSize.width;
    CGFloat h = panelSize.height;

    _panelHeader.frame = CGRectMake(0, 0, w, kHeaderHeight);
    _panelTitle.frame = CGRectMake(16, 0, w - 32, kHeaderHeight);

    for (UIView *sub in _panel.subviews) {
        if ([sub isKindOfClass:[UILabel class]] && sub.tag == 0) {
            sub.frame = CGRectMake(0, kHeaderHeight - 1, w, 1);
        }
    }

    // Тело панели: слева колонка вкладок, справа карточка содержимого.
    CGFloat bodyY = kHeaderHeight + 6.0;
    CGFloat bodyH = h - bodyY - kCardInset;
    CGFloat tabX = kCardInset;
    CGFloat tabW = kSidebarWidth;
    CGFloat cardX = tabX + tabW + 6.0;
    CGFloat cardW = w - cardX - kCardInset;

    CGFloat rowY = bodyY + 4.0;
    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        UIButton *button = _tabButtons[i];
        button.frame = CGRectMake(tabX, rowY, tabW - 8.0, kTabRowHeight);
        BOOL selected = (i == _tab);
        button.backgroundColor = [UIColor clearColor];
        [button setTitleColor:(selected ? HUDAccent() : HUDDim()) forState:UIControlStateNormal];
        if (selected) {
            _tabIndicator.hidden = NO;
            _tabIndicator.frame = CGRectMake(tabX + tabW - 4.0, rowY + 7.0, 3.0, kTabRowHeight - 14.0);
        }
        rowY += kTabRowHeight;
    }

    _contentCard.frame = CGRectMake(cardX, bodyY, cardW, bodyH);

    static NSString *const kSectionTitles[4] = { @"ESP", @"AIM", @"MISC", @"CONFIG" };
    _sectionTitle.text = (_tab >= 0 && _tab < 4) ? kSectionTitles[_tab] : kSectionTitles[0];
    _sectionTitle.frame = CGRectMake(14, 12, cardW - 28, 20);

    _scroll.frame = CGRectMake(0, kSectionTop, cardW, MAX(bodyH - kSectionTop, 0));
    [self layoutContentForTab:_tab width:cardW];
}

/// Раскладка содержимого активной вкладки: прячем всё лишнее и ставим нужные
/// элементы одним стеком сверху вниз. Заодно фиксируем contentSize прокрутки.
- (void)layoutContentForTab:(NSInteger)tab width:(CGFloat)w
{
    CGFloat x = 10.0;
    CGFloat rowWidth = w - 20.0;
    CGFloat y = 6.0;

    for (UISwitch *toggle in _switches) { toggle.superview.hidden = YES; }
    for (UISlider *slider in _sliders) { slider.superview.hidden = YES; }
    _gameProcLabel.hidden = YES;
    _unloadButton.hidden = YES;
    _miscCaption.hidden = YES;
    _configCaption.hidden = YES;
    _espStatusLabel.hidden = YES;

    if (tab == 0) {
        // Вкладка ESP: главный переключатель, затем что именно рисовать.
        [self layoutSwitchRow:_switches[0] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[3] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[4] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[5] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[6] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[7] x:x y:&y width:rowWidth];

        // Короткий статус чтения игры: без него непонятно, почему боксы не
        // появились (нет процесса, не заданы смещения, пустой список).
        _espStatusLabel.hidden = NO;
        _espStatusLabel.frame = CGRectMake(x, y + 2.0, rowWidth, 34.0);
        y += 34.0 + 4.0;
    } else if (tab == 1) {
        [self layoutSwitchRow:_switches[1] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[2] x:x y:&y width:rowWidth];
    } else if (tab == 2) {
        _gameProcLabel.hidden = NO;
        _gameProcLabel.frame = CGRectMake(x, y, rowWidth, 32);
        y += 32 + 10;

        _unloadButton.hidden = NO;
        _unloadButton.frame = CGRectMake(x, y, rowWidth, 46);
        y += 46 + 10;

        _miscCaption.hidden = NO;
        _miscCaption.frame = CGRectMake(x, y, rowWidth, 18);
        y += 18 + 4;
    } else {
        [self layoutSliderGroup:_sliders[0] x:x y:&y width:rowWidth];
        [self layoutSliderGroup:_sliders[1] x:x y:&y width:rowWidth];
        [self layoutSliderGroup:_sliders[2] x:x y:&y width:rowWidth];
        y += 4;

        _configCaption.hidden = NO;
        CGSize need = [_configCaption sizeThatFits:CGSizeMake(rowWidth, CGFLOAT_MAX)];
        _configCaption.frame = CGRectMake(x, y, rowWidth, need.height);
        y += need.height + 6;
    }

    _scroll.contentSize = CGSizeMake(w, MAX(y, _scroll.bounds.size.height));
}

- (void)layoutSwitchRow:(UISwitch *)toggle x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width
{
    UIView *row = toggle.superview;
    row.hidden = NO;
    row.frame = CGRectMake(x, *y, width, kSwitchRowHeight);

    // Подпись задаём ЯВНО и ровно по высоте строки: у UILabel иначе
    // «тянется» высота (autoresizing) от нулевого размера строки, и текст
    // уезжает ниже её середины — надписи выглядели сдвинутыми вниз.
    // Карточка снова широкая (≈258 pt), поэтому отступы обычные.
    for (UIView *sub in row.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            sub.frame = CGRectMake(14, 0, width - 80.0, kSwitchRowHeight);
        }
    }

    CGFloat toggleWidth = toggle.bounds.size.width;
    if (toggleWidth <= 0) { toggleWidth = 51.0; }
    CGFloat toggleHeight = toggle.bounds.size.height;
    if (toggleHeight <= 0) { toggleHeight = 31.0; }
    toggle.frame = CGRectMake(width - toggleWidth - 10,
                              (kSwitchRowHeight - toggleHeight) / 2.0,
                              toggleWidth, toggleHeight);
    *y += kSwitchRowHeight + kSwitchRowGap;
}

- (void)layoutSliderGroup:(UISlider *)slider x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width
{
    UIView *group = slider.superview;
    group.hidden = NO;
    group.frame = CGRectMake(x, *y, width, kSliderGroupHeight);
    for (UIView *sub in group.subviews) {
        if (sub.tag == 1) { sub.frame = CGRectMake(0, 0, width / 2.0, 14); }
        if (sub.tag == 2) { sub.frame = CGRectMake(width / 2.0, 0, width / 2.0, 14); }
    }
    slider.frame = CGRectMake(0, 16, width, 24);
    *y += kSliderGroupHeight + kSliderGroupGap;
}

#pragma mark - Действия панели

- (void)closePanel
{
    if (!_panelOpen) { return; }
    [self togglePanel];
}

- (void)tabTapped:(UIButton *)sender
{
    [self selectTab:sender.tag - 100];
}

- (void)selectTab:(NSInteger)tab
{
    _tab = tab;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    _scroll.contentOffset = CGPointZero;
}

/// Распознаватели жестов больше НЕ вешаем — и это важно.
///
/// Касания оверлея разбираются ТОЛЬКО потоком HID (handleRawTouchPhase:...).
/// Пока сюда ещё вешались UITapGestureRecognizer, одно и то же нажатие
/// обрабатывалось ДВАЖДЫ: распознавателем и потоком. Переключатель успевал
/// включиться и тут же выключиться, панель — открыться и закрыться. Снаружи это
/// выглядело как «нажимаю, а ничего не происходит» и «меню баганое».
- (void)addTapGesture:(UIView *)target action:(SEL)action
{
    (void)target;
    (void)action;
}

/// Один обработчик для простых «кнопок» панели: вкладки, unload.
/// Все действия идемпотентны, поэтому совпадение жеста и target
/// безвредно.
- (void)panelControlTapped:(UITapGestureRecognizer *)gesture
{
    UIView *view = gesture.view;
    AscentHUDLog(@"[gesture] панель: нажатие на %@ (tag=%ld)",
                 NSStringFromClass([view class]), (long)view.tag);
    if (view == _unloadButton) { [self unloadTapped]; return; }
    if (view.tag >= 100 && view.tag < 100 + (NSInteger)_tabButtons.count) { [self selectTab:view.tag - 100]; }
}

#pragma mark - Прокрутка (диагностика)

// Обработчики ниже только пишут в журнал: по ним видно, начиналась ли
// прокрутка меню и дожила ли она до конца — в паре с [touch] это показывает,
// на каком шаге всё обрывается, если меню «пропадает» при протяжке.

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    AscentHUDLog(@"[gesture] прокрутка меню: началась (смещение y=%.0f)",
                 scrollView.contentOffset.y);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    AscentHUDLog(@"[gesture] прокрутка меню: палец отпущен (деселерация=%d, y=%.0f)",
                 (int)decelerate, scrollView.contentOffset.y);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    AscentHUDLog(@"[gesture] прокрутка меню: остановилась (y=%.0f)", scrollView.contentOffset.y);
}



- (void)unloadTapped
{
    AscentHUDLog(@"HUD: unload — гасим оверлей");
    AscentRemovePIDFile();
    exit(0);
}

#pragma mark - Игровые настройки

- (UISwitch *)switchInRow:(UIView *)row
{
    for (UIView *sub in row.subviews) {
        if ([sub isKindOfClass:[UISwitch class]]) { return (UISwitch *)sub; }
    }
    return nil;
}

- (UISlider *)sliderInGroup:(UIView *)group
{
    for (UIView *sub in group.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) { return (UISlider *)sub; }
    }
    return nil;
}

/// Тап по строке переключает её свитч — состояние двигает только наш жест.
- (void)switchRowTapped:(UITapGestureRecognizer *)gesture
{
    UISwitch *toggle = [self switchInRow:gesture.view];
    if (toggle == nil) { return; }
    toggle.on = !toggle.on;
    AscentHUDLog(@"[gesture] %@ -> %d", toggle.accessibilityIdentifier, (int)toggle.on);
    [self switchChanged:toggle];
}

/// Тап или протяжка по строке двигают слайдер ровно под пальцем: значение
/// считаем из точки касания, минуя обработку касаний самим UISlider.
- (void)sliderRowTouched:(UIGestureRecognizer *)gesture
{
    UISlider *slider = [self sliderInGroup:gesture.view];
    if (slider == nil) { return; }

    CGPoint point = [gesture locationInView:slider];
    CGFloat width = MAX(slider.bounds.size.width, 1.0);
    CGFloat ratio = MIN(MAX(point.x / width, 0.0), 1.0);
    slider.value = slider.minimumValue + (float)(ratio * (slider.maximumValue - slider.minimumValue));
    [self updateSliderLabel:slider.accessibilityIdentifier];

    // В общий файл пишем только в конце жеста: пока палец на экране слайдер
    // просто едет и показывает текущее значение.
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        AscentHUDLog(@"[gesture] %@ = %.2f", slider.accessibilityIdentifier, slider.value);
        [self sliderChanged:slider];
    }
}

- (void)reloadCheatControls
{
    for (UISwitch *toggle in _switches) {
        NSString *key = toggle.accessibilityIdentifier;
        toggle.on = HUDOverlayFlag(key, HUDSwitchDefault(key));
    }
    for (UISlider *slider in _sliders) {
        NSString *key = slider.accessibilityIdentifier;
        [self configureSlider:slider forKey:key];
        slider.value = (float)HUDOverlayNumber(key, slider.value);
        [self updateSliderLabel:key];
    }
    [self refreshGameProcess];
}

- (void)configureSlider:(UISlider *)slider forKey:(NSString *)key
{
    if ([key isEqualToString:@"cheat.fov"]) {
        slider.minimumValue = 20; slider.maximumValue = 400; slider.value = 120;
    } else if ([key isEqualToString:@"cheat.smooth"]) {
        slider.minimumValue = 1; slider.maximumValue = 20; slider.value = 4;
    } else {
        slider.minimumValue = 0; slider.maximumValue = 300; slider.value = 60;
    }
}

- (NSString *)suffixForKey:(NSString *)key
{
    if ([key isEqualToString:@"cheat.fov"]) { return @"px"; }
    if ([key isEqualToString:@"cheat.smooth"]) { return @"x"; }
    return @"мс";
}

- (void)updateSliderLabel:(NSString *)key
{
    UILabel *label = _sliderValueLabels[key];
    if (label == nil) { return; }
    UISlider *slider = nil;
    for (UISlider *candidate in _sliders) {
        if ([candidate.accessibilityIdentifier isEqualToString:key]) { slider = candidate; break; }
    }
    label.text = [NSString stringWithFormat:@"%d%@", (int)lroundf(slider.value), [self suffixForKey:key]];
}

- (void)switchChanged:(UISwitch *)sender
{
    HUDOverlaySetFlag(sender.accessibilityIdentifier, sender.isOn);
}

- (void)sliderChanged:(UISlider *)sender
{
    HUDOverlaySetNumber(sender.accessibilityIdentifier, sender.value);
    [self updateSliderLabel:sender.accessibilityIdentifier];
}

- (void)refreshGameProcess
{
    int pid = AscentGameFindProcess(@"standoff");
    _gameProcLabel.text = pid > 0 ? [NSString stringWithFormat:@"процесс: pid %d", pid]
                                  : @"процесс не найден";
}

#pragma mark - Ориентация (реализация)

- (void)startOrientationObserver
{
    Class observerClass = objc_getClass("FBSOrientationObserver");
    if (observerClass != Nil) {
        id<HUDOrientationObserving> observer = (id<HUDOrientationObserving>)[[observerClass alloc] init];
        __weak HUDOverlayView *weakSelf = self;
        [observer setHandler:^(id update) {
            NSNumber *rawOrientation = [update valueForKey:@"orientation"];
            NSNumber *rawDuration = [update valueForKey:@"duration"];
            UIInterfaceOrientation orientation =
                (UIInterfaceOrientation)(rawOrientation != nil ? rawOrientation.integerValue
                                                               : UIInterfaceOrientationPortrait);
            NSTimeInterval duration = rawDuration != nil ? rawDuration.doubleValue : 0.28;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyOrientation:orientation duration:duration];
            });
        }];
        _orientationObserver = observer;
        AscentHUDLog(@"HUD: ориентация через FBSOrientationObserver");
        return;
    }

    // Запасной путь, если приватного наблюдателя нет: публичные уведомления.
    _usesDeviceOrientationFallback = YES;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationChanged:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    AscentHUDLog(@"HUD: ориентация через UIDevice (запасной путь)");
}

- (void)deviceOrientationChanged:(NSNotification *)note
{
    UIInterfaceOrientation orientation;
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationPortrait:           orientation = UIInterfaceOrientationPortrait; break;
        case UIDeviceOrientationPortraitUpsideDown: orientation = UIInterfaceOrientationPortraitUpsideDown; break;
        // У устройства и интерфейса ландшафты «зеркальные» — так у iOS.
        case UIDeviceOrientationLandscapeLeft:      orientation = UIInterfaceOrientationLandscapeRight; break;
        case UIDeviceOrientationLandscapeRight:     orientation = UIInterfaceOrientationLandscapeLeft; break;
        default: return;
    }
    [self applyOrientation:orientation duration:0.28];
}

- (void)applyOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    if (orientation == UIInterfaceOrientationUnknown || orientation == _orientation) { return; }
    _orientation = orientation;
    AscentHUDLog(@"HUD: ориентация -> %ld", (long)orientation);

    // Пересобираем раскладку внутри анимации: и слой, и квадрат, и панель
    // поворачиваются/переезжают одним движением.
    [UIView animateWithDuration:(duration > 0.01 ? duration : 0.28)
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        [self layoutSubviews];
    } completion:nil];
}

- (void)dealloc
{
    if (_usesDeviceOrientationFallback) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    } else {
        [_orientationObserver invalidate];
    }
}

@end
