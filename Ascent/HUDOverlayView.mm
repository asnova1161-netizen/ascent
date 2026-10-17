#import "HUDOverlayView.h"
#import "HUDHelper.h"
#import "GameMemory.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <math.h>

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
static UIColor *HUDLine(void)      { return [UIColor colorWithWhite:1.0 alpha:0.12]; }
static UIColor *HUDDim(void)       { return [UIColor colorWithWhite:1.0 alpha:0.55]; }
static UIColor *HUDGray(void)      { return HUDColor(0.36, 0.36, 0.40); }

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
static const CGFloat kPanelWidthMax  = 300.0;
static const CGFloat kPanelHeight    = 260.0;
static const CGFloat kHeaderHeight   = 44.0;
static const CGFloat kTabBarHeight   = 40.0;
static const CGFloat kMargin         = 10.0;
static const CGFloat kTriggerInset   = 14.0;

// Высота вкладок: строка переключателя, строка слайдера и содержимое вкладки
// «combot». Держим константами, потому что одни и те же числа нужны и сборке
// строк, и раскладке, и размеру прокручиваемой области.
static const CGFloat kSwitchRowHeight  = 40.0;
static const CGFloat kSwitchRowGap     = 8.0;
static const CGFloat kSliderGroupHeight = 40.0;
static const CGFloat kSliderGroupGap   = 6.0;
static const CGFloat kGameContentHeight = 410.0;

// Что тянет палец в потоке касаний (см. handleRawTouchPhase:...).
typedef NS_ENUM(NSInteger, HUDRawDragTarget) {
    HUDRawDragNone = 0,
    HUDRawDragTrigger,
    HUDRawDragPanel,
    HUDRawDragScroll,
};

// Единственный живой оверлей процесса (см. +currentOverlay). Ссылку держим
// статиком: владеет оверлеем окно HUD, а статик нужен лишь чтобы поток
// HID-событий мог найти оверлей, не перебирая окна. Процесс одноразовый, так
// что держать оверлей до конца жизни процесса можно.
static HUDOverlayView *_hudCurrentOverlay = nil;

// Делегат прокрутки нужен только ради журнала: по нему видно, начиналась ли
// прокрутка меню и дожила ли она до конца.
@interface HUDOverlayView () <UIScrollViewDelegate>
@end

@implementation HUDOverlayView
{
    // Слой, который поворачивается вслед за устройством: в нём лежат квадрат и
    // панель. Само вью оверлея остаётся ровным контейнером на всё окно.
    UIView *_stage;
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
    UIButton *_panelClose;
    NSMutableArray<UIButton *> *_tabButtons;
    UIScrollView *_scroll;
    UIView *_miscView;
    UIView *_gameView;
    UIButton *_unloadButton;
    UILabel *_gameProcLabel;
    NSMutableArray<UISwitch *> *_switches;
    NSMutableArray<UISlider *> *_sliders;
    NSMutableDictionary<NSString *, UILabel *> *_sliderValueLabels;
    CGSize _panelOffset;
    BOOL _panelOpen;
    NSInteger _tab;

    // Перетаскивание/прокрутка прямо от потока касаний (тап работает и через
    // синтетические UITouch, а движение — только так).
    HUDRawDragTarget _rawTarget;
    CGPoint _rawStart;          // точка начала в координатах _stage
    CGPoint _rawStartCenter;    // позиция квадрата/панели на момент начала
    CGPoint _rawStartOffset;    // contentOffset на момент начала
    BOOL _rawMoved;             // палец реально сдвинулся (а не просто тап)
    NSTimeInterval _rawLastTime; // время последнего события потока
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

/// Кто под пальцем. Считаем по своей иерархии (а не по окну): окно
/// accessibility-оверлея от системы касаний не получает, но hitTest по нашим
/// же вью работает всегда.
- (HUDRawDragTarget)rawDragTargetAtPoint:(CGPoint)point
{
    UIView *hit = [self hitTest:point withEvent:nil];
    if (hit == nil) { return HUDRawDragNone; }

    if (hit == _trigger || [hit isDescendantOfView:_trigger]) { return HUDRawDragTrigger; }
    if (hit == _panelHeader || [hit isDescendantOfView:_panelHeader]) { return HUDRawDragPanel; }
    if (hit == _scroll || [hit isDescendantOfView:_scroll]) { return HUDRawDragScroll; }
    return HUDRawDragNone;
}

/// Начинает (или заново подхватывает после паузы) жест от указанной точки.
/// Координаты — точка в своей иерархии (для hitTest) и точка в слое _stage (для
/// смещения с учётом поворота экрана).
- (void)beginRawDragAtPoint:(CGPoint)point stagePoint:(CGPoint)stagePoint
{
    _rawTarget = [self rawDragTargetAtPoint:point];
    _rawStart = stagePoint;
    _rawStartCenter = (_rawTarget == HUDRawDragTrigger) ? _trigger.center : _panel.center;
    _rawStartOffset = _scroll.contentOffset;
    _rawMoved = NO;
    _rawLastTime = [[NSProcessInfo processInfo] systemUptime];
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

    // Долгая тишина между событиями — палец замер или событие «подъёма»
    // потерялось. Жест тогда завершён: иначе старое начало осталось бы висеть, и
    // первый же сдвиг утащил бы квадрат к прежнему месту («телепорт»).
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    BOOL stale = (_rawTarget != HUDRawDragNone) && (now - _rawLastTime > 0.35);

    if (phase == UITouchPhaseBegan) {
        [self beginRawDragAtPoint:point stagePoint:stagePoint];
        return;
    }

    if (phase == UITouchPhaseStationary) { return; }

    if (phase == UITouchPhaseMoved) {
        if (_rawTarget == HUDRawDragNone) { return; }

        if (stale) {
            // Подхватываем жест заново от текущей точки: квадрат и панель
            // остаются под пальцем и никуда не прыгают.
            [self beginRawDragAtPoint:point stagePoint:stagePoint];
            return;
        }

        CGPoint delta = CGPointMake(stagePoint.x - _rawStart.x, stagePoint.y - _rawStart.y);
        // Пока палец не сдвинулся на несколько точек, это ещё тап: иначе дрожь
        // руки при нажатии уводила бы квадрат с места (и он бы «уползал»).
        if (!_rawMoved && (delta.x * delta.x + delta.y * delta.y) < 36.0) { return; }
        if (!_rawMoved) {
            _rawMoved = YES;
            AscentHUDLog(@"[gesture] поток: тянем %@",
                         _rawTarget == HUDRawDragTrigger ? @"квадрат" :
                         (_rawTarget == HUDRawDragPanel ? @"панель" : @"содержимое вкладки"));
        }
        [self applyRawDragDelta:delta];
        return;
    }

    // Ended / Cancelled: фиксируем результат (позицию или смещение прокрутки).
    if (_rawMoved) {
        [self commitRawDrag];
    }
    _rawTarget = HUDRawDragNone;
    _rawMoved = NO;
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
        CGFloat panelWidth = _panel.bounds.size.width;
        CGPoint center = CGPointMake(_rawStartCenter.x + delta.x, _rawStartCenter.y + delta.y);
        center = [self clampPanelCenter:center width:panelWidth];
        _panel.center = center;
        _panelOffset = [self panelOffsetForCenter:center width:panelWidth];
        return;
    }

    if (_rawTarget == HUDRawDragScroll) {
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
        CGFloat panelWidth = _panel.bounds.size.width;
        CGPoint center = [self clampPanelCenter:_panel.center width:panelWidth];
        _panelOffset = [self panelOffsetForCenter:center width:panelWidth];
        HUDOverlaySetNumber(@"hud.panel.x", _panelOffset.width);
        HUDOverlaySetNumber(@"hud.panel.y", _panelOffset.height);
        AscentHUDLog(@"[gesture] панель: перетаскивание закончилось, смещение=(%.0f, %.0f)",
                     _panelOffset.width, _panelOffset.height);
        return;
    }

    if (_rawTarget == HUDRawDragScroll) {
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

    // ВАЖНО: тап и перетаскивание — РАЗНЫЕ пути. UIPanGestureRecognizer
    // срабатывает только когда палец сдвинулся, поэтому обычное нажатие он
    // вообще не замечал: квадрат «не нажимался». Тап ловим отдельным
    // UITapGestureRecognizer, а перенос ведёт поток касаний напрямую
    // (см. handleRawTouchPhase:...) — на синтетических UITouch панорама
    // движения не распознаёт.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(triggerTapped:)];
    [_trigger addGestureRecognizer:tap];

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
    // Геометрия в журнал: по ней сразу видно, попадает ли панель на экран.
    AscentHUDLog(@"HUD: панель frame=%@, stage=%@, смещение=(%.0f, %.0f), квадрат center=%@",
                 NSStringFromCGRect(_panel.frame), NSStringFromCGRect([self stageBounds]),
                 _panelOffset.width, _panelOffset.height, NSStringFromCGPoint(_trigger.center));
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
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidthMax, kPanelHeight)];
    _panel.backgroundColor = HUDFill();
    _panel.layer.cornerRadius = 20.0;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = HUDLine().CGColor;
    _panel.hidden = YES;

    // Шапка: за неё таскаем, в ней же крестик.
    _panelHeader = [[UIView alloc] initWithFrame:CGRectZero];
    _panelHeader.backgroundColor = [UIColor clearColor];
    [_panel addSubview:_panelHeader];

    _panelTitle = HUDLabel(@"ascent", 15, UIFontWeightHeavy);
    [_panelHeader addSubview:_panelTitle];

    _panelClose = [UIButton buttonWithType:UIButtonTypeSystem];
    [_panelClose setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    _panelClose.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _panelClose.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _panelClose.layer.cornerRadius = 14.0;
    [_panelClose addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [_panelHeader addSubview:_panelClose];

    [self addTapGesture:_panelClose action:@selector(panelControlTapped:)];

    UILabel *headerLine = [[UILabel alloc] initWithFrame:CGRectZero];
    headerLine.backgroundColor = HUDLine();
    headerLine.tag = 0;
    [_panel addSubview:headerLine];

    // Вкладки
    _tabButtons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[ @"misc", @"combot" ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *button = [self makeFlatButton:titles[i]];
        button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        button.tag = 100 + i;
        button.layer.cornerRadius = 0.0;
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addTapGesture:button action:@selector(panelControlTapped:)];
        [_panel addSubview:button];
        [_tabButtons addObject:button];
    }

    UILabel *tabLine = [[UILabel alloc] initWithFrame:CGRectZero];
    tabLine.backgroundColor = HUDLine();
    tabLine.tag = 1;
    [_panel addSubview:tabLine];

    // Прокручиваемая область содержимого — вкладка «combot» длиннее остальных
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
    [_panel addSubview:_scroll];

    [self buildMiscTab];
    [self buildGameTab];

    [_stage addSubview:_panel];
}

- (void)buildMiscTab
{
    _miscView = [[UIView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:_miscView];

    _unloadButton = [self makeFlatButton:@"unload"];
    _unloadButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightHeavy];
    _unloadButton.backgroundColor = HUDGray();
    _unloadButton.layer.cornerRadius = 12.0;
    [_unloadButton addTarget:self action:@selector(unloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addTapGesture:_unloadButton action:@selector(panelControlTapped:)];
    [_miscView addSubview:_unloadButton];

    UILabel *caption = HUDLabel(@"стоп лоадера, меню остаётся", 11.5, UIFontWeightRegular);
    caption.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    caption.tag = 1;
    [_miscView addSubview:caption];
}

- (void)buildGameTab
{
    _gameView = [[UIView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:_gameView];

    UILabel *title = HUDLabel(@"standoff 2", 13, UIFontWeightRegular);
    title.textColor = HUDDim();
    title.tag = 1;
    [_gameView addSubview:title];

    _switches = [NSMutableArray array];
    NSArray<NSString *> *switchKeys = @[ @"cheat.esp", @"cheat.aimbot", @"cheat.trigger" ];
    NSArray<NSString *> *switchTitles = @[ @"esp", @"aimbot", @"triggerbot" ];
    for (NSInteger i = 0; i < (NSInteger)switchKeys.count; i++) {
        UIView *row = HUDRoundedBox(12.0, [UIColor colorWithWhite:1.0 alpha:0.07]);
        UILabel *label = HUDLabel(switchTitles[i], 13, UIFontWeightMedium);
        // Кадр подписи задаёт layoutGameTab (ровно по высоте строки). Здесь
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
        [_gameView addSubview:row];
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
        slider.minimumTrackTintColor = [UIColor whiteColor];
        slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        // Слайдер двигает только жест по строке (см. комментарий про переключатель):
        // значение считаем из точки касания, минуя обработку касаний самим UISlider.
        // Жест только ТАП — иначе он воюет со скроллом вкладки за pan-жест.
        slider.userInteractionEnabled = NO;
        [group addSubview:slider];

        [self addTapGesture:group action:@selector(sliderRowTouched:)];

        [_gameView addSubview:group];
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
    [_gameProcLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(refreshGameProcess)]];
    [_gameView addSubview:_gameProcLabel];

    UILabel *caption = HUDLabel(@"память игры читает HUD-процесс: переключатели выше только включают доступ к ней",
                                10.5, UIFontWeightRegular);
    caption.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    caption.numberOfLines = 0;
    caption.tag = 4;
    [_gameView addSubview:caption];
}

#pragma mark - Панель (раскладка)

- (CGFloat)contentHeightForTab:(NSInteger)tab
{
    if (tab == 1) { return kGameContentHeight; }
    return 88.0;
}

/// Держим панель внутри безопасной зоны. Считается всегда — и во время
/// перетаскивания тоже: уехать за край экрана панель не может в принципе, а
/// любой повторный расчёт раскладки даёт ровно ту же точку (перетаскивание
/// двигало панель «рывками» именно потому, что раскладка откатывала её назад).
- (CGPoint)clampPanelCenter:(CGPoint)center width:(CGFloat)panelWidth
{
    CGRect area = [self triggerArea];
    CGFloat halfW = panelWidth / 2.0;
    CGFloat halfH = kPanelHeight / 2.0;
    CGFloat minX = area.origin.x + halfW;
    CGFloat maxX = MAX(area.origin.x + area.size.width - halfW, minX);
    CGFloat minY = area.origin.y + halfH;
    CGFloat maxY = MAX(area.origin.y + area.size.height - halfH, minY);
    center.x = MIN(MAX(center.x, minX), maxX);
    center.y = MIN(MAX(center.y, minY), maxY);
    return center;
}

/// Смещение панели от базовой позиции — то, что сохраняется в общий файл.
- (CGSize)panelOffsetForCenter:(CGPoint)center width:(CGFloat)panelWidth
{
    CGRect stage = [self stageBounds];
    CGFloat baseX = (stage.size.width - panelWidth) / 2.0;
    CGFloat baseY = stage.size.height * 0.74 - kPanelHeight / 2.0;
    return CGSizeMake(center.x - (baseX + panelWidth / 2.0),
                      center.y - (baseY + kPanelHeight / 2.0));
}

- (void)layoutPanel
{
    if (_panel == nil) { return; }

    CGRect stage = [self stageBounds];
    CGFloat panelWidth = MIN(MAX(stage.size.width - 44.0, 0), kPanelWidthMax);
    CGSize panelSize = CGSizeMake(panelWidth, kPanelHeight);
    CGFloat baseX = (stage.size.width - panelWidth) / 2.0;
    CGFloat baseY = stage.size.height * 0.74 - kPanelHeight / 2.0;

    CGPoint center = CGPointMake(baseX + panelWidth / 2.0 + _panelOffset.width,
                                 baseY + kPanelHeight / 2.0 + _panelOffset.height);
    center = [self clampPanelCenter:center width:panelWidth];

    _panel.bounds = CGRectMake(0, 0, panelSize.width, panelSize.height);
    _panel.center = center;
    _panel.layer.cornerRadius = 20.0;
    _panel.layer.masksToBounds = YES;

    CGFloat w = panelSize.width;
    CGFloat h = panelSize.height;

    _panelHeader.frame = CGRectMake(0, 0, w, kHeaderHeight);
    _panelTitle.frame = CGRectMake(14, 0, w - 60, kHeaderHeight);
    _panelClose.frame = CGRectMake(w - 14 - 28, (kHeaderHeight - 28) / 2.0, 28, 28);
    _panelClose.layer.cornerRadius = 14.0;

    for (UIView *sub in _panel.subviews) {
        if ([sub isKindOfClass:[UILabel class]] && sub.tag == 0) {
            sub.frame = CGRectMake(0, kHeaderHeight - 1, w, 1);
        } else if ([sub isKindOfClass:[UILabel class]] && sub.tag == 1) {
            sub.frame = CGRectMake(0, kHeaderHeight + kTabBarHeight - 1, w, 1);
        }
    }

    // Вкладок может быть меньше, чем три (сейчас misc и combot) — делим полосу
    // ровно на их число, иначе справа оставалась пустая треть.
    CGFloat tabWidth = w / (CGFloat)MAX((NSInteger)_tabButtons.count, 1);
    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        UIButton *button = _tabButtons[i];
        button.frame = CGRectMake(tabWidth * i, kHeaderHeight, tabWidth, kTabBarHeight);
        BOOL selected = (i == _tab);
        button.backgroundColor = selected ? [UIColor colorWithWhite:1.0 alpha:0.08] : [UIColor clearColor];
        [button setTitleColor:(selected ? [UIColor whiteColor] : HUDDim()) forState:UIControlStateNormal];
    }

    _scroll.frame = CGRectMake(0, kHeaderHeight + kTabBarHeight, w, h - kHeaderHeight - kTabBarHeight);

    CGFloat contentWidth = w;
    CGFloat contentHeight = [self contentHeightForTab:_tab];
    CGSize containerSize = CGSizeMake(contentWidth, contentHeight);

    _miscView.frame = CGRectMake(0, 0, containerSize.width, 88.0);
    _gameView.frame = CGRectMake(0, 0, containerSize.width, kGameContentHeight);
    _scroll.contentSize = containerSize;

    [self layoutMiscTab:(_tab == 0)];
    [self layoutGameTab:(_tab == 1)];
}



- (void)layoutMiscTab:(BOOL)visible
{
    _miscView.hidden = !visible;
    CGFloat w = _miscView.bounds.size.width;
    _unloadButton.frame = CGRectMake(16, 16, w - 32, 46);
    for (UIView *sub in _miscView.subviews) {
        if (sub.tag == 1) { sub.frame = CGRectMake(16, 70, w - 32, 18); }
    }
}

- (void)layoutGameTab:(BOOL)visible
{
    _gameView.hidden = !visible;
    CGFloat w = _gameView.bounds.size.width;
    CGFloat y = 14.0;

    for (UIView *sub in _gameView.subviews) {
        if (sub.tag == 1) { sub.frame = CGRectMake(16, y, w - 32, 18); }
    }
    y += 24.0;

    CGFloat rowWidth = w - 32.0;
    for (UISwitch *toggle in _switches) {
        UIView *row = toggle.superview;
        row.frame = CGRectMake(16, y, rowWidth, kSwitchRowHeight);

        // Подпись задаём ЯВНО и ровно по высоте строки: у UILabel иначе
        // «тянется» высота (autoresizing) от нулевого размера строки, и текст
        // уезжает ниже её середины — надписи esp/aimbot/triggerbot выглядели
        // сдвинутыми вниз.
        for (UIView *sub in row.subviews) {
            if ([sub isKindOfClass:[UILabel class]]) {
                sub.frame = CGRectMake(14, 0, rowWidth - 80.0, kSwitchRowHeight);
            }
        }

        CGFloat toggleWidth = toggle.bounds.size.width;
        if (toggleWidth <= 0) { toggleWidth = 51.0; }
        CGFloat toggleHeight = toggle.bounds.size.height;
        if (toggleHeight <= 0) { toggleHeight = 31.0; }
        toggle.frame = CGRectMake(rowWidth - toggleWidth - 10,
                                  (kSwitchRowHeight - toggleHeight) / 2.0,
                                  toggleWidth, toggleHeight);
        y += kSwitchRowHeight + kSwitchRowGap;
    }

    y += 2.0;
    for (UISlider *slider in _sliders) {
        UIView *group = slider.superview;
        group.frame = CGRectMake(16, y, rowWidth, kSliderGroupHeight);
        for (UIView *sub in group.subviews) {
            if (sub.tag == 1) { sub.frame = CGRectMake(0, 0, rowWidth / 2.0, 14); }
            if (sub.tag == 2) { sub.frame = CGRectMake(rowWidth / 2.0, 0, rowWidth / 2.0, 14); }
        }
        slider.frame = CGRectMake(0, 16, rowWidth, 24);
        y += kSliderGroupHeight + kSliderGroupGap;
    }

    y += 4.0;
    _gameProcLabel.frame = CGRectMake(16, y, rowWidth, 32);
    y += 32 + 10;

    for (UIView *sub in _gameView.subviews) {
        if (sub.tag == 4) { sub.frame = CGRectMake(16, y, rowWidth, 30); }
    }
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

/// Жесты вешаем на все «кнопки» панели дополнительно к target'ам: касания
/// оверлея доставляются синтезированными UITouch (см. HUDApp.mm), и с ними
/// надёжно срабатывают распознаватели жестов, а не раздача касаний UIControls —
/// именно на жестах целиком построено меню эталонного TrollSpeed.
- (void)addTapGesture:(UIView *)target action:(SEL)action
{
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
    [target addGestureRecognizer:tap];
}

/// Один обработчик для простых «кнопок» панели: крестик, вкладки, unload.
/// Все действия идемпотентны, поэтому совпадение жеста и target
/// безвредно.
- (void)panelControlTapped:(UITapGestureRecognizer *)gesture
{
    UIView *view = gesture.view;
    AscentHUDLog(@"[gesture] панель: нажатие на %@ (tag=%ld)",
                 NSStringFromClass([view class]), (long)view.tag);
    if (view == _panelClose) { [self closePanel]; return; }
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
        toggle.on = HUDOverlayFlag(toggle.accessibilityIdentifier, NO);
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
