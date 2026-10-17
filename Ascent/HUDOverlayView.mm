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
    BOOL _triggerDragging;
    CGPoint _triggerDragStart;

    // Панель
    UIView *_panel;
    UIView *_panelHeader;
    UILabel *_panelTitle;
    UIButton *_panelClose;
    NSMutableArray<UIButton *> *_tabButtons;
    UIScrollView *_scroll;
    UIView *_mainView;
    UIView *_miscView;
    UIView *_gameView;
    UILabel *_statusLabel;
    UIButton *_telegramButton;
    UIButton *_unloadButton;
    UILabel *_gameProcLabel;
    NSMutableArray<UISwitch *> *_switches;
    NSMutableArray<UISlider *> *_sliders;
    NSMutableDictionary<NSString *, UILabel *> *_sliderValueLabels;
    CGSize _panelOffset;
    BOOL _panelDragging;
    BOOL _panelOpen;
    NSInteger _tab;
}

#pragma mark - Создание

+ (instancetype)overlayForWindow:(UIWindow *)window
{
    HUDOverlayView *overlay = [[HUDOverlayView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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

    [self buildTrigger];
    [self buildPanel];
    [self startOrientationObserver];

    // Сообщаем приложению, что квадрат рисует HUD и дублировать его в app не
    // нужно. Приложение покажет свой запасной квадрат, только если этой метки
    // нет (то есть HUD-оверлей не поднялся).
    HUDOverlaySetFlag(@"hud.overlay", YES);

    _trigger.hidden = NO;
    _trigger.layer.opacity = 1.0f;

    AscentHUDLog(@"HUD: UIKit-оверлей создан, bounds=%@", NSStringFromCGRect(frame));
    return self;
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
    if (!_triggerDragging) { [self layoutTrigger]; }
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

- (CGFloat)safeTop
{
    return MIN(MAX(self.safeAreaInsets.top, 10.0), 44.0);
}

- (CGFloat)safeBottom
{
    return MIN(MAX(self.safeAreaInsets.bottom, 10.0), 34.0);
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

    // ВАЖНО: тап и перетаскивание — РАЗНЫЕ жесты. UIPanGestureRecognizer
    // срабатывает только когда палец сдвинулся, поэтому обычное нажатие он
    // вообще не замечал: квадрат «не нажимался». Тап ловим отдельным
    // UITapGestureRecognizer, а панорама остаётся для переноса.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(triggerTapped:)];
    [_trigger addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(triggerPanned:)];
    [_trigger addGestureRecognizer:pan];

    [_stage addSubview:_trigger];
}

- (void)triggerTapped:(UITapGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self togglePanel];
    }
}

- (void)triggerPanned:(UIPanGestureRecognizer *)gesture
{
    // Координаты считаем в пространстве _stage (а не self): слой повёрнут под
    // ориентацию, и в повёрнутых координатах перетаскивание должно идти по
    // пальцу, а не «поперёк».
    CGPoint t = [gesture translationInView:_stage];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        _triggerDragging = NO;
        _triggerDragStart = _trigger.center;
        return;
    }

    if (gesture.state == UIGestureRecognizerStateChanged) {
        if (t.x * t.x + t.y * t.y > 25.0) { _triggerDragging = YES; }
        if (_triggerDragging) {
            CGPoint center = CGPointMake(_triggerDragStart.x + t.x, _triggerDragStart.y + t.y);
            _trigger.center = [self clampTriggerCenter:center];
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        if (_triggerDragging) {
            CGPoint base = [self triggerBaseCenter];
            CGPoint center = [self clampTriggerCenter:_trigger.center];
            _triggerOffset = CGSizeMake(center.x - base.x, center.y - base.y);
            HUDOverlaySetNumber(@"trigger.x", _triggerOffset.width);
            HUDOverlaySetNumber(@"trigger.y", _triggerOffset.height);
            _triggerDragging = NO;
        }
        // Тап здесь больше не обрабатываем — это делает triggerTapped:.
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

    UIPanGestureRecognizer *headerPan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(panelHeaderPanned:)];
    [_panelHeader addGestureRecognizer:headerPan];

    UILabel *headerLine = [[UILabel alloc] initWithFrame:CGRectZero];
    headerLine.backgroundColor = HUDLine();
    headerLine.tag = 0;
    [_panel addSubview:headerLine];

    // Вкладки
    _tabButtons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[ @"main", @"misc", @"game" ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *button = [self makeFlatButton:titles[i]];
        button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        button.tag = 100 + i;
        button.layer.cornerRadius = 0.0;
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:button];
        [_tabButtons addObject:button];
    }

    UILabel *tabLine = [[UILabel alloc] initWithFrame:CGRectZero];
    tabLine.backgroundColor = HUDLine();
    tabLine.tag = 1;
    [_panel addSubview:tabLine];

    // Прокручиваемая область содержимого — вкладка «game» длиннее остальных
    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    [_panel addSubview:_scroll];

    [self buildMainTab];
    [self buildMiscTab];
    [self buildGameTab];

    [_stage addSubview:_panel];
}

- (void)buildMainTab
{
    _mainView = [[UIView alloc] initWithFrame:CGRectZero];
    [_scroll addSubview:_mainView];

    _statusLabel = HUDLabel(@"загрузчик активен", 13, UIFontWeightSemibold);
    [_mainView addSubview:_statusLabel];

    _telegramButton = [self makeFlatButton:@"t.me/ascentios"];
    _telegramButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _telegramButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    _telegramButton.layer.cornerRadius = 12.0;
    _telegramButton.layer.borderWidth = 1.0;
    _telegramButton.layer.borderColor = HUDLine().CGColor;
    [_telegramButton addTarget:self action:@selector(openTelegram) forControlEvents:UIControlEventTouchUpInside];
    [_mainView addSubview:_telegramButton];
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
        label.frame = CGRectMake(14, 0, 160, 36);
        label.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        [row addSubview:label];

        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        toggle.accessibilityIdentifier = switchKeys[i];
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [row addSubview:toggle];

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
        [group addSubview:slider];

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
    if (tab == 2) { return 376.0; }
    return 88.0;
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

    if (!_panelDragging) {
        // Не даём панели уехать за пределы безопасной зоны.
        CGRect area = [self triggerArea];
        CGFloat halfW = panelWidth / 2.0;
        CGFloat halfH = kPanelHeight / 2.0;
        CGFloat minX = area.origin.x + halfW;
        CGFloat maxX = MAX(area.origin.x + area.size.width - halfW, minX);
        CGFloat minY = area.origin.y + halfH;
        CGFloat maxY = MAX(area.origin.y + area.size.height - halfH, minY);
        center.x = MIN(MAX(center.x, minX), maxX);
        center.y = MIN(MAX(center.y, minY), maxY);

        _panel.bounds = CGRectMake(0, 0, panelSize.width, panelSize.height);
        _panel.center = center;
    }
    _panel.layer.cornerRadius = 20.0;

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

    CGFloat tabWidth = w / 3.0;
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

    _mainView.frame = CGRectMake(0, 0, containerSize.width, 88.0);
    _miscView.frame = CGRectMake(0, 0, containerSize.width, 88.0);
    _gameView.frame = CGRectMake(0, 0, containerSize.width, 376.0);
    _scroll.contentSize = containerSize;

    [self layoutMainTab:(_tab == 0)];
    [self layoutMiscTab:(_tab == 1)];
    [self layoutGameTab:(_tab == 2)];
}

- (void)layoutMainTab:(BOOL)visible
{
    _mainView.hidden = !visible;
    CGFloat w = _mainView.bounds.size.width;
    _statusLabel.frame = CGRectMake(16, 16, w - 32, 20);
    _telegramButton.frame = CGRectMake(16, 48, w - 32, 46);
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
        row.frame = CGRectMake(16, y, rowWidth, 36);
        CGFloat toggleWidth = toggle.bounds.size.width;
        if (toggleWidth <= 0) { toggleWidth = 51.0; }
        toggle.frame = CGRectMake(rowWidth - toggleWidth - 10, (36 - toggle.bounds.size.height) / 2.0,
                                  toggleWidth, toggle.bounds.size.height);
        y += 36 + 8;
    }

    y += 2.0;
    for (UISlider *slider in _sliders) {
        UIView *group = slider.superview;
        group.frame = CGRectMake(16, y, rowWidth, 40);
        for (UIView *sub in group.subviews) {
            if (sub.tag == 1) { sub.frame = CGRectMake(0, 0, rowWidth / 2.0, 14); }
            if (sub.tag == 2) { sub.frame = CGRectMake(rowWidth / 2.0, 0, rowWidth / 2.0, 14); }
        }
        slider.frame = CGRectMake(0, 16, rowWidth, 24);
        y += 40 + 6;
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

- (void)panelHeaderPanned:(UIPanGestureRecognizer *)gesture
{
    CGPoint t = [gesture translationInView:_stage];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        _panelDragging = YES;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        _panel.center = CGPointMake(_panel.center.x + t.x, _panel.center.y + t.y);
        [gesture setTranslation:CGPointZero inView:_stage];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        _panelDragging = NO;
        CGFloat panelWidth = _panel.bounds.size.width;
        CGRect stage = [self stageBounds];
        CGFloat baseX = (stage.size.width - panelWidth) / 2.0;
        CGFloat baseY = stage.size.height * 0.74 - kPanelHeight / 2.0;
        _panelOffset = CGSizeMake(_panel.center.x - (baseX + panelWidth / 2.0),
                                  _panel.center.y - (baseY + kPanelHeight / 2.0));
        HUDOverlaySetNumber(@"hud.panel.x", _panelOffset.width);
        HUDOverlaySetNumber(@"hud.panel.y", _panelOffset.height);
        [self setNeedsLayout];
    }
}

- (void)openTelegram
{
    NSURL *url = [NSURL URLWithString:@"https://t.me/ascentios"];
    if (url == nil) { return; }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)unloadTapped
{
    AscentHUDLog(@"HUD: unload — гасим оверлей");
    AscentRemovePIDFile();
    exit(0);
}

#pragma mark - Игровые настройки

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
