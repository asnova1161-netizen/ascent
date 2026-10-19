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

/// Значение по умолчанию для строки меню. Под-опций ESP в меню больше нет
/// (остался только Enable): их старые значения в файле нормализуются при
/// подъёме оверлея (см. initWithFrame:), здесь по умолчанию всё выключено.
static BOOL HUDSwitchDefault(NSString *key)
{
    (void)key;
    return NO;
}

static void HUDOverlaySetFlag(NSString *key, BOOL value)
{
    HUDOverlaySetNumber(key, value ? 1 : 0);
}

#pragma mark - Конфиги (имя → набор настроек)

/// Отдельный файл конфигов: словарь «имя → {ключ → число}». Свой файл, а не
/// общий overlay.plist — там лежат позиции и служебные флаги, их не трогаем.
static NSString *AscentConfigsPath(void)
{
    NSString *dir = AscentStateDirectory();
    if (dir.length == 0) { dir = NSTemporaryDirectory(); }
    return [dir stringByAppendingPathComponent:@"ascent.configs.plist"];
}

static NSDictionary *AscentConfigsRead(void)
{
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:AscentConfigsPath()];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : @{};
}

static void AscentConfigsWrite(NSDictionary *dict)
{
    NSString *path = AscentConfigsPath();
    [dict writeToFile:path atomically:YES];
    chmod([path fileSystemRepresentation], 0666);
}

#pragma mark - Оформление

static UIColor *HUDColor(double r, double g, double b)
{
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

// Палитра — как в меню-эталоне (MY IMGUI): окно #242424, панельки #1a1a1a,
// красный акцент #ff1a1a (заголовок и активная вкладка берут цвет из
// палитры акцентов — см. HUDMenuAccent()).
//
// Тема меню (строка menu theme на вкладке Misc): dark по умолчанию, light —
// белая панель. Кэш читается из plist ОДИН раз при создании оверлея (см.
// init), дальше файл на кадрах раскладки не трогаем. Все хелперы ниже
// учитывают тему, поэтому сборка с «запасом» светлой темы сразу красится
// правильно, а смена темы просто перезовывает их поверх старых значений.
static BOOL sMenuLight = NO;
static UIColor *HUDFill(void)      { return sMenuLight ? [UIColor whiteColor]
                                                      : HUDColor(0.141176, 0.141176, 0.141176); }
static UIColor *HUDCard(void)      { return sMenuLight ? HUDColor(0.93, 0.93, 0.94)
                                                      : HUDColor(0.1, 0.1, 0.1); }
static UIColor *HUDAccent(void)    { return HUDColor(1.0, 0.1, 0.1); }
static UIColor *HUDLine(void)      { return [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.12]; }
static UIColor *HUDDim(void)       { return [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.55]; }
static UIColor *HUDGray(void)      { return sMenuLight ? HUDColor(0.90, 0.90, 0.92)
                                                      : HUDColor(0.36, 0.36, 0.40); }
// Основной текст меню: белый на тёмной теме, почти-чёрный на светлой.
static UIColor *HUDText(void)      { return [UIColor colorWithWhite:(sMenuLight ? 0.15 : 1.0) alpha:1.0]; }
// Полупрозрачная заливка (поле имени конфига, строки списка): на белой
// панели белый 0.07 не виден — берём чёрный 0.05.
static UIColor *HUDSoftFill(void)  { return [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0)
                                                              alpha:(sMenuLight ? 0.05 : 0.07)]; }
// Фон включённого тумблера: плотная заливка ОДИНАКОВАЯ в обеих темах, как на
// белой. На тёмной теме прежний светлый 0.85 почти совпадал со «выключенным»
// треком iOS (он на светлом фоне ≈ 0.91), и включённый тумблер выглядел без
// заливки; на белой панели 0.35 читался плотно — берём этот цвет везде.
static UIColor *HUDSwitchOn(void)  { return [UIColor colorWithWhite:0.35 alpha:1.0]; }
// Фон ВЫКЛЮЧЕННОГО тумблера: полупрозрачный серый текущей темы (по заказу —
// ЗАМЕТНО темнее прежнего: на тёмной панели белый 0.22 читался светлой
// плашкой, теперь 0.10; на белой карточке чёрный 0.20 почти не отличался от
// фона, теперь 0.30).
static UIColor *HUDSwitchOff(void) { return [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0)
                                                              alpha:(sMenuLight ? 0.30 : 0.10)]; }

// Зелёный для «своих» в ESP и для полоски здоровья.
static UIColor *HUDGreen(void)     { return HUDColor(0.22, 0.78, 0.36); }

// Акцентный цвет меню (вкладка Misc): хранится как СОСТАВЛЯЮЩИЕ HSV (оттенок,
// насыщенность, яркость) в plist — пикер на классической схеме HSV даёт выбор
// ЛЮБОГО цвета. Компоненты кэшируются в static: HUDOverlayNumber читает файл
// СИНХРОННО, а HUDMenuAccent() спрашивают на каждом кадре раскладки (цвет
// активной вкладки, полоска-индикатор, заголовок) — без кэша это было бы
// чтение файла десятки раз в секунду.
// Дефолтный цвет (по заказу) — приглушённый красно-коралловый #b04033:
// RGB (176, 64, 51) → HSV: H = 60·(13/125) = 6.24°, S = 125/176 = 0.7102,
// V = 176/255 = 0.6902.
static CGFloat sMenuAccentH = 6.24;    // оттенок, 0..360 (0 — красный)
static CGFloat sMenuAccentS = 0.7102;  // насыщенность, 0..1
static CGFloat sMenuAccentV = 0.6902;  // яркость, 0..1
// Есть ли цвет, ещё НЕ записанный в файл: во время перетаскивания его не
// пишем (см. HUDMenuAccentSetHSV), но закрытие пикера от этого не должно
// подтормаживать — запись нужна, только если перенос успели прервать.
static BOOL sMenuAccentSavePending = NO;

/// Читаем сохранённый цвет ровно ОДИН раз — при создании оверлея
/// (см. initWithFrame:). Дальше работает только кэш.
static void HUDMenuAccentLoad(void)
{
    static BOOL loaded = NO;
    if (loaded) { return; }
    loaded = YES;
    double h = HUDOverlayNumber(@"hud.accent.h", -1.0);
    double s = HUDOverlayNumber(@"hud.accent.s", -1.0);
    double v = HUDOverlayNumber(@"hud.accent.v", -1.0);
    if (h >= 0.0 && s >= 0.0 && v >= 0.0 && s <= 1.0 && v <= 1.0) {
        sMenuAccentH = (CGFloat)fmod(h, 360.0);
        if (sMenuAccentH < 0.0) { sMenuAccentH += 360.0; }
        sMenuAccentS = (CGFloat)s;
        sMenuAccentV = (CGFloat)v;
        return;
    }
    // Старый формат: индекс фиксированной палитры (ключ hud.accent) —
    // переводим его цвет в HSV, чтобы выбор не слетел при обновлении.
    static const CGFloat kOldPalette[][3] = {
        { 1.000, 0.100, 0.100 },  // 0 — красный
        { 1.000, 0.584, 0.000 },  // 1 — оранжевый
        { 0.188, 0.827, 0.345 },  // 2 — зелёный
        { 0.039, 0.518, 1.000 },  // 3 — синий
        { 0.686, 0.322, 0.871 },  // 4 — фиолетовый
    };
    NSInteger index = (NSInteger)HUDOverlayNumber(@"hud.accent", 0);
    if (index < 0 || index >= (NSInteger)(sizeof(kOldPalette) / sizeof(kOldPalette[0]))) {
        index = 0;
    }
    CGFloat hh = 0, ss = 0, vv = 0, aa = 0;
    UIColor *old = HUDColor(kOldPalette[index][0], kOldPalette[index][1], kOldPalette[index][2]);
    if ([old getHue:&hh saturation:&ss brightness:&vv alpha:&aa]) {
        sMenuAccentH = hh * 360.0;
        sMenuAccentS = ss;
        sMenuAccentV = vv;
    }
}

static UIColor *HUDMenuAccent(void)
{
    return [UIColor colorWithHue:sMenuAccentH / 360.0
                      saturation:sMenuAccentS
                      brightness:sMenuAccentV
                           alpha:1.0];
}

/// Ставит цвет в КЭШ, без записи файла: палец во время перетаскивания меняет
/// цвет десятки раз в секунду, а HUDOverlaySetNumber пишет plist СИНХРОННО —
/// писать его под пальцем нельзя. Файл пишем один раз: при тапе или при
/// отпускании пальца (см. HUDMenuAccentSave, commitRawDrag).
static void HUDMenuAccentSetHSV(double h, double s, double v)
{
    h = fmod(h, 360.0);
    if (h < 0.0) { h += 360.0; }
    s = MIN(MAX(s, 0.0), 1.0);
    v = MIN(MAX(v, 0.0), 1.0);
    sMenuAccentH = (CGFloat)h;
    sMenuAccentS = (CGFloat)s;
    sMenuAccentV = (CGFloat)v;
}

/// Разовая запись текущего цвета в plist.
static void HUDMenuAccentSave(void)
{
    // ОДНО чтение и ОДНА запись файла вместо трёх: HUDOverlaySetNumber на
    // каждый вызов заново читал весь plist и писал его атомарно с chmod —
    // три таких пар на закрытии пикера давали «маленькую задержку».
    NSMutableDictionary *dict = HUDOverlayDict();
    dict[@"hud.accent.h"] = @(sMenuAccentH);
    dict[@"hud.accent.s"] = @(sMenuAccentS);
    dict[@"hud.accent.v"] = @(sMenuAccentV);
    HUDOverlayWrite(dict);
}

/// Позиция тапа на вертикальной полосе оттенка — 0..1 по высоте
/// (маркер-риска 3 pt, читаем от его середины).
static CGFloat HUDAccentRatioAtY(CGPoint local, UIView *strip)
{
    CGFloat usable = strip.bounds.size.height - 3.0;
    if (usable <= 0.0) { return 0.0; }
    CGFloat value = (local.y - strip.frame.origin.y - 1.5) / usable;
    return MIN(MAX(value, 0.0), 1.0);
}

/// Оттенок из позиции пальца на полосе: 0..359, а НЕ 0..360. Строгое 360
/// сводилось к 0 через fmod — и белая риска ПРЫГАЛА С САМОГО НИЗА НАВЕРХ,
/// как только палец доезжал до конца полосы («перекидывает наверх»).
/// 359° на глаз неотличимо от 360° (обе — красный), но риска остаётся внизу.
static CGFloat HUDAccentHueAtRatio(CGFloat ratio)
{
    return MIN(ratio * 360.0, 359.0);
}

static UILabel *HUDLabel(NSString *text, CGFloat size, UIFontWeight weight)
{
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = HUDText();
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

/// Иконка квадратика. Вес Medium вместо Bold (по заказу): ползунки на иконке
/// были «жирными» — на размере 20 pt они читаются и тоньше. Приложение квадрат
/// больше не рисует (см. LoaderView), держать пару весов больше не с чем.
static UIImage *HUDTriggerImage(BOOL open)
{
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:(open ? @"xmark" : @"slider.horizontal.3") withConfiguration:config];
}

#pragma mark - Плоский тумблер

// Размер тумблера (по заказу — ЗАКРУГЛЁННЫЙ): подложка-пилюля 44×20 (скругление
// = половина высоты), бегунок внутри — КРУГ диаметром 14 pt цвета #d4d6d9.
static const CGFloat kFlatSwitchW = 44.0;
static const CGFloat kFlatSwitchH = 20.0;
// Длительность анимации переключения (по заказу — быстрее прежних 0.35 с).
static const NSTimeInterval kSwitchAnimDuration = 0.24;
// Длительность анимаций самого меню (смена темы, переключение вкладки,
// появление/исчезновение панели) — тот же порядок, что у тумблера.
static const NSTimeInterval kMenuFadeDuration = 0.30;

/// Тумблер вместо системного UISwitch. Закруглённая пилюля с круглым бегунком;
/// включение/выключение ПЛАВНОЕ (~0.24 с): подложка перекрашивается и бегунок
/// едет на место (см. setOn:). Касания класс НЕ обрабатывает (как и раньше):
/// строку переключает жест панели (см. switchRowTapped: и performTapAtPoint:),
/// переключатель — индикатор состояния.
@interface HUDFlatSwitch : UIControl
/// Включён или выключен; при смене перекрашивает подложку и двигает бегунок.
@property (nonatomic, assign) BOOL on;
/// Цвета подложки вкл/выкл — их задаёт палитра темы (см. applyMenuTheme).
@property (nonatomic, strong) UIColor *onColor;
@property (nonatomic, strong) UIColor *offColor;
/// Перекрасить подложку под текущее состояние (после смены onColor/offColor).
- (void)refreshColors;
@end

@implementation HUDFlatSwitch {
    BOOL _on;
    UIView *_knob;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil) { return nil; }
    // Касания не обрабатываем — состояние двигает только жест строки.
    self.userInteractionEnabled = NO;
    // Пилюля (по заказу тумблер закруглённый): скругление = половина высоты.
    self.layer.cornerRadius = kFlatSwitchH / 2.0;
    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    // Бегунок #d4d6d9 (по заказу) — не чистый белый; он КРУГЛЫЙ (по заказу) —
    // радиус positionKnob считает как side / 2.
    _knob.backgroundColor = [UIColor colorWithRed:0.831 green:0.839 blue:0.851 alpha:1.0];
    [self addSubview:_knob];
    return self;
}

- (BOOL)on { return _on; }

/// Куда встать бегунок: слева (выкл) или справа (вкл), с отступом 3 pt от края.
- (void)positionKnob
{
    CGFloat pad = 3.0;
    CGFloat side = self.bounds.size.height - 2.0 * pad;
    CGFloat x = _on ? self.bounds.size.width - side - pad : pad;
    _knob.frame = CGRectMake(round(x), pad, side, side);
    _knob.layer.cornerRadius = side / 2.0;   // круг (по заказу)
}

- (void)setOn:(BOOL)on
{
    _on = on;
    UIColor *target = _on ? _onColor : _offColor;
    void (^apply)(void) = ^{
        self.backgroundColor = target;
        [self positionKnob];
    };
    // Плавное включение/выключение ~0.24 с (по заказу, чуть быстрее прежних
    // 0.35 с): подложка перекрашивается и бегунок ЕДЕТ на место одновременно.
    // Раньше здесь менялся только цвет — кадр бегунка пересчитывался лишь при
    // layout, поэтому он «стоял на месте». До первого layout кадр пуст —
    // анимировать нечего, ставим состояние сразу.
    if (CGRectIsEmpty(self.bounds)) {
        apply();
        return;
    }
    [UIView animateWithDuration:kSwitchAnimDuration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:apply
                     completion:nil];
}

- (void)refreshColors
{
    self.backgroundColor = _on ? _onColor : _offColor;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self positionKnob];
}

@end

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
// По заказу панель чуть растянута (было 340×190): в портрете на iPhone 7
// (ширина 375 pt) по бокам остаётся по 9.5 pt — перенос за чёрные области цел.
static const CGFloat kPanelWidthMax  = 356.0;   // ширина меню
static const CGFloat kPanelHeightMax = 200.0;   // высота меню (влезает и в ландшафт)
// Пропорция меню: ширина / высота. 1.25 давало почти квадрат — просили
// прямоугольник и размер поменьше. 1.55 (≈3:2) — явно вытянуто вширь и заметно
// ниже прежнего, при этом и в портрете, и в ландшафте панель остаётся
// читаемой: по высоте всё равно ограничивает kPanelHeightMax и площадь.
static const CGFloat kPanelRatio     = 1.55;

// Тайминги жеста. AX/HID-поток на iOS 15 часто теряет событие «подъём», и без
// жёсткого контроля старое начало жеста оставалось бы висеть навсегда: следующее
// движение считалось протяжкой ОТ старой точки, и квадрат/панель прыгали назад —
// ровно на то место, где они появились. Жест жив, только пока по нему идут
// события и только ограниченное время.
static const NSTimeInterval kRawGestureStale    = 0.40;  // пауза, после которой жест протух
static const NSTimeInterval kRawGestureLifetime = 2.50;  // предельная длина одного жеста
static const NSTimeInterval kRawTapDebounce     = 0.12;  // гасит повторный «подъём» одного тапа
// Предел одного шага пальца между событиями ДО включения переноса, в точках.
// Поток HID иногда присылает событие движения с координатами ЧУЖОГО касания
// (остаток прошлого жеста) — это скачок на сотни точек за один кадр. Настоящий
// палец столько не проходит (120 pt за 16 мс — это 7500 pt/с), поэтому такой
// шаг считается мусором: элемент не двигается, жест просто перебазируется.
static const CGFloat kRawJumpLimit = 120.0;
// Тот же предел, но для УЖЕ НАЧАТОГО переноса — и работает он иначе. Когда
// элемент уже идёт за пальцем 1:1, обрыв на скачке хуже самой ошибки: раньше
// резкий шаг останавливал перенос и перебазировал отсчёт — элемент замирал, а
// потом НАВСЕГДА отставал от пальца на величину скачка (ровно то, что видно как
// «лагает при передвижении»). Теперь отсчёт не трогаем: шаг лишь ограничиваем
// (см. LimitStep), и следующее нормальное событие возвращает элемент на
// истинный путь пальца. Запас на настоящий рывок щедрый: 240 pt за событие —
// это 7200 pt/с даже при склеивании событий до 30 Гц (поток AX их склеивает,
// когда главный поток занят рисованием).
static const CGFloat kRawDragStepMax       = 240.0;
// ПЕРЕНОС квадрата и панели. Раньше он ждал 0.25 с и перебазировался на точку
// старта — из-за этого элемент таскался «с задержкой» и отставал от пальца.
// Теперь удержание короткое, а перенос ведётся строго за пальцем один к одному.
// Перенос включается, если палец задержался на kRawDragHold ИЛИ сразу ушёл на
// kRawDragArmMove: нажатие короткое и почти без движения, поэтому переносом не
// становится. Держим это коротким: пока держание не вышло, палец может уже
// вести элемент, а движения не видно — это и выглядит как «лаг в начале
// протяжки». Настоящие тапы это не ломает: при отпускании путь всё равно
// сверяется с kRawTapSlop, и короткое нажатие остаётся нажатием.
static const NSTimeInterval kRawDragHold   = 0.06;
static const CGFloat kRawDragArmMove       = 14.0;
// Жест, начатый на чёрной карточке вкладки (прокрутка и строки внутри неё),
// решается по первому заметному движению — без каких-либо таймеров удержания:
// вертикальное движение в сторону, где содержимое ещё может ехать, = листание
// до конца жеста; если ехать некуда (лист у края) или движение горизонтальное,
// = перенос панели, идущий СРАЗУ и строго за пальцем. Таймеры ломали оба
// случая: медленное листание превращалось в перенос, а сам перенос молчал
// долю секунды, а потом «телепортировал» панель к пальцу.
static const CGFloat kRawScrollDecide   = 8.0;
// Борт панели: касание в пределах этого расстояния от края панели — это ВСЕГДА
// «взять меню», даже если попало на чёрную карточку вкладки. Строки и скролл
// начинаются глубже, поэтому у края панель берётся сразу, за любую сторону.
static const CGFloat kPanelGrabRim      = 14.0;
// Если за весь жест палец прошёл меньше этого, жест считается НАЖАТИЕМ:
// элемент возвращается ровно на место, где был в момент нажатия.
static const CGFloat kRawTapSlop           = 14.0;
// Возврат «это было нажатие» действует только для коротких жестов: если палец
// водил дольше срока, крошечный путь — это уже НАМЕРЕННОЕ «чуть перетащить»,
// и элемент остаётся там, где его оставили (иначе панель после маленького
// переноса телепортировалась назад к точке захвата).
static const NSTimeInterval kRawTapMaxTime   = 0.25;

// Раскладка панели (по образцу меню-эталона MY IMGUI): заголовок слева сверху,
// под ним колонка вкладок, справа — тёмная карточка контента во всю высоту.
// Размеры колонки и строк считаются от пропорций эталона прямо в layoutPanel;
// здесь — только общие отступы, одни и те же для сборки и раскладки.
static const CGFloat kCardInset      = 8.0;     // отступ карточки от края панели
static const CGFloat kSectionTop     = 32.0;    // высота полосы заголовка раздела
static const CGFloat kTriggerInset   = 14.0;
// Край экрана для перетаскивания: квадрат и панель ездят по ВЕСЬМУ экрану и
// зажимаются только так, чтобы не выйти за границу. 6 pt — чтобы скруглённые
// углы не срезались об рамку и элементы визуально не «слипались» с краем.
static const CGFloat kEdgeMargin     = 6.0;

// Высота вкладок: строка переключателя, строка слайдера и содержимое вкладки
// «combot». Держим константами, потому что одни и те же числа нужны и сборке
// строк, и раскладке, и размеру прокручиваемой области. По заказу строка
// переключателя ПОТЯНЕЕ прежней 40 (32): и тумблер стоит выше, и над
// accent color больше нет большого пустого резерва.
static const CGFloat kSwitchRowHeight  = 32.0;
static const CGFloat kSwitchRowGap     = 4.0;
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
    // Ползунок (вкладка Aim): драг по горизонтали, но ВЕРТИКАЛЬНЫЙ свайп над
    // ним обязан листать вкладку — ползунки занимают почти всю ширину карточки,
    // и без такого решения жест «поднять палец снизу вверх» съедался слайдером
    // и долистанная до низа вкладка не листалась бы обратно (решение — по
    // kRawScrollDecide, см. handleRawTouchPhase:).
    HUDRawDragSlider,
    // Пикер accent color (всплывающая карточка поверх меню): прямое управление
    // значением пальцем — кружок в поле тянется, риска по радужной полосе
    // мотается вверх-вниз. Удержания не требуют, порог не нужен.
    HUDRawDragPickerSV,
    HUDRawDragPickerHue,
    // Перенос самой карточки пикера — за чёрные поля вокруг поля и полосы,
    // как меню за чёрные области. Тоже сразу, без удержания.
    HUDRawDragPickerCard,
    // Остальное при открытом пикере: карточка перекрывает меню, поэтому
    // «пустой» жест — тап по нему закрывает пикер, а меню под ним не трогается.
    HUDRawDragPickerOutside,
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
    UILabel *_buildLabel;       // мелкая метка времени сборки в колонке вкладок —
                                // чтобы сразу видеть, какая сборка стоит на
                                // телефоне (проверка жалоб «ничего не изменилось»)
    NSMutableArray<UIButton *> *_tabButtons;
    UIView *_tabIndicator;        // красная полоска у выбранной вкладки
    UIView *_contentCard;         // тёмная карточка справа
    UILabel *_sectionTitle;       // заголовок раздела внутри карточки
    UIScrollView *_scroll;
    UIButton *_unloadButton;
    // Вкладка Misc: строка accent color — надпись слева, свотч текущего цвета
    // СПРАВА от неё. Тап по свотчу (и по всей строке — чтобы легко попадать)
    // открывает HSV-пикер. См. togglePicker.
    UIView *_accentRow;
    UIView *_accentSwatch;      // свотч текущего цвета — он же кнопка пикера
    UILabel *_accentLabel;
    // Строка menu theme (вкладка Misc): выбор ТЕМЫ меню — не переключатель,
    // а две пилюли dark | light справа от надписи (см. updateThemeSegmentUI).
    UIView *_themeRow;
    UILabel *_themeLabel;
    UILabel *_themeDarkLabel;
    UILabel *_themeLightLabel;
    // Строка target (вкладка Aim): цель аимбота — четыре пилюли head / neck /
    // body / legs; выбранную красит updateTargetUI, значение лежит в plist
    // (cheat.target).
    UIView *_targetRow;
    UILabel *_targetLabel;
    NSMutableArray<UILabel *> *_targetPills;
    // Пикер — ВСПЛЫВАЮЩАЯ карточка поверх меню (не внутри панели и не в
    // отдельном окне): тёмная карточка с полем «насыщенность × яркость» и
    // вертикальной радужной полосой оттенка. Рисуется в том же HUD-слое
    // (_stage), что и меню, — отдельное UIWindow здесь НЕ годится: HUD живёт
    // в системном окне поверх всех приложений, а обычное окно приложения
    // остаётся ПОД игрой, и пикер был бы невидим (именно поэтому кнопка
    // «не нажималась» — пикер открывался, но его не было видно). Касания
    // идут в HUD по потоку HID и разбираются геометрически (см.
    // rawDragTargetAtPoint и handleRawTouchPhase:).
    UIView *_pickerCard;
    UIView *_svSquare;          // поле: слева белое → справа чистый цвет
    CAGradientLayer *_svBase;   // горизонталь: белый → цвет текущего оттенка
    CAGradientLayer *_svShade;  // вертикаль: прозрачный сверху → чёрный снизу
    UIView *_hueStrip;          // вертикальная радужная полоса оттенка
    CAGradientLayer *_hueGradient;
    UIView *_svMarker;          // круг-маркер выбранной точки поля
    UIView *_hueMarker;         // белая риска на полосе оттенка
    // Кэш hud.picker.x/y — смещение карточки от центра сцены: с диска читаем
    // один раз (ensurePickerCard), пишем при перетаскивании (commitRawDrag).
    // Раньше это читал layoutPicker на КАЖДОМ открытии — открытие подтормаживало.
    CGSize _pickerOffset;
    // Запись экрана/AirPlay: панель и квадрат скрыты, пока UIScreen.isCaptured
    // (вкладка Misc, переключатель overlay).
    BOOL _captureHidden;
    NSMutableArray<HUDFlatSwitch *> *_switches;
    NSMutableArray<UISlider *> *_sliders;
    NSMutableDictionary<NSString *, UILabel *> *_sliderValueLabels;
    // Тёмная колонка вкладок слева (лежит ВНУТРИ _panelHeader — см. buildPanel).
    UIView *_sidebarBg;
    // Вкладка Config: поле имени, кнопка создания и список конфигов.
    // _configRowsDirty — «список надо пересобрать»: файл читаем только когда
    // что-то создали/удалили, а не на каждой раскладке.
    UITextField *_configNameField;
    UIButton *_configCreateButton;
    NSMutableArray<UIView *> *_configRows;
    NSMutableArray<NSString *> *_configNames;
    BOOL _configRowsDirty;
    // Область системной клавиатуры в координатах оверлея: касания внутри неё
    // отбрасываем, иначе буквы «нажимали» бы панель под клавиатурой.
    CGRect _keyboardFrame;
    CGSize _panelOffset;
    BOOL _panelOpen;
    NSInteger _tab;
    NSInteger _contentTab;       // какая вкладка раскладывалась в последний раз:
                                 // при СМЕНЕ вкладки прокрутку начинаем сверху

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
    CGRect _rawStageBounds;     // границы сцены на момент начала жеста: если сцена
                                // пересобралась посреди жеста (быстрый Start сразу
                                // разворачивает игру), координаты событий приходят
                                // уже в новом кадре — якорь тогда перебазируем
    UISlider *_rawSlider;       // ползунок, который тянет палец (HUDRawDragSlider)
    BOOL _rawMoved;             // палец реально сдвинулся (а не просто тап)
    BOOL _rawArmed;             // удержание прошло — жест стал переносом
    BOOL _rawHoldable;          // удержание здесь вообще разрешено (см. ниже)
    BOOL _rawHoldFromScroll;    // захват с карточки — долгим удержанием
    BOOL _rawScrollTouched;     // карточку начали листать — это не тап
    BOOL _rawCanScrollUp;       // содержимое карточки может ехать вверх (dy > 0)
    BOOL _rawCanScrollDown;     // ...и вниз (dy < 0) — на момент нажатия
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

    // По заказу при КАЖДОМ новом запуске сбрасываются ВСЕ настройки меню:
    // позиции квадрата и панели, акцент, тема и все переключатели. Список
    // конфигов НЕ трогаем — он лежит в отдельном файле. Всё делается ОДНИМ
    // словарём и ОДНОЙ записью файла: раньше шло восемь отдельных
    // HUDOverlaySetFlag, и каждый заново читал plist и атомарно его
    // перезаписывал. Значения по умолчанию: переключатели выключены (см.
    // HUDSwitchDefault), акцент — красный (см. HUDMenuAccentLoad), тема — dark.
    NSMutableDictionary *fresh = HUDOverlayDict();
    [fresh removeObjectsForKeys:@[ @"cheat.esp", @"cheat.aimbot", @"misc.overlay",
                                   @"hud.accent", @"hud.accent.h", @"hud.accent.s",
                                   @"hud.accent.v", @"hud.theme" ]];
    fresh[@"trigger.x"] = @0;
    fresh[@"trigger.y"] = @0;
    fresh[@"hud.panel.x"] = @0;
    fresh[@"hud.panel.y"] = @0;
    // Под-опций ESP в меню больше нет (остался только Enable), а старые значения
    // в файле прочитал бы холст ESP — приводим их к нужным.
    fresh[@"esp.box"] = @1;
    fresh[@"esp.health"] = @1;
    fresh[@"esp.name"] = @1;
    fresh[@"esp.distance"] = @1;
    fresh[@"esp.snapline"] = @0;
    HUDOverlayWrite(fresh);

    _triggerOffset = CGSizeMake(HUDOverlayNumber(@"trigger.x", 0),
                                HUDOverlayNumber(@"trigger.y", 0));
    _panelOffset = CGSizeMake(HUDOverlayNumber(@"hud.panel.x", 0),
                              HUDOverlayNumber(@"hud.panel.y", 0));
    _tab = 0;

    _configRows = [NSMutableArray array];
    _configNames = [NSMutableArray array];
    _configRowsDirty = YES;
    _keyboardFrame = CGRectZero;

    // Акцентный цвет меню (HSV): читаем из plist ДО сборки панели —
    // buildPanel/buildContent красят заголовок и полоску этим цветом.
    // Дальше работает только кэш (чтение файла на каждый кадр недопустимо).
    HUDMenuAccentLoad();
    // Тема меню (dark/light) — тоже ДО сборки панели: buildContent красит
    // фоны и подписи палитрой, зависящей от темы (см. HUDFill/HUDText).
    sMenuLight = (HUDOverlayNumber(@"hud.theme", 0.0) > 0.5);

    [self buildTrigger];
    [self startOrientationObserver];

    // Панель (сборка контента, конфиги, тема — самая тяжёлая часть поднятия
    // оверлея) собираем на СЛЕДУЮЩЕМ такте главной очереди: квадрат к этому
    // моменту уже добавлен в иерархию и появляется на экране раньше — меню
    // после Start выезжает как можно быстрее. Тап по квадрату, пока панели
    // ещё нет, просто игнорируется (см. togglePanel).
    dispatch_async(dispatch_get_main_queue(), ^{
        [self buildPanel];
        [self setNeedsLayout];
    });

    // Сообщаем приложению, что квадрат рисует HUD и дублировать его в app не
    // нужно. Приложение покажет свой запасной квадрат, только если этой метки
    // нет (то есть HUD-оверлей не поднялся).
    HUDOverlaySetFlag(@"hud.overlay", YES);

    // Запись экрана/AirPlay прячет панель и квадрат при включённом overlay
    // (вкладка Misc). Уведомление дёшевое и приходит только при смене захвата.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenCaptureChanged:)
                                                 name:UIScreenCapturedDidChangeNotification
                                               object:nil];
    [self applyCaptureVisibility];

    // Если HUD поднялся во время записи экрана, applyCaptureVisibility уже
    // спрятал квадрат — не возвращаем его насильно.
    if (!_captureHidden) {
        _trigger.hidden = NO;
        _trigger.layer.opacity = 1.0f;
    }

    AscentHUDLog(@"HUD: UIKit-оверлей создан (сборка 5), bounds=%@", NSStringFromCGRect(frame));
    return self;
}

#pragma mark - Касания из потока HID (перетаскивание и прокрутка)

/// Управляемый элемент: кнопка, вкладка, строка переключателя, группа слайдера
/// или строка конфига. Отдельная категория нужна, чтобы НАЖАТИЕ на кнопку не
/// превращалось в прокрутку: управляющим элементам даём большой порог
/// «протяжки», и дрожь руки при нажатии остаётся тапом.
- (BOOL)isInteractiveView:(UIView *)view
{
    if (view == nil) { return NO; }
    UIView *cursor = view;
    while (cursor != nil && cursor != _stage && cursor != _panel) {
        if ([cursor isKindOfClass:[UIControl class]]) { return YES; }
        if (cursor == _accentRow) { return YES; }
        if (cursor == _targetRow) { return YES; }
        if ([_configRows indexOfObjectIdenticalTo:cursor] != NSNotFound) { return YES; }
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
    // Пикер открыт (всплывающая карточка поверх меню) — проверяем ДО hitTest
    // по меню: кружок в поле и риска на полосе тянутся пальцем сразу, без
    // удержания; за чёрные поля вокруг них таскается сама карточка (как меню
    // за чёрные области); всё остальное — «пустое» (тап закроет пикер, а меню
    // под ним палец не тронет).
    if (_pickerCard != nil && !_pickerCard.hidden) {
        CGPoint local = [_pickerCard convertPoint:point fromView:self];
        if (CGRectContainsPoint(_svSquare.frame, local)) { return HUDRawDragPickerSV; }
        if (CGRectContainsPoint(_hueStrip.frame, local)) { return HUDRawDragPickerHue; }
        if (CGRectContainsPoint(_pickerCard.bounds, local)) { return HUDRawDragPickerCard; }
        return HUDRawDragPickerOutside;
    }

    UIView *hit = [self hitTest:point withEvent:nil];
    if (hit == nil) { return HUDRawDragNone; }

    // Квадрат: нажатие открывает меню, а перенос идёт только по УДЕРЖАНИЮ
    // (см. kRawDragHold). Дрожь руки при нажатии его не сдвинет.
    if (hit == _trigger || [hit isDescendantOfView:_trigger]) { return HUDRawDragTrigger; }
    // Ползунок тянется пальцем СРАЗУ, без удержания (как маркеры пикера) —
    // проверяем ДО общего «управляющего элемента»: иначе протяжка по строке
    // слайдера после kRawDragHold превращалась бы в перенос панели.
    {
        UIView *cursor = hit;
        while (cursor != nil && cursor != _stage && cursor != _panel) {
            if ([self sliderInGroup:cursor] != nil) { return HUDRawDragSlider; }
            cursor = cursor.superview;
        }
    }
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
    // БОРТ панели: касание у её края (обод ~kPanelGrabRim по всему периметру,
    // то есть и нижний правый угол) — сразу перенос, без долгого удержания.
    // Внутри карточки удержание, как раньше: листание вкладки захватом не
    // становится ни на каком участке. Срабатывает ДО расчёта порога, чтобы у
    // края действовал порог панели, а не прокрутки.
    if (_rawTarget == HUDRawDragScroll || _rawTarget == HUDRawDragControl) {
        CGPoint local = [_panel convertPoint:point fromView:self];
        // Обод переноса панели НЕ шире самой карточки (kCardInset = 8): обод
        // в 14 pt «съедал» нижнюю полосу карточки — свайп, начатый у НИЗА
        // вкладки, шёл в перенос панели, а не в листание (жалоба: долистанный
        // до низа Aim не листался обратно). Край панели (в т.ч. нижний правый
        // угол) по-прежнему тащит панель — просто на 6 pt уже.
        CGFloat rim = MIN(kPanelGrabRim, kCardInset);
        CGRect grabZone = CGRectInset(_panel.bounds, rim, rim);
        if (CGRectContainsPoint(_panel.bounds, local) && !CGRectContainsPoint(grabZone, local)) {
            _rawTarget = HUDRawDragPanel;
        }
    }
    _rawThreshold = [self rawThresholdForTarget:_rawTarget];
    _rawStart = stagePoint;
    _rawLastPoint = stagePoint;
    _rawPressPoint = stagePoint;
    _rawStageBounds = [self stageBounds];
    // Центр элемента переноса на момент нажатия: квадрат, карточка пикера
    // или панель — от него и считается весь путь пальца (1:1).
    if (_rawTarget == HUDRawDragTrigger) {
        _rawStartCenter = _trigger.center;
    } else if (_rawTarget == HUDRawDragPickerCard) {
        _rawStartCenter = _pickerCard.center;
    } else {
        _rawStartCenter = _panel.center;
    }
    _rawPressCenter = _rawStartCenter;
    _rawStartOffset = _scroll.contentOffset;
    _rawMoved = NO;
    // Пикер (кружок, полоса, перенос карточки) тянется с САМОГО начала —
    // удержание ему не нужно, поэтому помечаем жест «начатым» сразу. Из-за
    // этого он: (1) не «протухает» по кайфу длинного перетаскивания (см.
    // kRawGestureLifetime) и не перебазируется на полпути; (2) при скачке
    // попадает в ветку «перенос уже идёт» (пропуск мусора БЕЗ перебазации),
    // а не в ветку мусора, которая берёт _rawStartCenter ОТ ПАНЕЛИ — для
    // пикера это и было причиной «телепорта к меню и возврата к пальцу».
    _rawArmed = (_rawTarget == HUDRawDragPickerSV ||
                 _rawTarget == HUDRawDragPickerHue ||
                 _rawTarget == HUDRawDragPickerCard);
    // Где жест вообще может стать переносом. Квадрат, панель, кнопки вкладок —
    // как раньше, почти сразу. С ЧЁРНОЙ карточки (прокрутка и строки внутри)
    // режим «листать или таскать» решается первым заметным движением по
    // направлению и возможности прокрутки (см. handleRawTouchPhase) — таймеров
    // тут нет ни никаких: из-за них листание и перенос путались.
    UIView *hit = [self hitTest:point withEvent:nil];
    BOOL insideScroll = (hit != nil && [hit isDescendantOfView:_scroll]);
    _rawHoldable = (_rawTarget == HUDRawDragTrigger ||
                    _rawTarget == HUDRawDragPanel ||
                    _rawTarget == HUDRawDragControl ||
                    _rawTarget == HUDRawDragScroll);
    _rawHoldFromScroll = insideScroll &&
                         (_rawTarget == HUDRawDragScroll ||
                          _rawTarget == HUDRawDragControl);
    // Ползунок (вкладка Aim) пока только ЗАПОМИНАЕМ: решение «драг ползунка
    // или листание вкладки» принимается по первому заметному движению в
    // handleRawTouchPhase: — сразу давить значение нельзя, иначе вертикальный
    // свайп над ползунком съедался слайдером и вкладка не листалась обратно.
    // Тап при этом работает и без этого решения — значение ставит
    // applyTapToSlider на отпускании.
    _rawSlider = nil;
    if (_rawTarget == HUDRawDragSlider) {
        UIView *cursor = hit;
        while (cursor != nil && cursor != _stage && cursor != _panel) {
            UISlider *slider = [self sliderInGroup:cursor];
            if (slider != nil) { _rawSlider = slider; break; }
            cursor = cursor.superview;
        }
    }
    _rawScrollTouched = NO;
    _rawTapFired = NO;
    _dragging = YES;
    _rawStartTime = [[NSProcessInfo processInfo] systemUptime];
    _rawLastTime = _rawStartTime;
    // Может ли содержимое карточки ещё ехать вверх/вниз с этой точки нажатия:
    // от этого зависит решение «листать или таскать» (см. handleRawTouchPhase).
    CGFloat minY = -_scroll.contentInset.top;
    CGFloat maxY = MAX(_scroll.contentSize.height - _scroll.bounds.size.height +
                       _scroll.contentInset.bottom, minY);
    _rawCanScrollUp = (_scroll.contentOffset.y - minY) > 0.5;
    _rawCanScrollDown = (maxY - _scroll.contentOffset.y) > 0.5;
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

    // Сцена могла пересобраться ВО ВРЕМЯ жеста: быстрый Start разворачивает игру
    // — координаты события приходят уже в новом кадре сцены, а якорь
    // (_rawStart/_rawStartCenter) считался в старом. Без этого дельты «улетали»
    // в сторону, панель вела себя как застрявшая, а на отпускании телепортировалась
    // в точку пальца. Перебазируемся от текущей точки и текущего центра: элемент
    // остаётся где стоял, дальше идёт строго за пальцем.
    if (_rawTarget != HUDRawDragNone &&
        !CGRectEqualToRect(_rawStageBounds, [self stageBounds])) {
        _rawStageBounds = [self stageBounds];
        _rawStart = stagePoint;
        _rawLastPoint = stagePoint;
        _rawPressPoint = stagePoint;
        _rawStartOffset = _scroll.contentOffset;
        if (_rawTarget == HUDRawDragTrigger) {
            _rawStartCenter = _trigger.center;
        } else if (_rawTarget == HUDRawDragPickerCard) {
            _rawStartCenter = _pickerCard.center;
        } else {
            _rawStartCenter = _panel.center;
        }
        _rawPressCenter = _rawStartCenter;
        AscentHUDLog(@"[gesture] сцена пересобралась во время жеста — якорь перебазирован");
    }

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
            // Ветка мусора — только для НЕначатого жеста (_rawArmed == NO).
            // Все «обычные» цели здесь держимые, поэтому раньше условие
            // читалось как !_rawArmed; с пикером (он не держимый, но начатый
            // сразу — см. beginRawDragAtPoint) ветка «!_rawHoldable» стала бы
            // ловить и его — а там _rawStartCenter перебазируется ОТ ПАНЕЛИ,
            // и карточка «телепортировалась» к меню. Поэтому оставляем только
            // !_rawArmed: для держимых целей поведение ровно прежнее.
            if (!_rawArmed) {
                // Перенос ещё не идёт: координаты выглядят как мусорные (остаток
                // прошлого касания), поэтому ЭТО событие элемент не двигает. Но
                // якорь (_rawStart/_rawStartCenter) НЕ перебазируем — именно этим
                // накапливался главный баг «панель стоит, на отпускании телепорт»:
                // пока главный поток занят стартом игры, события склеиваются, шаг
                // между ними легко больше kRawJumpLimit, и каждое такое событие
                // сбрасывало отсчёт от настоящей точки нажатия. Панель тогда стояла
                // на месте весь перенос, а на первом «нормальном» событии (часто
                // уже на отпускании) догоняла пальца — ровно тот телепорт, что и
                // жаловались поймать. Теперь якорь остаётся настоящей точкой
                // нажатия, а сам жест по прежним правилам включается прямо здесь —
                // дальше он ведёт элемент сразу, не дожидаясь конца движения.
                // Мусорное событие чужого касания при этом по-прежнему ничего не
                // двигает: применять его некуда, а вот уже начатый перенос пропускает
                // его ниже, не сбивая отсчёт.
                AscentHUDLog(@"[gesture] скачок %.0f pt — мусорное событие, элемент не двигаю", stepLen);
                CGPoint jumpDelta = CGPointMake(stagePoint.x - _rawStart.x,
                                                stagePoint.y - _rawStart.y);
                CGFloat jumpLen = sqrt(jumpDelta.x * jumpDelta.x + jumpDelta.y * jumpDelta.y);
                if (_rawHoldFromScroll) {
                    // С карточки режим «листать или таскать» решаем теми же
                    // правилами, что и на обычном движении (см. ниже): вертикально
                    // и содержимое ехает — листание; иначе — перенос панели. Только
                    // саму прокрутку к мусорным координатам не применяем.
                    if (jumpLen >= kRawScrollDecide) {
                        BOOL vertical = fabs(jumpDelta.y) > fabs(jumpDelta.x);
                        BOOL scrollable = (_rawCanScrollUp || _rawCanScrollDown);
                        if (vertical && scrollable) {
                            _rawScrollTouched = YES;
                        } else {
                            _rawTarget = HUDRawDragPanel;
                        }
                        _rawArmed = YES;
                    }
                } else if (_rawTarget == HUDRawDragSlider && jumpLen >= kRawScrollDecide) {
                    // Быстрый свайп с ползунка приехал одним «скачком» (поток
                    // касаний на живой игре регулярно склеивается). Те же правила
                    // решения, что и на обычном движении: вертикально и вкладке
                    // есть куда ехать → листание; иначе → драг ползунка. Без
                    // этой ветки такой свайп заармливался бы сразу драгом и
                    // съедал листание — ровно та жалоба «не листается обратно».
                    BOOL vertical = fabs(jumpDelta.y) > fabs(jumpDelta.x);
                    BOOL scrollable = (_rawCanScrollUp || _rawCanScrollDown);
                    if (vertical && scrollable) {
                        _rawTarget = HUDRawDragScroll;
                        _rawHoldable = YES;
                        _rawHoldFromScroll = NO;
                        _rawScrollTouched = YES;
                        _rawSlider = nil;
                        // Жест считается начатым: на отпускании не долетит
                        // «тап» и не перезапишет значение ползунка.
                        _rawMoved = YES;
                        AscentHUDLog(@"[gesture] ползунок -> листание вкладки (скачок)");
                    }
                    _rawArmed = YES;
                } else if ((now - _rawStartTime) >= kRawDragHold ||
                           jumpLen >= kRawDragArmMove) {
                    // Держание уже вышло (или палец ушёл далеко) — считаем жест
                    // начатым. _rawMoved НЕ трогаем: движение к этому моменту не
                    // применялось, поэтому короткое нажатие на месте останется
                    // нажатием (см. ветку tinyQuick в конце жеста).
                    if (_rawTarget == HUDRawDragControl) {
                        _rawTarget = HUDRawDragPanel;
                    }
                    _rawArmed = YES;
                }
                return;
            }
            // Перенос уже идёт 1:1, а шаг больше предела настоящего пальца —
            // это мусорное событие с координатами ЧУЖОГО касания, а не рывок.
            // Раньше LimitStep преследовал такую точку: элемент прыгал до
            // kRawDragStepMax к чужой точке и возвращался обратно на
            // следующем событии («телепорт куда-то и сразу обратно» —
            // жалоба на квадрат при перетаскивании). Пропускаем событие
            // ЦЕЛИКОМ: элемент не двигается и отсчёт не трогаем. _rawLastPoint
            // уже обновлён выше, поэтому фризов нет; движение абсолютное (от
            // _rawStart), так что после мусорного события следующее НОРМАЛЬНОЕ
            // событие ставит элемент ровно на истинный путь пальца.
            AscentHUDLog(@"[gesture] рывок %.0f pt в переносе — мусорное событие, пропускаю", stepLen);
            return;
        }

        CGPoint delta = CGPointMake(stagePoint.x - _rawStart.x, stagePoint.y - _rawStart.y);

        // ПИКЕР: кружок в поле и риска на полосе ведутся пальцем СРАЗУ, без
        // удержания и порогов — прямое управление значением, как в системном
        // выборе цвета. Значение ставится от ТЕКУЩЕЙ точки пальца, поэтому и
        // отсев скачков выше работает как надо: мусорное событие просто
        // пропускается, следующее нормальное ставит цвет на истинный путь.
        if (_rawTarget == HUDRawDragPickerSV || _rawTarget == HUDRawDragPickerHue) {
            _rawMoved = YES;
            [self applyPickerDragAtPoint:point];
            return;
        }

        // ПЕРЕНОС карточки пикера — за чёрные поля вокруг поля и полосы, как
        // меню за чёрные области: сразу, без удержания, строго за пальцем
        // (1:1, от центра на момент нажатия). Скачок-мусор отсекается выше.
        if (_rawTarget == HUDRawDragPickerCard) {
            CGPoint center = CGPointMake(_rawStartCenter.x + delta.x,
                                         _rawStartCenter.y + delta.y);
            center = LimitStep(_pickerCard.center, center, kRawDragStepMax);
            _pickerCard.center = [self clampPickerCenter:center];
            _rawMoved = YES;
            return;
        }

        // ПОЛЗУНОК (вкладка Aim): драг по горизонтали, но вертикальный свайп
        // превращается в лИСТАНИЕ вкладки — иначе ползунки (они почти во всю
        // ширину карточки) съедали бы вертикальные свайпы, и долистанная до
        // низа вкладка не листалась бы обратно. Решение — по первому заметному
        // движению, как у строк с карточки (kRawScrollDecide).
        if (_rawTarget == HUDRawDragSlider) {
            if (!_rawArmed) {
                CGFloat len = sqrt(delta.x * delta.x + delta.y * delta.y);
                if (len < kRawScrollDecide) {
                    // Покачали пальцем — ещё не решаем и значение не двигаем:
                    // короткое нажатие остаётся тапом по дорожке слайдера.
                    return;
                }
                BOOL vertical = fabs(delta.y) > fabs(delta.x);
                BOOL scrollable = (_rawCanScrollUp || _rawCanScrollDown);
                if (vertical && scrollable) {
                    // Вертикально — это листание: цель меняется на прокрутку,
                    // дальше жест живёт её правилами. Якорь прокрутки — точка
                    // нажатия, поэтому содержимое едет ровно за пальцем, без
                    // «догоняний».
                    _rawTarget = HUDRawDragScroll;
                    _rawHoldable = YES;
                    _rawHoldFromScroll = NO;   // уже решено — без повторного decide
                    _rawScrollTouched = YES;
                    _rawSlider = nil;
                    AscentHUDLog(@"[gesture] ползунок -> листание вкладки");
                }
                _rawArmed = YES;
            }
            if (_rawTarget == HUDRawDragSlider) {
                // Горизонтально (или вкладке некуда ехать) — драгаем ползунок:
                // точку события переводим в координаты слайдера (см.
                // dragSlider:toStagePoint:). Файл пишем на отпускании.
                _rawMoved = YES;
                if (_rawSlider != nil) { [self dragSlider:_rawSlider toStagePoint:stagePoint]; }
                return;
            }
            // Превратилось в листание: _rawArmed уже выставлен, ниже жест
            // обработан общими правилами прокрутки.
        }

        // ПЕРЕНОС квадрата и панели — строго ЗА ПАЛЬЦЕМ, один к одному:
        // положение = положение на момент нажатия + весь путь пальца. Никаких
        // порогов, перебазирований и «догоняний» — именно из-за них перенос
        // отставал от пальца. Начало отсчёта не сдвигается ни на точку, поэтому
        // смещение элемента всегда равно смещению пальца.
        if (_rawHoldable) {
            if (!_rawArmed) {
                CGFloat len = sqrt(delta.x * delta.x + delta.y * delta.y);
                if (_rawHoldFromScroll) {
                    // Жест на чёрной карточке: режим «листать или таскать»
                    // решаем ОДИН раз по первому заметному движению
                    // (kRawScrollDecide) и держим до конца жеста. Вертикально
                    // и содержимое может ехать в ту сторону — листание; если
                    // ехать некуда (лист у края) или движение горизонтальное —
                    // сразу перенос панели, строго за пальцем. Никаких таймеров
                    // удержания: медленное листание не превращается в перенос,
                    // а перенос идёт с первой точки движения — без молчания и
                    // «телепортов» к пальцу.
                    if (len < kRawScrollDecide) {
                        // Покачали пальцем — ещё не решаем и ничего не двигаем:
                        // тап с дрожью не сдвинет ни строку, ни панель.
                        return;
                    }
                    BOOL vertical = fabs(delta.y) > fabs(delta.x);
                    BOOL scrollable = (_rawCanScrollUp || _rawCanScrollDown);
                    if (vertical && scrollable) {
                        // Вкладка листается — вертикальный свайп ВСЕГДА
                        // листание, даже если в эту сторону ехать некуда: у
                        // края список просто стоит, а меню НЕ уезжает (жалоба:
                        // у низа Aim свайп таскал панель). Перенос панели с
                        // карточки при этом жив: на вкладках без прокрутки
                        // (Misc и т.п.) и на любом ГОРИЗОНТАЛЬНОМ свайпе.
                        // Листание — и до конца жеста переносом уже не станет.
                        _rawScrollTouched = YES;
                        AscentHUDLog(@"[gesture] поток: листаю содержимое вкладки");
                    } else {
                        _rawTarget = HUDRawDragPanel;
                        AscentHUDLog(@"[gesture] перенос панели с карточки");
                    }
                } else {
                    // Включаем перенос либо по очень короткому удержанию, либо
                    // сразу, если палец успел уйти далеко. Нажатие короткое и почти
                    // без движения, поэтому переносом не становится.
                    if ((now - _rawStartTime) < kRawDragHold && len < kRawDragArmMove) { return; }
                    // Удержание на кнопке вкладки тоже переносит панель — так
                    // меню можно утащить не только за шапку.
                    if (_rawTarget == HUDRawDragControl) {
                        _rawTarget = HUDRawDragPanel;
                    }
                }
                _rawArmed = YES;
            }
            _rawMoved = YES;
            [self applyRawDragDelta:delta];
            return;
        }

        // Все цели жеста «удерживаемые» (см. beginRawDragAtPoint) — сюда не
        // доходим. На всякий случай возвращаемся, НЕ завершая жест.
        return;
    }

    // Ended / Cancelled: фиксируем результат (позицию или смещение прокрутки).
    if (_rawMoved && _rawHoldable && !_rawScrollTouched) {
        // Смотрим ВЕСЬ путь пальца от точки нажатия. Если он крошечный И жест
        // был коротким — это всё-таки нажатие, а не перенос: возвращаем элемент
        // ровно туда, где он был в момент нажатия, и обрабатываем как тап. Без
        // этого медленное нажатие с дрожью руки съедало бы нажатие, а элемент
        // оставался сдвинутым на пару точек. Если же палец водил дольше срока —
        // крошечный путь это НАМЕРЕННОЕ «чуть перетащить», и элемент остаётся
        // там, где его оставили (иначе панель после маленького переноса
        // телепортировалась обратно к точке захвата). Если палец успел
        // прокрутить содержимое карточки — это протяжка, а не тап: квадрат с
        // панелью просто фиксируем, нажатие не засчитывая.
        CGFloat pathX = stagePoint.x - _rawPressPoint.x;
        CGFloat pathY = stagePoint.y - _rawPressPoint.y;
        BOOL tinyQuick = (pathX * pathX + pathY * pathY) < kRawTapSlop * kRawTapSlop &&
                         (now - _rawStartTime) < kRawTapMaxTime;
        if (tinyQuick) {
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
    _rawSlider = nil;
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
    // Нажатия самой клавиатуры (она лежит поверх экрана) отбрасываем сразу:
    // панель часто оказывается ПОД клавиатурой, и каждая буква «нажимала» бы
    // строку под собой, а мы ещё и гасили бы клавиатуру при наборе.
    if (!CGRectIsEmpty(_keyboardFrame) && CGRectContainsPoint(_keyboardFrame, point)) { return; }

    // Пикер accent color открыт (всплывающая карточка поверх меню) — он
    // МОДАЛЬНЫЙ, поэтому проверяем ДО ВСЕГО меню. Тап по полю задаёт
    // насыщенность/яркость, по радужной полосе — оттенок; тап по чёрным полям
    // карточки глотается (под карточкой может лежать строка меню — до неё
    // нажатие не должно дойти); тап ПО МЕНЮ или пустому экрану закрывает
    // пикер. Раньше этот блок стоял ПОСЛЕ кнопок меню: нажатие срабатывало,
    // а пикер оставался открытым.
    if (_pickerCard != nil && !_pickerCard.hidden) {
        CGPoint local = [_pickerCard convertPoint:point fromView:self];
        CGRect square = _svSquare.frame;
        if (CGRectContainsPoint(square, local) && square.size.width > 0.0) {
            CGFloat sx = (local.x - square.origin.x) / square.size.width;
            CGFloat sy = (local.y - square.origin.y) / square.size.height;
            [self applyMenuAccentHue:sMenuAccentH
                          saturation:MIN(MAX(sx, 0.0), 1.0)
                          brightness:1.0 - MIN(MAX(sy, 0.0), 1.0)
                                save:YES];
        } else if (CGRectContainsPoint(_hueStrip.frame, local)) {
            CGFloat ratio = HUDAccentRatioAtY(local, _hueStrip);
            [self applyMenuAccentHue:HUDAccentHueAtRatio(ratio)
                          saturation:sMenuAccentS
                          brightness:sMenuAccentV
                                save:YES];
        } else if (!CGRectContainsPoint(_pickerCard.bounds, local)) {
            [self closePicker];   // тап по меню/пустому месту — закрываем
        }
        return;
    }

    UIView *hit = [self hitTest:point withEvent:nil];

    // Клавиатура открыта — тап МИМО поля гасит её (привычное iOS-«вне поля»,
    // как по пустому месту формы). Нажатия самой клавиатуры отсечены выше,
    // а тап по кнопке при этом тоже выполняется: сначала гасим — потом действие.
    if (_configNameField != nil && _configNameField.isFirstResponder &&
        (hit == nil || (hit != _configNameField && ![hit isDescendantOfView:_configNameField]))) {
        [_configNameField resignFirstResponder];
    }

    // Квадратик-триггер: нажатие только открывает/закрывает меню и никогда не
    // двигает квадрат.
    if (hit != nil && (hit == _trigger || [hit isDescendantOfView:_trigger])) { [self togglePanel]; return; }

    // Заголовок и фон колонки вкладок (внутри _panelHeader) сами по себе ничего
    // не делают — это зона переноса панели; кнопки вкладок лежат прямо в панели
    // и проверяются ниже.
    if (hit != nil && (hit == _panelHeader || [hit isDescendantOfView:_panelHeader])) { return; }

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
    for (HUDFlatSwitch *toggle in _switches) {
        UIView *row = toggle.superview;
        if (![self pointIsOnScrollRow:point row:row]) { continue; }
        toggle.on = !toggle.on;
        AscentHUDLog(@"[gesture] %@ -> %d", toggle.accessibilityIdentifier, (int)toggle.on);
        [self switchChanged:toggle];
        return;
    }

    // Строка accent color (вкладка Misc): тап по кнопке-квадратику СПРАВА от
    // надписи (и по всей строке — чтобы легко попадать) открывает пикер.
    if (_accentRow != nil && [self pointIsOnScrollRow:point row:_accentRow]) {
        [self togglePicker];
        return;
    }

    // Строка menu theme (вкладка Misc): тап выбирает тему ПО ПИЛЮЛЕ dark
    // или light. Надпись слева выбором не является — она просто подпись.
    if (_themeRow != nil && [self pointIsOnScrollRow:point row:_themeRow]) {
        CGPoint local = [_themeRow convertPoint:point fromView:self];
        if (CGRectContainsPoint(_themeDarkLabel.frame, local)) {
            [self setMenuLight:NO];
        } else if (CGRectContainsPoint(_themeLightLabel.frame, local)) {
            [self setMenuLight:YES];
        }
        return;
    }

    // Строка target (вкладка Aim): тап по ПИЛЮЛЕ head/neck/body/legs выбирает
    // цель; надпись слева выбором не является (как в menu theme).
    if (_targetRow != nil && [self pointIsOnScrollRow:point row:_targetRow]) {
        CGPoint local = [_targetRow convertPoint:point fromView:self];
        for (NSInteger i = 0; i < (NSInteger)_targetPills.count; i++) {
            if (CGRectContainsPoint(_targetPills[i].frame, local)) {
                HUDOverlaySetNumber(@"cheat.target", (double)i);
                [self updateTargetUI];
                AscentHUDLog(@"[gesture] cheat.target -> %ld", (long)i);
                break;
            }
        }
        return;
    }

    for (UISlider *slider in _sliders) {
        UIView *group = slider.superview;
        if (![self pointIsOnScrollRow:point row:group]) { continue; }
        CGPoint local = [slider convertPoint:point fromView:self];
        [self applyTapToSlider:slider atPoint:local];
        return;
    }

    // Вкладка Config: поле имени — вызываем системную клавиатуру.
    if (_configNameField != nil && [self pointIsOnScrollRow:point row:_configNameField]) {
        [_configNameField becomeFirstResponder];
        return;
    }

    // «создать конфиг»: снимок текущих переключателей и слайдеров.
    if (_configCreateButton != nil && [self pointIsOnScrollRow:point row:_configCreateButton]) {
        [self createConfigTapped];
        return;
    }

    // Строки конфигов: тап по строке (и по «▶») — запустить, тап по «✕» — удалить.
    for (NSInteger i = 0; i < (NSInteger)_configRows.count; i++) {
        UIView *row = _configRows[i];
        if (![self pointIsOnScrollRow:point row:row]) { continue; }
        CGPoint local = [row convertPoint:point fromView:self];
        if (local.x > row.bounds.size.width - 32.0) {
            [self deleteConfigAtIndex:i];
        } else {
            [self applyConfigAtIndex:i];
        }
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

/// Протяжка слайдера пальцем: значение — прямо под точкой касания. Точку
/// события переводим в координаты САМОГО слайдера, поэтому повороты экрана и
/// перенос меню посреди жеста на расчёт не влияют. Файл при этом не пишем —
/// значение живёт в памяти до отпускания (см. commitRawDrag).
- (void)dragSlider:(UISlider *)slider toStagePoint:(CGPoint)stagePoint
{
    CGPoint local = [slider convertPoint:stagePoint fromView:_stage];
    CGFloat width = MAX(slider.bounds.size.width, 1.0);
    CGFloat ratio = MIN(MAX(local.x / width, 0.0), 1.0);
    slider.value = slider.minimumValue + (float)(ratio * (slider.maximumValue - slider.minimumValue));
    [self updateSliderLabel:slider.accessibilityIdentifier];
}

/// Ограничивает сдвиг за ОДНО событие: элемент идёт в направлении точки, куда
/// вёл палец, но за событие проходит не больше limit. Нужно, чтобы мусорное
/// событие с чужими координатами не увозило квадрат/панель на сотни точек и
/// чтобы настоящий рывок не превращался в «залипание» (см. kRawDragStepMax).
/// Отсчёт при этом не сбивается: цель каждый раз считается от точки нажатия,
/// поэтому следующее нормальное событие сразу ставит элемент на место.
static CGPoint LimitStep(CGPoint from, CGPoint to, CGFloat limit)
{
    CGFloat dx = to.x - from.x;
    CGFloat dy = to.y - from.y;
    CGFloat len = sqrt(dx * dx + dy * dy);
    if (len <= limit || len < 0.0001) { return to; }
    CGFloat scale = limit / len;
    return CGPointMake(from.x + dx * scale, from.y + dy * scale);
}

- (void)applyRawDragDelta:(CGPoint)delta
{
    if (_rawTarget == HUDRawDragTrigger) {
        CGPoint center = CGPointMake(_rawStartCenter.x + delta.x, _rawStartCenter.y + delta.y);
        center = LimitStep(_trigger.center, center, kRawDragStepMax);
        center = [self clampTriggerCenter:center];
        _trigger.center = center;
        CGPoint base = [self triggerBaseCenter];
        _triggerOffset = CGSizeMake(center.x - base.x, center.y - base.y);
        return;
    }

    if (_rawTarget == HUDRawDragPanel) {
        // Размер панели берём ТОТ ЖЕ, что применит layoutPanel после жеста: он
        // считается от dragArea (а bounds панели во время переноса не
        // пересчитываются — раскладка пропущена). Иначе смещение сохранялось бы
        // «от другого размера», и на отпускании панель телепортировалась бы.
        CGSize panelSize = [self panelSizeForArea:[self dragArea]];
        CGPoint center = CGPointMake(_rawStartCenter.x + delta.x, _rawStartCenter.y + delta.y);
        center = LimitStep(_panel.center, center, kRawDragStepMax);
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
    if (_rawTarget == HUDRawDragPickerSV || _rawTarget == HUDRawDragPickerHue) {
        // Палец отпущен после перетаскивания: цвет уже применён кэшем, файл
        // пишем разово (во время движения пальца plist не трогали).
        HUDMenuAccentSave();
        sMenuAccentSavePending = NO;
        AscentHUDLog(@"[accent] перетаскивание закончено, цвет h=%.0f s=%.2f v=%.2f",
                     sMenuAccentH, sMenuAccentS, sMenuAccentV);
        return;
    }

    if (_rawTarget == HUDRawDragPickerCard) {
        // Палец отпущен после переноса карточки: позицию клампим и пишем один
        // раз — как у панели, чтобы пикер встал туда же при следующем открытии.
        CGPoint center = [self clampPickerCenter:_pickerCard.center];
        _pickerCard.center = center;
        CGSize offset = [self pickerOffsetForCenter:center];
        _pickerOffset = offset;
        // Одна запись файла вместо двух: HUDOverlaySetNumber на каждый вызов
        // заново читал весь plist и писал его — на отпускании пальца это
        // было две пары «чтение+запись» диска.
        NSMutableDictionary *dict = HUDOverlayDict();
        dict[@"hud.picker.x"] = @(offset.width);
        dict[@"hud.picker.y"] = @(offset.height);
        HUDOverlayWrite(dict);
        AscentHUDLog(@"[gesture] пикер: перетаскивание закончилось, смещение=(%.0f, %.0f)",
                     offset.width, offset.height);
        return;
    }

    // Ползунок: пока палец ездил, значение менялось только в памяти (см.
    // dragSlider:toStagePoint:); файл пишем один раз — здесь, на отпускании.
    if (_rawTarget == HUDRawDragSlider) {
        if (_rawSlider != nil) {
            AscentHUDLog(@"[gesture] %@ = %.2f (отпускание)", _rawSlider.accessibilityIdentifier, _rawSlider.value);
            [self sliderChanged:_rawSlider];
        }
        _rawSlider = nil;
        return;
    }

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
        // Размер — как в applyRawDragDelta:, чтобы смещение совпало с тем, что
        // восстановит layoutPanel сразу после жеста (без «прыжка» на отпускании).
        CGSize panelSize = [self panelSizeForArea:[self dragArea]];
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
    // Пикер — всплывающая карточка в сцене: при повороте/раскладке
    // пересчитываем её позицию по центру сцены.
    if (_pickerCard != nil && !_pickerCard.hidden) { [self layoutPicker]; }
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

// Отступ сверху берём тем же, что было в запасном квадрате приложения
// (LoaderView: top = max(safeArea.top, 44)). Запасной квадрат приложения больше
// не рисуется — его убрали, рисует только HUD — но правило оставили: оно держит
// базовую позицию квадрата и шапку панели ниже статус-бара на любых устройствах.
- (CGFloat)safeTop
{
    return MAX(self.safeAreaInsets.top, 44.0);
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

/// Зона ПЕРЕНОСА — весь экран целиком. Раньше здесь была «безопасная» полоса
/// (safe area сверху + отступы по бокам), и в портрете у панели оставалось
/// всего несколько десятков точек хода: казалось, что элемент упирается в
/// невидимый барьер и двигать его почти нельзя. Теперь барьера нет: квадрат и
/// панель едут от самого верха до самого низа и от края до края — ограничение
/// одно, самое разумное: не выйти за экран.
- (CGRect)dragArea
{
    CGRect stage = [self stageBounds];
    return CGRectInset(stage, kEdgeMargin, kEdgeMargin);
}

- (CGPoint)clampTriggerCenter:(CGPoint)center
{
    CGRect area = [self dragArea];
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
    if (_panel == nil) { return; }   // панель ещё собирается — тап игнорируем
    _panelOpen = !_panelOpen;
    AscentHUDLog(@"HUD: панель %@", _panelOpen ? @"открыта" : @"закрыта");
    // Любую текущую анимацию появления/исчезновения отменяем: без этого
    // быстрое повторное нажатие подменяло кадры (completion от закрытия прятал
    // только что открытую панель).
    [_panel.layer removeAllAnimations];
    if (_panelOpen) {
        [self reloadCheatControls];
        [self selectTab:_tab];
        // _captureHidden: при записи экрана панель остаётся скрытой, даже если
        // квадрат «открылся» — иначе меню засветилось бы в записи.
        _panel.hidden = _captureHidden;
        _panel.userInteractionEnabled = YES;
        // Появление — с анимацией (по заказу): короткий фейд внутрь.
        _panel.alpha = 0.0;
        [UIView animateWithDuration:kMenuFadeDuration animations:^{
            _panel.alpha = 1.0;
        }];
    } else {
        // При закрытии гасим клавиатуру: она могла остаться от поля имени
        // конфига, и без этого висела бы поверх игры. Пикер тоже закрываем —
        // он открывался из меню и без меню смысла не имеет.
        [_configNameField resignFirstResponder];
        [self closePicker];
        // Исчезновение — с анимацией; на время фейда панель не ловит тапы
        // (иначе невидимые кнопки нажимались бы пальцем наугад).
        _panel.userInteractionEnabled = NO;
        [UIView animateWithDuration:kMenuFadeDuration animations:^{
            _panel.alpha = 0.0;
        } completion:^(BOOL finished) {
            // finished == NO — анимацию отменили (меню снова открыли):
            // прятать и трогать alpha в этом случае нельзя.
            if (finished) {
                _panel.hidden = YES;
                _panel.alpha = 1.0;
            }
        }];
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
    [button setTitleColor:HUDText() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    return button;
}

#pragma mark - Панель (сборка)

- (void)buildPanel
{
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidthMax, kPanelHeightMax)];
    _panel.backgroundColor = HUDFill();
    _panel.layer.cornerRadius = 16.0;   // WindowRounding = 16 у эталонного окна
    // По заказу БЕЛОЙ ОБВОДКИ у панели больше нет (была рамка 1 pt из HUDLine()).
    _panel.layer.borderWidth = 0.0;
    _panel.hidden = YES;

    // Раскладка как в меню-эталоне (MY IMGUI): заголовок слева сверху над
    // колонкой вкладок, справа — карточка контента во всю высоту. ПОЛНОШИРИННОЙ
    // шапки-полосы больше нет. _panelHeader — прозрачная зона переноса на ВСЮ
    // панель: в неё входят заголовок и фон колонки вкладок, а кнопки вкладок
    // и карточка лежат выше по z и перехватывают свои нажатия сами.
    // Кнопки-крестика нет — панель закрывается тапом по квадрату.
    _panelHeader = [[UIView alloc] initWithFrame:CGRectZero];
    _panelHeader.backgroundColor = [UIColor clearColor];
    [_panel addSubview:_panelHeader];

    _panelTitle = HUDLabel(@"@ascentios", 14, UIFontWeightHeavy);
    // Цвет заголовка управляется выбранным акцентом (вкладка Misc).
    _panelTitle.textColor = HUDMenuAccent();
    // Колонка узкая (как у эталона), поэтому при нехватке ширины заголовок
    // ужимается, а не обрезается многоточием.
    _panelTitle.adjustsFontSizeToFitWidth = YES;
    _panelTitle.minimumScaleFactor = 0.85;
    [_panelHeader addSubview:_panelTitle];

    // Метка времени СБОРКИ (компиляция — на CI, время UTC): мелко и внизу
    // колонки вкладок. Если на телефоне стоит старый .tipa, метка сразу
    // покажет «другое» время — без догадок, та ли установка.
    _buildLabel = HUDLabel([NSString stringWithFormat:@"build %.5s", __TIME__],
                           8, UIFontWeightMedium);
    _buildLabel.textColor = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.32];
    _buildLabel.textAlignment = NSTextAlignmentCenter;
    _buildLabel.adjustsFontSizeToFitWidth = YES;
    _buildLabel.minimumScaleFactor = 0.6;
    [_panelHeader addSubview:_buildLabel];

    // Фон колонки вкладок: тёмный #1a1a1a со скруглением 10 (левая панель
    // эталона). Лежит внутри _panelHeader → удержание на пустом месте колонки
    // тащит панель, как перетаскивание окна за фон.
    _sidebarBg = [[UIView alloc] initWithFrame:CGRectZero];
    _sidebarBg.backgroundColor = HUDCard();
    _sidebarBg.layer.cornerRadius = 10.0;
    [_panelHeader addSubview:_sidebarBg];

    // Колонка вкладок слева. Выбранная — красным текстом плюс красная
    // полоска у правого края колонки (как в эталонном меню).
    _tabButtons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[ @"Esp", @"Aim", @"Misc", @"Config" ];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *button = [self makeFlatButton:titles[i]];
        // Как в эталоне: подпись мелкая, по левому краю строки (у эталона
        // ButtonTextAlign = (0,0)), отступ слева 8 pt.
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
    _tabIndicator.backgroundColor = HUDMenuAccent();
    _tabIndicator.layer.cornerRadius = 1.5;
    [_panel addSubview:_tabIndicator];

    // Тёмная карточка содержимого справа — во всю высоту панели (как в
    // эталоне): сплошной #1a1a1a, скругление 10, без рамки.
    _contentCard = [[UIView alloc] initWithFrame:CGRectZero];
    _contentCard.backgroundColor = HUDCard();
    _contentCard.layer.cornerRadius = 10.0;
    _contentCard.clipsToBounds = YES;
    [_panel addSubview:_contentCard];

    _sectionTitle = HUDLabel(@"", 13, UIFontWeightSemibold);
    _sectionTitle.textColor = HUDText();
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
    [self startKeyboardObserver];

    [_stage addSubview:_panel];
}

/// Собираем всё содержимое вкладок сразу, а какие элементы видны — решает
/// раскладка по активной вкладке (см. layoutContentForTab:). Элементы лежат в
/// _scroll одним стеком и просто переставляются при смене вкладки.
- (void)buildContent
{
    _switches = [NSMutableArray array];
    // Четыре переключателя: esp, aimbot, overlay (вкладка Misc — прячет панель
    // и квадрат от записи экрана) и draw fov (вкладка Aim, по заказу — рисует
    // круг FOV в игре). Под-опции ESP (боксы, здоровье, имена, дистанция,
    // линии) из меню убраны. Порядок важен: layoutContentForTab: обращается к
    // элементам по индексу (0 esp, 1 aimbot, 2 overlay, 3 draw fov).
    NSArray<NSString *> *switchKeys = @[ @"cheat.esp",
                                         @"cheat.aimbot",
                                         @"misc.overlay",
                                         @"cheat.drawfov" ];
    NSArray<NSString *> *switchTitles = @[ @"Enable",
                                           @"Aimbot",
                                           @"Overlay",
                                           @"draw fov" ];
    for (NSInteger i = 0; i < (NSInteger)switchKeys.count; i++) {
        // Строка переключателя БЕЗ серо-белого фона (по заказу): подложка
        // alpha 0.07 на мелком шрифте выглядела как грязная плашка.
        UIView *row = HUDRoundedBox(12.0, [UIColor clearColor]);
        // И БЕЗ обводки: HUDRoundedBox рисует рамку 1 pt, которая на пустом
        // фоне строки стала чётко видна — по заказу её убираем.
        row.layer.borderWidth = 0.0;
        // Шрифт 12 (а не 13): карточка содержимого сузилась до 158 pt, чтобы
        // панель стала вертикальной, и «Distance» при 13 упиралось в край.
        UILabel *label = HUDLabel(switchTitles[i], 12, UIFontWeightMedium);
        // Кадр подписи задаёт раскладка строки (см. layoutSwitchRow:). Здесь
        // только запрещаем autoresizing: строка рождается нулевой, и «тянущаяся»
        // высота раздувала подпись вдвое — текст уезжал ниже середины строки.
        label.autoresizingMask = UIViewAutoresizingNone;
        [row addSubview:label];

        // Закруглённый тумблер вместо системного UISwitch (по заказу): своя
        // пилюля с круглым бегунком и плавной анимацией (см. HUDFlatSwitch).
        // Касания не обрабатывает (выставлено в initWithFrame: класса) —
        // состояние двигает только жест строки, иначе касания воюют с ним и
        // получается двойное переключение.
        HUDFlatSwitch *toggle = [[HUDFlatSwitch alloc] initWithFrame:
                                    CGRectMake(0, 0, kFlatSwitchW, kFlatSwitchH)];
        toggle.onColor = HUDSwitchOn();
        toggle.offColor = HUDSwitchOff();
        toggle.accessibilityIdentifier = switchKeys[i];
        [row addSubview:toggle];

        [self addTapGesture:row action:@selector(switchRowTapped:)];
        [_scroll addSubview:row];
        [_switches addObject:toggle];
    }

    // Строка accent color (вкладка Misc): надпись слева, свотч текущего
    // цвета СПРАВА от неё (по заказу) — он же кнопка: тап по свотчу и по
    // всей строке открывает HSV-пикер всплывающей карточкой поверх меню
    // (см. togglePicker). Иконки-палитры больше нет — убрана по заказу.
    _accentRow = [[UIView alloc] initWithFrame:CGRectZero];
    // Без серо-белой подложки (по заказу) — строка живёт только на фоне вкладки,
    // её читают надпись и свотч. Вкладка/раскладка при этом НЕ меняются.
    _accentRow.backgroundColor = [UIColor clearColor];
    _accentRow.layer.cornerRadius = 12.0;
    _accentRow.autoresizingMask = UIViewAutoresizingNone;
    _accentLabel = HUDLabel(@"accent color", 11, UIFontWeightMedium);
    _accentLabel.textColor = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.85];
    _accentLabel.autoresizingMask = UIViewAutoresizingNone;
    [_accentRow addSubview:_accentLabel];
    _accentSwatch = [[UIView alloc] initWithFrame:CGRectZero];
    _accentSwatch.backgroundColor = HUDMenuAccent();
    // Рамка СЕРАЯ, еле заметная и ПОТОНЬШЕ прежних 0.5 pt (по заказу: толстая
    // выглядела «пиксельной») — 0.35 pt мягче ложится на @2x. Углы, наоборот,
    // КРУТЧЕ (7 вместо 5) — свотч стал круглее; сам он меньше (20, см.
    // layoutContentForTab).
    _accentSwatch.layer.cornerRadius = 7.0;
    _accentSwatch.layer.borderWidth = 0.35;
    _accentSwatch.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
    _accentSwatch.userInteractionEnabled = NO;
    [_accentRow addSubview:_accentSwatch];

    [_scroll addSubview:_accentRow];

    // Строка menu theme (вкладка Misc): выбор ТЕМЫ — НЕ переключатель (по
    // заказу), а две пилюли dark | light справа от надписи; активную
    // подсвечивает updateThemeSegmentUI (нейтральной заливкой, без акцента).
    // Значение лежит в plist (hud.theme) и применяется мгновенно: светлая
    // тема красит фон панели в белый (см. setMenuLight).
    _themeRow = [[UIView alloc] initWithFrame:CGRectZero];
    _themeRow.backgroundColor = [UIColor clearColor];
    _themeRow.autoresizingMask = UIViewAutoresizingNone;
    _themeLabel = HUDLabel(@"menu theme", 11, UIFontWeightMedium);
    _themeLabel.textColor = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.85];
    // По заказу надпись обязана УМЕЩАТЬСЯ целиком: раньше при нехватке ширины
    // она обрезалась до «menu the…». Ужимаем шрифт, а не режем текст.
    _themeLabel.adjustsFontSizeToFitWidth = YES;
    _themeLabel.minimumScaleFactor = 0.65;
    _themeLabel.lineBreakMode = NSLineBreakByClipping;
    _themeLabel.autoresizingMask = UIViewAutoresizingNone;
    [_themeRow addSubview:_themeLabel];
    _themeDarkLabel = HUDLabel(@"dark", 10, UIFontWeightSemibold);
    _themeLightLabel = HUDLabel(@"light", 10, UIFontWeightSemibold);
    for (UILabel *segment in @[ _themeDarkLabel, _themeLightLabel ]) {
        segment.textAlignment = NSTextAlignmentCenter;
        segment.layer.cornerRadius = 8.0;
        segment.clipsToBounds = YES;
        segment.autoresizingMask = UIViewAutoresizingNone;
        [_themeRow addSubview:segment];
    }
    [_scroll addSubview:_themeRow];

    // Строка target (вкладка Aim, по заказу): цель аимбота — четыре пилюли
    // head | neck | body | legs, выбранную красит updateTargetUI. Как и в
    // menu theme, НАДПИСЬ слева выбором не является — только пилюли.
    _targetRow = [[UIView alloc] initWithFrame:CGRectZero];
    _targetRow.backgroundColor = [UIColor clearColor];
    _targetRow.autoresizingMask = UIViewAutoresizingNone;
    _targetLabel = HUDLabel(@"target", 11, UIFontWeightMedium);
    _targetLabel.textColor = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.85];
    _targetLabel.adjustsFontSizeToFitWidth = YES;
    _targetLabel.minimumScaleFactor = 0.65;
    _targetLabel.lineBreakMode = NSLineBreakByClipping;
    _targetLabel.autoresizingMask = UIViewAutoresizingNone;
    [_targetRow addSubview:_targetLabel];
    _targetPills = [NSMutableArray array];
    for (NSString *name in @[ @"head", @"neck", @"body", @"legs" ]) {
        UILabel *pill = HUDLabel(name, 10, UIFontWeightSemibold);
        pill.textAlignment = NSTextAlignmentCenter;
        pill.layer.cornerRadius = 8.0;
        pill.clipsToBounds = YES;
        pill.autoresizingMask = UIViewAutoresizingNone;
        [_targetRow addSubview:pill];
        [_targetPills addObject:pill];
    }
    [_scroll addSubview:_targetRow];

    // Поле, полоса и маркеры пикера собираются лениво — при первом открытии
    // (см. ensurePickerCard). Здесь только перекрашиваем акцентные элементы
    // панели по загруженному HSV.
    [self updateAccentUI];

    // Ползунки вкладки Aim (по заказу вернули): fov — ОТ 10 ДО 100, значение
    // крупно справа от названия — и smooth. Раскладку задаёт layoutSliderGroup:
    // две подписи вверху (tag 1 — название, tag 2 — значение), сам ползунок
    // под ними; тянется пальцем сразу (см. HUDRawDragSlider).
    _sliders = [NSMutableArray array];
    _sliderValueLabels = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"cheat.fov", @"cheat.smooth" ]) {
        UIView *group = [[UIView alloc] initWithFrame:CGRectZero];
        group.autoresizingMask = UIViewAutoresizingNone;
        UILabel *titleLabel = HUDLabel([key isEqualToString:@"cheat.fov"] ? @"fov" : @"smooth",
                                       11, UIFontWeightMedium);
        titleLabel.tag = 1;
        titleLabel.autoresizingMask = UIViewAutoresizingNone;
        [group addSubview:titleLabel];
        UILabel *valueLabel = HUDLabel(@"", 11, UIFontWeightSemibold);
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.tag = 2;
        valueLabel.autoresizingMask = UIViewAutoresizingNone;
        [group addSubview:valueLabel];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
        slider.accessibilityIdentifier = key;
        slider.minimumTrackTintColor = HUDMenuAccent();
        slider.maximumTrackTintColor = HUDSoftFill();
        [group addSubview:slider];
        [_scroll addSubview:group];
        [_sliders addObject:slider];
        _sliderValueLabels[key] = valueLabel;
    }

    _unloadButton = [self makeFlatButton:@"unload"];
    // Шрифт как у подписей вкладок (12 Semibold), а не 14 Heavy — по заказу.
    _unloadButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _unloadButton.backgroundColor = HUDGray();
    _unloadButton.layer.cornerRadius = 12.0;
    [_unloadButton addTarget:self action:@selector(unloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addTapGesture:_unloadButton action:@selector(panelControlTapped:)];
    [_scroll addSubview:_unloadButton];

    // Имя нового конфига. Тап по полю (см. performTapAtPoint:) вызывает
    // СИСТЕМНУЮ клавиатуру iPhone — как обычное поле ввода в iOS.
    _configNameField = [[UITextField alloc] initWithFrame:CGRectZero];
    _configNameField.placeholder = @"имя конфига";
    _configNameField.backgroundColor = HUDSoftFill();
    _configNameField.layer.cornerRadius = 12.0;
    _configNameField.layer.borderWidth = 1.0;
    _configNameField.layer.borderColor = HUDLine().CGColor;
    _configNameField.textColor = HUDText();
    _configNameField.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _configNameField.tintColor = HUDAccent();
    _configNameField.returnKeyType = UIReturnKeyDone;
    _configNameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    _configNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _configNameField.enablesReturnKeyAutomatically = YES;
    UIView *fieldPad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _configNameField.leftView = fieldPad;
    _configNameField.leftViewMode = UITextFieldViewModeAlways;
    [_configNameField addTarget:self
                         action:@selector(configNameReturnTapped)
               forControlEvents:UIControlEventEditingDidEndOnExit];
    [_scroll addSubview:_configNameField];

    // «создать конфиг»: сохраняет текущие переключатели под именем
    // из поля (без имени — автоимя «Config N», см. createConfigTapped).
    // Цвет — обычный серый, как у кнопки unload.
    _configCreateButton = [self makeFlatButton:@"создать конфиг"];
    _configCreateButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
    _configCreateButton.backgroundColor = HUDGray();
    _configCreateButton.layer.cornerRadius = 12.0;
    [_configCreateButton addTarget:self
                            action:@selector(createConfigTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_configCreateButton];

    // Перекрашиваем всё собранное под текущую тему (см. sMenuLight): при
    // сборке это добивает цвета, которые палитра ещё не знала; при смене
    // темы этот же метод вызывает setMenuLight.
    [self applyMenuTheme];
}

/// Системная клавиатура: запоминаем её область, чтобы тапы ПО КЛАВИАТУРЕ не
/// летели в меню. Кадр приходит в координатах экрана; для полноэкранного
/// окна они совпадают с нашими, но на всякий случай приводим через convertRect:.
- (void)startKeyboardObserver
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardFrameChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (void)keyboardFrameChanged:(NSNotification *)note
{
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect frame = (value != nil) ? value.CGRectValue : CGRectZero;
    frame = CGRectIntersection([self convertRect:frame fromView:nil], self.bounds);
    _keyboardFrame = (CGRectIsNull(frame) || CGRectIsEmpty(frame)) ? CGRectZero : frame;
    AscentHUDLog(@"[keyboard] рамка=%@", NSStringFromCGRect(_keyboardFrame));
}

#pragma mark - Панель (раскладка)

/// Размер панели под фактическую площадь сцены. Ширина ограничена константой,
/// высота — и константой, и площадью: в ландшафте сцена всего ≈375 pt, поэтому
/// высокая панель уходила за верх экрана. Пропорцию держим ГОРИЗОНТАЛЬНОЙ —
/// меню должно расходиться влево-вправо, а не вверх.
- (CGSize)panelSizeForArea:(CGRect)area
{
    // Ширина — просто константа, пока влезает в площадь: в портрете и в
    // горизонтали меню ОДИНАКОВОГО размера (340×190 на iPhone 7). Раньше тут
    // резервировался запас на боковой перенос, и в портрете меню сжималось
    // до 273 pt, а в горизонтали было 340 — это и заметно. Теперь ход в
    // портрете небольшой (панель почти во всю ширину), ограничение одно —
    // не выйти за экран (см. clampPanelCenter).
    CGFloat width = MIN(MAX(area.size.width, 0), kPanelWidthMax);
    CGFloat height = MIN(kPanelHeightMax, MAX(area.size.height, 0));

    // Меню горизонтальное: ширина обязана быть заметно больше высоты, иначе
    // панель выглядит почти квадратной. Пропорция задана константой kPanelRatio
    // (1.55 ≈ 3:2) — именно она делает меню явным прямоугольником; если площадь
    // узкая, режем высоту вместе с шириной, иначе пропорция «перевернётся».
    CGFloat limit = floor(width / kPanelRatio);
    if (height > limit) {
        height = MAX(limit, 150.0);
    }
    return CGSizeMake(width, height);
}

/// Держим панель ВНУТРИ ЭКРАНА — а не в старой «безопасной» полосе. Считается
/// всегда — и во время перетаскивания тоже: уехать за край экрана панель не
/// может в принципе, а любой повторный расчёт раскладки даёт ровно ту же точку
/// (перетаскивание двигало панель «рывками» именно потому, что раскладка
/// откатывала её назад).
- (CGPoint)clampPanelCenter:(CGPoint)center size:(CGSize)panelSize
{
    CGRect area = [self dragArea];
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
    CGSize panelSize = [self panelSizeForArea:[self dragArea]];
    CGFloat baseX = (stage.size.width - panelSize.width) / 2.0;
    CGFloat baseY = stage.size.height * 0.74 - panelSize.height / 2.0;

    CGPoint center = CGPointMake(baseX + panelSize.width / 2.0 + _panelOffset.width,
                                 baseY + panelSize.height / 2.0 + _panelOffset.height);
    center = [self clampPanelCenter:center size:panelSize];

    _panel.bounds = CGRectMake(0, 0, panelSize.width, panelSize.height);
    _panel.center = center;
    _panel.layer.cornerRadius = 16.0;
    _panel.layer.masksToBounds = YES;

    CGFloat w = panelSize.width;
    CGFloat h = panelSize.height;

    // Раскладка как в меню-эталоне (MY IMGUI, окно 460×300): заголовок слева
    // сверху над колонкой вкладок, под ним тёмная колонка вкладок, справа —
    // карточка контента во всю высоту. Колонка ≈ 130/460 ширины панели,
    // отступы — общие (kCardInset).
    CGFloat inset = kCardInset;
    CGFloat titleTop = inset + 2.0;
    CGFloat titleH = 20.0;
    CGFloat sidebarX = inset;
    CGFloat sidebarW = floor(w * 0.285);
    CGFloat sidebarTop = titleTop + titleH + 10.0;
    CGFloat sidebarH = h - sidebarTop - inset;
    CGFloat cardX = sidebarX + sidebarW + inset;
    CGFloat cardY = inset;
    CGFloat cardW = w - cardX - inset;
    CGFloat cardH = h - 2.0 * inset;

    _panelHeader.frame = CGRectMake(0, 0, w, h);   // зона переноса — вся панель
    // По заказу надпись @ascentios ЧУТЬ ПРАВЕЕ прежнего отступа (8 вместо 3).
    _panelTitle.frame = CGRectMake(sidebarX + 8.0, titleTop,
                                   MAX(cardX - (sidebarX + 8.0) - 3.0, 40.0), titleH);
    _sidebarBg.frame = CGRectMake(sidebarX, sidebarTop, sidebarW, sidebarH);
    // Метка сборки — в самый низ колонки, под столбиком вкладок (у вкладок
    // «кучно сверху», снизу колонки всегда пусто).
    _buildLabel.frame = CGRectMake(sidebarX + 4.0,
                                   sidebarTop + sidebarH - 18.0,
                                   sidebarW - 8.0, 14.0);

    // Колонка вкладок: строки кучно сверху, снизу остаётся пустой край —
    // как в эталоне. Высоту ограничиваем и запасом снизу: иначе последняя
    // вкладка «уезжала» бы за край колонки и обрезалась маской панели.
    NSInteger tabCount = (NSInteger)_tabButtons.count;
    // По заказу вкладки ЕЩЁ БЛИЖЕ друг к другу: отступ сверху 2 и зазор 0 —
    // строки идут вплотную (было 3/2, а до того 5/5).
    CGFloat tabPadTop = 2.0;
    CGFloat tabGap = 0.0;
    CGFloat tabRowH = 24.0;
    if (tabCount > 0) {
        tabRowH = floor((sidebarH - tabPadTop - (tabCount - 1) * tabGap - 4.0) / (CGFloat)tabCount);
        tabRowH = MIN(24.0, MAX(tabRowH, 18.0));
    }
    CGFloat tabX = sidebarX + 6.0;
    CGFloat tabW = sidebarW - 20.0;   // справа остаётся зона полоски-индикатора
    CGFloat rowY = sidebarTop + tabPadTop;
    for (NSInteger i = 0; i < tabCount; i++) {
        UIButton *button = _tabButtons[i];
        button.frame = CGRectMake(tabX, rowY, tabW, tabRowH);
        BOOL selected = (i == _tab);
        button.backgroundColor = [UIColor clearColor];
        // Неактивные вкладки белые, активная — цветом выбранного акцента
        // (как в эталоне, только цвет выбирается на вкладке Misc).
        [button setTitleColor:(selected ? HUDMenuAccent() : HUDText()) forState:UIControlStateNormal];
        if (selected) {
            _tabIndicator.hidden = NO;
            CGFloat indicatorH = MAX(tabRowH * 0.68, 8.0);
            _tabIndicator.frame = CGRectMake(sidebarX + sidebarW - 11.0,
                                             rowY + (tabRowH - indicatorH) / 2.0,
                                             2.5, indicatorH);
        }
        rowY += tabRowH + tabGap;
    }

    _contentCard.frame = CGRectMake(cardX, cardY, cardW, cardH);

    static NSString *const kSectionTitles[4] = { @"ESP", @"AIM", @"MISC", @"CONFIG" };
    _sectionTitle.text = (_tab >= 0 && _tab < 4) ? kSectionTitles[_tab] : kSectionTitles[0];
    _sectionTitle.frame = CGRectMake(14, 12, cardW - 28, 20);

    _scroll.frame = CGRectMake(0, kSectionTop, cardW, MAX(cardH - kSectionTop, 0));
    [self layoutContentForTab:_tab width:cardW];
}

/// Раскладка содержимого активной вкладки: прячем всё лишнее и ставим нужные
/// элементы одним стеком сверху вниз. Заодно фиксируем contentSize прокрутки.
- (void)layoutContentForTab:(NSInteger)tab width:(CGFloat)w
{
    // Вкладка сменилась (в т.ч. после ухода на другую и обратно) — прокрутку
    // начинаем СВЕРХУ: долистанный до низа Aim при возврате не должен
    // открываться снизу. При обычных переложениях ТОЙ ЖЕ вкладки (раскладка
    // зовётся, например, при появлении клавиатуры) позицию НЕ трогаем.
    BOOL tabChanged = (_contentTab != tab);
    _contentTab = tab;

    CGFloat x = 10.0;
    CGFloat rowWidth = w - 20.0;
    CGFloat y = 4.0;   // контент чуть выше (по заказу)

    for (HUDFlatSwitch *toggle in _switches) { toggle.superview.hidden = YES; }
    for (UISlider *slider in _sliders) { slider.superview.hidden = YES; }
    _unloadButton.hidden = YES;
    _accentRow.hidden = YES;
    _themeRow.hidden = YES;
    _targetRow.hidden = YES;
    _configNameField.hidden = YES;
    _configCreateButton.hidden = YES;
    for (UIView *row in _configRows) { row.hidden = YES; }

    if (tab == 0) {
        // Вкладка ESP: только главный переключатель — под-опции (боксы,
        // здоровье, имена, дистанция, линии) из меню убраны.
        [self layoutSwitchRow:_switches[0] x:x y:&y width:rowWidth];
    } else if (tab == 1) {
        // Вкладка Aim (по заказу расширена): aimbot, draw fov, ползунки fov и
        // smooth и выбор цели target. Triggerbot убран.
        [self layoutSwitchRow:_switches[1] x:x y:&y width:rowWidth];
        [self layoutSwitchRow:_switches[3] x:x y:&y width:rowWidth];   // draw fov
        [self layoutSliderGroup:_sliders[0] x:x y:&y width:rowWidth];  // fov
        [self layoutSliderGroup:_sliders[1] x:x y:&y width:rowWidth];  // smooth

        // target: надпись слева, четыре пилюли head/neck/body/legs справа
        // (раскладка как у menu theme).
        _targetRow.hidden = NO;
        CGFloat targetRowH = 28.0;
        _targetRow.frame = CGRectMake(x, y, rowWidth, targetRowH);
        CGFloat pillH = 22.0;
        CGFloat pillGap = 4.0;
        CGFloat pillW = floor((rowWidth - 60.0 - pillGap * 3.0) / 4.0);
        CGFloat pillX = round(rowWidth - 12.0 - (pillW * 4.0 + pillGap * 3.0));
        CGFloat pillY = round((targetRowH - pillH) / 2.0);
        for (NSInteger i = 0; i < (NSInteger)_targetPills.count; i++) {
            _targetPills[i].frame = CGRectMake(round(pillX + i * (pillW + pillGap)),
                                               pillY, pillW, pillH);
        }
        _targetLabel.frame = CGRectMake(12.0, 0.0,
                                        MAX(0.0, pillX - 12.0 - 6.0), targetRowH);
        y += targetRowH + 4.0;
    } else if (tab == 2) {
        // Misc: переключатель overlay, строка accent color и кнопка unload.
        // Подписи-пояснения под кнопкой больше нет (убрана по заказу).
        [self layoutSwitchRow:_switches[2] x:x y:&y width:rowWidth];

        // Строка accent color: надпись слева, свотч текущего цвета СРАЗУ РЯДОМ
        // С НЕЙ (по заказу — раньше свотч висел у дальнего края строки). Тап
        // по свотчу и по всей строке открывает пикер всплывающей карточкой
        // поверх меню. Иконки-палитры больше нет.
        _accentRow.hidden = NO;
        // Строка компактная (20 вместо 26): большого резерва сверху и снизу
        // больше нет, вкладка Misc при этом укладывается в окно БЕЗ прокрутки.
        CGFloat accentRowH = 20.0;
        _accentRow.frame = CGRectMake(x, y, rowWidth, accentRowH);
        CGFloat accentSwatchSize = 20.0;   // меньше прежних 22 (по заказу)
        // Надпись — в её натуральную ширину, и свотч вплотную справа от неё.
        // Целые координаты — рамка и текст ложатся ровно на пиксели, без
        // «пиксельных» краёв.
        CGSize accentTextSize = [_accentLabel sizeThatFits:CGSizeMake(rowWidth, accentRowH)];
        CGFloat accentLabelW = ceil(accentTextSize.width);
        _accentLabel.frame = CGRectMake(12.0, 0.0, accentLabelW, accentRowH);
        _accentSwatch.frame = CGRectMake(round(12.0 + accentLabelW + 8.0),
                                         round((accentRowH - accentSwatchSize) / 2.0),
                                         accentSwatchSize, accentSwatchSize);
        y += accentRowH + 2.0;

        // menu theme: выбор ТЕМЫ — надпись слева, две пилюли dark | light
        // СПРАВА (как у accent color — раскладка та же). Реагируют только
        // пилюли (см. performTapAtPoint:), активную красит updateThemeSegmentUI.
        _themeRow.hidden = NO;
        CGFloat themeRowH = 30.0;
        _themeRow.frame = CGRectMake(x, y, rowWidth, themeRowH);
        CGFloat themeSegW = 52.0;
        CGFloat themeSegH = 22.0;
        // Целые координаты — как у свотча, чтобы рамки/заливки не «пикселили».
        CGFloat themeSegY = round((themeRowH - themeSegH) / 2.0);
        // Зазоры поуже (4 и 8 вместо 6 и 10) — надписи «menu theme» нужно
        // больше места, чтобы умещаться целиком (плюс ужимание шрифта).
        CGFloat themeLightX = round(rowWidth - 8.0 - themeSegW);
        CGFloat themeDarkX = round(themeLightX - 4.0 - themeSegW);
        _themeLightLabel.frame = CGRectMake(themeLightX, themeSegY, themeSegW, themeSegH);
        _themeDarkLabel.frame = CGRectMake(themeDarkX, themeSegY, themeSegW, themeSegH);
        _themeLabel.frame = CGRectMake(12.0, 0.0,
                                       MAX(0.0, themeDarkX - 12.0 - 6.0),
                                       themeRowH);
        y += themeRowH + 6.0;

        // unload: высота 32 вместо 46 — по заказу кнопка меньше.
        _unloadButton.hidden = NO;
        _unloadButton.frame = CGRectMake(x, y, rowWidth, 32);
        y += 32 + 6;
    } else {
        // Слайдеры fov/smooth/delay из вкладки убраны — сразу список конфигов.

        // Список конфигов перечитываем только когда он поменялся
        // (создали/удалили) — см. _configRowsDirty.
        if (_configRowsDirty) { [self rebuildConfigRows]; }

        // Имя нового конфига и кнопка создания. Тап по полю (см.
        // performTapAtPoint:) открывает СИСТЕМНУЮ клавиатуру iPhone.
        _configNameField.hidden = NO;
        _configNameField.frame = CGRectMake(x, y, rowWidth, 34.0);
        y += 34.0 + 6.0;

        _configCreateButton.hidden = NO;
        _configCreateButton.frame = CGRectMake(x, y, rowWidth, 38.0);
        y += 38.0 + 8.0;

        for (UIView *row in _configRows) {
            row.hidden = NO;
            row.frame = CGRectMake(x, y, rowWidth, 34.0);
            for (UIView *sub in row.subviews) {
                // 1 — имя, 2 — «▶» запустить, 3 — «✕» удалить.
                if (sub.tag == 1) { sub.frame = CGRectMake(12, 0, rowWidth - 76.0, 34.0); }
                if (sub.tag == 2) { sub.frame = CGRectMake(rowWidth - 58.0, 0, 20.0, 34.0); }
                if (sub.tag == 3) { sub.frame = CGRectMake(rowWidth - 30.0, 0, 22.0, 34.0); }
            }
            y += 34.0 + 6.0;
        }
        if (_configRows.count > 0) { y += 2.0; }
    }

    _scroll.contentSize = CGSizeMake(w, MAX(y, _scroll.bounds.size.height));
    if (tabChanged) { _scroll.contentOffset = CGPointZero; }
}

- (void)layoutSwitchRow:(HUDFlatSwitch *)toggle x:(CGFloat)x y:(CGFloat *)y width:(CGFloat)width
{
    UIView *row = toggle.superview;
    row.hidden = NO;
    row.frame = CGRectMake(x, *y, width, kSwitchRowHeight);

    // Тумблер СЛЕВА, подпись СПРАВА от него (по заказу). Тумблер закруглённый
    // (см. HUDFlatSwitch), никаких transform — кадр задаём напрямую, центрируя
    // по высоте строки.
    // По заказу вся группа (тумблер + подпись) ещё ЛЕВЕЕ — вплотную к левому
    // краю карточки (отступ 0 вместо 3) — и ВЫШЕ середины строки (на 6 pt).
    const CGFloat leftInset = 0.0;
    const CGFloat liftUp = 6.0;
    toggle.frame = CGRectMake(leftInset,
                              round((kSwitchRowHeight - kFlatSwitchH) / 2.0) - liftUp,
                              kFlatSwitchW, kFlatSwitchH);

    // Подпись — строго справа от тумблера, на всю высоту строки (высота
    // UILabel «тянется» от нулевого кадра, если её задать неполной — раньше
    // текст уезжал ниже середины), с тем же подъёмом на 6 pt вверх.
    CGFloat labelX = leftInset + kFlatSwitchW + 12.0;
    for (UIView *sub in row.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            sub.frame = CGRectMake(labelX, -liftUp,
                                   MAX(0.0, width - labelX - 12.0),
                                   kSwitchRowHeight);
        }
    }
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
    // Переключение вкладки — с анимацией (по заказу): старое содержимое
    // перетекает в новое (кросс-фейд transitionWithView берёт «до» и «после»
    // карточки целиком — номер вкладки и цвет индикатора тоже перетекают).
    [UIView transitionWithView:_scroll
                      duration:kMenuFadeDuration
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    } completion:nil];
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

- (HUDFlatSwitch *)switchInRow:(UIView *)row
{
    for (UIView *sub in row.subviews) {
        if ([sub isKindOfClass:[HUDFlatSwitch class]]) { return (HUDFlatSwitch *)sub; }
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
    HUDFlatSwitch *toggle = [self switchInRow:gesture.view];
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
    for (HUDFlatSwitch *toggle in _switches) {
        NSString *key = toggle.accessibilityIdentifier;
        toggle.on = HUDOverlayFlag(key, HUDSwitchDefault(key));
    }
    for (UISlider *slider in _sliders) {
        NSString *key = slider.accessibilityIdentifier;
        [self configureSlider:slider forKey:key];
        slider.value = (float)HUDOverlayNumber(key, slider.value);
        // Старые файлы могли сохранить fov из прежнего диапазона 20..400 —
        // такое значение вне новых рамок 10..100 клэмпим, иначе ползунок стоял
        // бы «за краем».
        if (slider.value < slider.minimumValue) { slider.value = slider.minimumValue; }
        if (slider.value > slider.maximumValue) { slider.value = slider.maximumValue; }
        [self updateSliderLabel:key];
    }
}

- (void)configureSlider:(UISlider *)slider forKey:(NSString *)key
{
    if ([key isEqualToString:@"cheat.fov"]) {
        // По заказу: fov выбирается ОТ 10 ДО 100, стартовое значение 45.
        slider.minimumValue = 10; slider.maximumValue = 100; slider.value = 45;
    } else if ([key isEqualToString:@"cheat.smooth"]) {
        slider.minimumValue = 1; slider.maximumValue = 20; slider.value = 4;
    } else {
        slider.minimumValue = 0; slider.maximumValue = 300; slider.value = 60;
    }
}

- (NSString *)suffixForKey:(NSString *)key
{
    if ([key isEqualToString:@"cheat.fov"]) { return @""; }   // просто число, по заказу
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

- (void)switchChanged:(HUDFlatSwitch *)sender
{
    HUDOverlaySetFlag(sender.accessibilityIdentifier, sender.on);
    if ([sender.accessibilityIdentifier isEqualToString:@"misc.overlay"]) {
        // Сразу применяем видимость: если запись уже идёт, панель и квадрат
        // исчезнут в тот же кадр.
        [self applyCaptureVisibility];
    }
}

#pragma mark - Скрытие при записи экрана (вкладка Misc)

/// misc.overlay — панель и триггер не должны попадать в запись экрана или
/// зеркалирование. iOS отдаёт приложению надёжный признак захвата только для
/// ЗАПИСИ/AirPlay (UIScreen.isCaptured + уведомление о смене захвата), поэтому
/// запись скрывается всегда. Дополнительно пробуем приватный флаг secure у
/// окна — secure-окна не попадают в скриншоты; если селектора на этой версии
/// UIKit нет, вызов просто пропускается.
- (void)applyCaptureVisibility
{
    BOOL enabled = HUDOverlayFlag(@"misc.overlay", NO);
    BOOL wantHide = enabled && UIScreen.mainScreen.isCaptured;
    [self setWindowSecure:enabled];
    if (wantHide == _captureHidden) { return; }
    _captureHidden = wantHide;
    if (wantHide) {
        // Скрытая панель не должна продолжать чужой жест; пикер тоже
        // прячем явно — он в том же окне, что и меню, но закрытый пикер
        // не должен «всплыть» после конца записи.
        [self closePicker];
        [self endRawGesture];
        _panel.hidden = YES;
        _trigger.hidden = YES;
        AscentHUDLog(@"HUD: запись экрана — панель и квадрат скрыты");
    } else {
        _panel.hidden = !_panelOpen;
        _trigger.hidden = NO;
        AscentHUDLog(@"HUD: запись экрана закончилась — панель и квадрат показаны");
    }
}

- (void)screenCaptureChanged:(NSNotification *)note
{
    (void)note;
    [self applyCaptureVisibility];
}

/// Приватный флаг secure окна (если есть на этой версии UIKit): secure-окна
/// исключаются из скриншотов. Селектор проверяем — без него это тихий no-op.
- (void)setWindowSecure:(BOOL)secure
{
    UIWindow *window = self.window;
    SEL selector = NSSelectorFromString(@"setSecure:");
    if (window == nil || ![window respondsToSelector:selector]) { return; }
    NSMethodSignature *signature = [window methodSignatureForSelector:selector];
    if (signature == nil) { return; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = window;
    invocation.selector = selector;
    BOOL value = secure;
    [invocation setArgument:&value atIndex:2];
    [invocation invoke];
    AscentHUDLog(@"HUD: окно secure=%d (приватный флаг)", (int)secure);
}

/// Окно появляется позже создания оверлея — повторяем флаг secure, если
/// overlay уже включён.
- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window != nil) {
        [self setWindowSecure:HUDOverlayFlag(@"misc.overlay", NO)];
    }
}

#pragma mark - Accent color (вкладка Misc) и пикер в отдельном окне

/// Тап/перетаскивание по пикеру: ставим составляющую HSV (кэш + акцентные
/// элементы меню), при save — сразу пишем в plist. Во время перетаскивания
/// save=NO: файл пишется один раз при отпускании (см. commitRawDrag).
- (void)applyMenuAccentHue:(CGFloat)h saturation:(CGFloat)s brightness:(CGFloat)v save:(BOOL)save
{
    HUDMenuAccentSetHSV(h, s, v);
    if (save) { HUDMenuAccentSave(); }
    // save=NO — палец ещё ведёт: в файл пока не пишем, но помним, что
    // накопилось несохранённое (см. closePicker — там запись строго по флагу).
    sMenuAccentSavePending = !save;
    [self updateAccentUI];
    if (save) {
        AscentHUDLog(@"[accent] цвет h=%.0f s=%.2f v=%.2f", sMenuAccentH, sMenuAccentS, sMenuAccentV);
    }
}

/// Палец ведёт кружок или риску по пикеру: значение = позиция пальца
/// (точка экрана в координатах карточки пикера).
- (void)applyPickerDragAtPoint:(CGPoint)point
{
    CGPoint local = [_pickerCard convertPoint:point fromView:self];
    if (_rawTarget == HUDRawDragPickerSV) {
        CGRect sq = _svSquare.frame;
        if (sq.size.width <= 0.0) { return; }
        CGFloat sx = (local.x - sq.origin.x) / sq.size.width;
        CGFloat sy = (local.y - sq.origin.y) / sq.size.height;
        [self applyMenuAccentHue:sMenuAccentH
                      saturation:MIN(MAX(sx, 0.0), 1.0)
                      brightness:1.0 - MIN(MAX(sy, 0.0), 1.0)
                            save:NO];
    } else {
        CGFloat ratio = HUDAccentRatioAtY(local, _hueStrip);
        [self applyMenuAccentHue:HUDAccentHueAtRatio(ratio)
                      saturation:sMenuAccentS
                      brightness:sMenuAccentV
                            save:NO];
    }
}

/// Перекраска всего, что зависит от текущего HSV: акцентные элементы панели,
/// поле пикера (его горизонтальный градиент зависит от оттенка) и маркеры.
#pragma mark - Тема меню (dark / light)

/// Выбор темы в строке menu theme (вкладка Misc). Это НЕ переключатель, а
/// ВЫБОР: dark — как всегда, light — белый фон панели. Значение пишем в
/// plist парой «одно чтение + одна запись» (как акцент) и перекрашиваем
/// меню мгновенно — раскладка и набор элементов не меняются.
- (void)setMenuLight:(BOOL)light
{
    if (sMenuLight == light) { return; }
    sMenuLight = light;
    NSMutableDictionary *dict = HUDOverlayDict();
    dict[@"hud.theme"] = @(light ? 1 : 0);
    HUDOverlayWrite(dict);
    // Смена темы — ПЛАВНАЯ (по заказу), как появление меню: фоны, рамки и
    // текст перетекают в новые цвета за kMenuFadeDuration. Цвета градиента
    // триггера анимируются отдельно — CAGradientLayer не входит в UIView-блок.
    [UIView animateWithDuration:kMenuFadeDuration animations:^{
        [self applyMenuTheme];
    }];
    AscentHUDLog(@"[theme] menu theme -> %@", light ? @"light" : @"dark");
}

/// Перекраска меню под текущую тему (см. sMenuLight). Фоны/рамки задаём
/// ЯВНО — они выставляются при сборке панели и при rebuildConfigRows; весь
/// текст меняем единым обходом — подписи собраны из HUDLabel и живут своей
/// жизнью. Обход идемпотентен (меняет только цвет чужой темы), поэтому
/// метод можно звать и при сборке, и при смене темы.
- (void)applyMenuTheme
{
    _panel.backgroundColor = HUDFill();
    // Обводки у панели нет (по заказу) — borderColor не выставляем.
    _sidebarBg.backgroundColor = HUDCard();
    _contentCard.backgroundColor = HUDCard();
    // Квадрат-триггер следует теме меню (по заказу): в СВЕТЛОЙ теме он БЕЛЫЙ,
    // а ползунки-иконки на нём ЧЁРНЫЕ; в тёмной — прежний серый градиент с
    // белой иконкой. В light градиент почти плоский (чуть темнее книзу), чтобы
    // квадрат не слипался с белой панелью меню.
    NSArray *oldTriggerColors = _triggerGradient.colors;
    if (sMenuLight) {
        _triggerGradient.colors = @[ (id)[UIColor whiteColor].CGColor,
                                     (id)HUDColor(0.93, 0.93, 0.95).CGColor ];
        _triggerIcon.tintColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        _trigger.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.15].CGColor;
    } else {
        _triggerGradient.colors = @[ (id)HUDColor(0.52, 0.52, 0.56).CGColor,
                                     (id)HUDColor(0.29, 0.29, 0.33).CGColor ];
        _triggerIcon.tintColor = [UIColor whiteColor];
        _trigger.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    }
    // Градиент — «голый» слой и сам по себе НЕ входит в UIView-блок анимации:
    // при смене темы переливаем colors явно (на сборке старых цветов ещё нет —
    // анимация просто не добавляется).
    if (oldTriggerColors.count > 0) {
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"colors"];
        anim.fromValue = (id)oldTriggerColors;
        anim.toValue = (id)_triggerGradient.colors;
        anim.duration = kMenuFadeDuration;
        [_triggerGradient removeAllAnimations];
        [_triggerGradient addAnimation:anim forKey:@"colors"];
    }
    _sectionTitle.textColor = HUDText();
    _buildLabel.textColor = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.32];
    _unloadButton.backgroundColor = HUDGray();
    [_unloadButton setTitleColor:HUDText() forState:UIControlStateNormal];
    _configCreateButton.backgroundColor = HUDGray();
    [_configCreateButton setTitleColor:HUDText() forState:UIControlStateNormal];
    _configNameField.backgroundColor = HUDSoftFill();
    _configNameField.layer.borderColor = HUDLine().CGColor;
    _configNameField.textColor = HUDText();
    _accentLabel.textColor = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.85];
    _themeLabel.textColor = _accentLabel.textColor;
    for (HUDFlatSwitch *toggle in _switches) {
        toggle.onColor = HUDSwitchOn();
        toggle.offColor = HUDSwitchOff();
        [toggle refreshColors];
    }
    for (UIView *row in _configRows) {
        row.backgroundColor = HUDSoftFill();
        row.layer.borderColor = HUDLine().CGColor;
    }
    [self themeFlipLabelsIn:_panel];
    // Пикер собирается лениво и лежит в _stage ВНЕ панели — обходим отдельно,
    // если карточку уже создавали.
    if (_pickerCard != nil) {
        _pickerCard.backgroundColor = HUDFill();
        _pickerCard.layer.borderColor = HUDLine().CGColor;
        [self themeFlipLabelsIn:_pickerCard];
    }
    // Акцентные элементы и пилюли темы — ПОСЛЕ обхода: их цвета задаются
    // явно и от инверсии не должны зависеть.
    [self updateAccentUI];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

/// Единый обход текста: серо-белые цвета инвертируем в сторону текущей темы
/// (на светлой светлый текст становится тёмным — и наоборот, alpha
/// сохраняется). Цветной текст (акцент заголовка, зелёный «▶») не трогаем.
/// Правило «менять только цвет чужой темы» делает обход идемпотентным:
/// повторный проход ничего не переворачивает обратно.
- (void)themeFlipLabelsIn:(UIView *)view
{
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)sub;
            CGFloat r = 0, g = 0, b = 0, a = 0;
            if ([label.textColor getRed:&r green:&g blue:&b alpha:&a] &&
                fabs(r - g) < 0.03 && fabs(g - b) < 0.03 && a > 0.01) {
                CGFloat w = r;
                if ((sMenuLight && w > 0.5) || (!sMenuLight && w < 0.5)) {
                    [self setLabel:label
                  textColorAnimated:[UIColor colorWithWhite:1.0 - w alpha:a]];
                }
            }
        }
        [self themeFlipLabelsIn:sub];
    }
}

/// Пилюли dark | light в строке menu theme: активная — НЕЙТРАЛЬНОЙ серой
/// заливкой (как включённый тумблер), БЕЗ цвета акцента (по заказу: раньше она
/// красилась выбранным акцентом), неактивная — полупрозрачная подложка текущей
/// темы. Вызывается и после смены темы, и после смены акцента.
- (void)updateThemeSegmentUI
{
    if (_themeDarkLabel == nil || _themeLightLabel == nil) { return; }
    UIColor *plainFill = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0)
                                           alpha:(sMenuLight ? 0.06 : 0.10)];
    UIColor *plainText = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.55];
    // Активная пилюля: плотная серая заливка (та же, что у включённого
    // тумблера) — акцент больше не участвует.
    UIColor *activeFill = HUDSwitchOn();
    _themeDarkLabel.backgroundColor = sMenuLight ? plainFill : activeFill;
    [self setLabel:_themeDarkLabel textColorAnimated:(sMenuLight ? plainText : [UIColor whiteColor])];
    _themeLightLabel.backgroundColor = sMenuLight ? activeFill : plainFill;
    [self setLabel:_themeLightLabel
   textColorAnimated:(sMenuLight ? [UIColor whiteColor] : plainText)];
}

/// Пилюли head/neck/body/legs (вкладка Aim): выбранная — цветом акцента (как
/// активная вкладка), остальные — полупрозрачная подложка текущей темы.
/// Значение — индекс в plist (cheat.target), по умолчанию 0 (head).
- (void)updateTargetUI
{
    NSInteger index = (NSInteger)HUDOverlayNumber(@"cheat.target", 0.0);
    if (index < 0 || index >= (NSInteger)_targetPills.count) { index = 0; }
    UIColor *plainFill = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.06];
    UIColor *plainText = [UIColor colorWithWhite:(sMenuLight ? 0.0 : 1.0) alpha:0.55];
    UIColor *accent = HUDMenuAccent();
    for (NSInteger i = 0; i < (NSInteger)_targetPills.count; i++) {
        UILabel *pill = _targetPills[i];
        pill.backgroundColor = (i == index) ? accent : plainFill;
        pill.textColor = (i == index) ? [UIColor whiteColor] : plainText;
    }
}

/// UILabel.textColor НЕ анимируется от UIView-блока, а смена темы должна идти
/// ПЛАВНО — как фоны (см. setMenuLight). Поэтому цвет текста меняем с явной
/// анимацией foregroundColor: старый цвет берём ДО присваивания. На сборке
/// панели анимация безвредна — вью ещё не на экране.
- (void)setLabel:(UILabel *)label textColorAnimated:(UIColor *)color
{
    if (label == nil || color == nil || [label.textColor isEqual:color]) { return; }
    id from = (id)label.textColor.CGColor;
    label.textColor = color;
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"foregroundColor"];
    anim.fromValue = from;
    anim.toValue = (id)color.CGColor;
    anim.duration = kMenuFadeDuration;
    [label.layer addAnimation:anim forKey:@"foregroundColor"];
}

- (void)updateAccentUI
{
    UIColor *accent = HUDMenuAccent();
    _accentSwatch.backgroundColor = accent;
    _panelTitle.textColor = accent;
    _tabIndicator.backgroundColor = accent;

    // Активная вкладка — цветом акцента. Раскладка ставит этот цвет только
    // при ПЕРЕКЛЮЧЕНИИ вкладки (layoutPanel), поэтому без этой строки надпись
    // меняла бы цвет лишь после ухода на другую вкладку — именно тот баг:
    // выбрал чёрный, а надпись misc оставалась старого цвета.
    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        UIButton *button = _tabButtons[i];
        [button setTitleColor:(i == _tab ? accent : HUDText())
                     forState:UIControlStateNormal];
    }

    // Пилюли dark/light в строке menu theme: акцент в них БОЛЬШЕ НЕ участвует
    // (по заказу), но метод всё равно зовём — он держит их цвета в актуальной
    // теме.
    [self updateThemeSegmentUI];

    // Пилюли target (вкладка Aim) — выбранная акцентом; обновляем здесь же,
    // чтобы смена accent color сразу отражалась и на них.
    [self updateTargetUI];

    // Акцентная дорожка слайдеров и подложка — тем же текущим цветом (меню и
    // тема меняют их через этот же метод).
    for (UISlider *slider in _sliders) {
        slider.minimumTrackTintColor = accent;
        slider.maximumTrackTintColor = HUDSoftFill();
    }

    // Поле пикера: слева белый (s=0) → справа чистый цвет текущего оттенка.
    // Поля ещё может не быть — пикер собирается лениво при первом открытии.
    if (_svBase != nil) {
        // CAGradientLayer — «голый» слой, и Core Animation по умолчанию
        // АНИМИРУЕТ смену colors (кросс-фейд ~0.25 с): пока палец мотал полосу
        // оттенка, поле перекрашивалось с задержкой и «плавно» — цвет
        // отставал от пальца. Меняем мгновенно, без анимации.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _svBase.colors = @[
            (id)[UIColor whiteColor].CGColor,
            (id)[UIColor colorWithHue:sMenuAccentH / 360.0
                           saturation:1.0
                           brightness:1.0
                                alpha:1.0].CGColor,
        ];
        [CATransaction commit];
    }

    [self placeAccentSVMarker];
    [self placeAccentHueMarker];
}

/// Круг-маркер на выбранной точке поля: x = насыщенность, y = яркость
/// (сверху яркое, снизу чёрное — как в системном пикере).
- (void)placeAccentSVMarker
{
    CGRect sq = _svSquare.frame;
    if (sq.size.width <= 0.0) { return; }
    CGFloat cx = sq.origin.x + sMenuAccentS * sq.size.width;
    CGFloat cy = sq.origin.y + (1.0 - sMenuAccentV) * sq.size.height;
    _svMarker.bounds = CGRectMake(0.0, 0.0, 12.0, 12.0);
    _svMarker.center = CGPointMake(MIN(MAX(cx, sq.origin.x + 6.0), CGRectGetMaxX(sq) - 6.0),
                                   MIN(MAX(cy, sq.origin.y + 6.0), CGRectGetMaxY(sq) - 6.0));
    _svMarker.layer.cornerRadius = 6.0;
}

/// Белая риска на полосе оттенка (оттенок 0..360 сверху вниз).
- (void)placeAccentHueMarker
{
    CGRect strip = _hueStrip.frame;
    if (strip.size.height <= 0.0) { return; }
    CGFloat cy = strip.origin.y + (sMenuAccentH / 360.0) * strip.size.height;
    _hueMarker.frame = CGRectMake(strip.origin.x - 2.0, cy - 1.5,
                                  strip.size.width + 4.0, 3.0);
    _hueMarker.layer.cornerRadius = 1.5;
}

#pragma mark - Всплывающий пикер

/// Ленивая сборка карточки пикера: тёмная карточка с полем и радужной
/// полосой. Карточка лежит в _stage — том же слое HUD, что и меню, — поэтому
/// гарантированно рисуется поверх игры и поверх панели. Отдельное UIWindow
/// для этого НЕ годится: HUD живёт в системном окне поверх приложений, а
/// обычное окно приложения остаётся ПОД игрой — пикер был бы невидим (именно
/// поэтому кнопка «не нажималась»: пикер открывался, но его не было видно).
/// Касания в карточку приходят не сами: они идут в HUD по потоку HID и
/// разбираются геометрически (см. rawDragTargetAtPoint и
/// handleRawTouchPhase:).
- (void)ensurePickerCard
{
    if (_pickerCard != nil) { return; }

    _pickerCard = [[UIView alloc] initWithFrame:CGRectZero];
    _pickerCard.backgroundColor = HUDFill();
    _pickerCard.layer.cornerRadius = 16.0;
    _pickerCard.layer.borderWidth = 1.0;
    _pickerCard.layer.borderColor = HUDLine().CGColor;
    _pickerCard.hidden = YES;
    _pickerCard.userInteractionEnabled = NO;
    [_stage addSubview:_pickerCard];

    // Сохранённое смещение карточки читаем ОДИН раз на сессию (раньше это
    // были два полных чтения plist на каждое открытие пикера — см. layoutPicker).
    _pickerOffset = CGSizeMake(HUDOverlayNumber(@"hud.picker.x", 0.0),
                               HUDOverlayNumber(@"hud.picker.y", 0.0));

    // Поле: слева белое (насыщенность 0) → справа чистый цвет (1), сверху
    // яркое (v=1) → снизу чёрное (v=0). Скругление — на самих слоях
    // градиентов, чтобы контейнер не резал подложки и круг-маркер мог
    // вылезать за край.
    _svSquare = [[UIView alloc] initWithFrame:CGRectZero];
    _svBase = [CAGradientLayer layer];
    _svBase.startPoint = CGPointMake(0.0, 0.5);
    _svBase.endPoint = CGPointMake(1.0, 0.5);
    [_svSquare.layer addSublayer:_svBase];
    _svShade = [CAGradientLayer layer];
    _svShade.startPoint = CGPointMake(0.5, 0.0);
    _svShade.endPoint = CGPointMake(0.5, 1.0);
    _svShade.colors = @[
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor blackColor].CGColor,
    ];
    [_svSquare.layer addSublayer:_svShade];
    _svMarker = [[UIView alloc] initWithFrame:CGRectZero];
    _svMarker.backgroundColor = [UIColor clearColor];
    _svMarker.layer.borderWidth = 2.0;
    _svMarker.layer.borderColor = [UIColor whiteColor].CGColor;
    _svMarker.layer.shadowColor = [UIColor blackColor].CGColor;
    _svMarker.layer.shadowOpacity = 0.8;
    _svMarker.layer.shadowRadius = 2.0;
    _svMarker.layer.shadowOffset = CGSizeZero;
    _svMarker.userInteractionEnabled = NO;
    [_pickerCard addSubview:_svSquare];
    [_pickerCard addSubview:_svMarker];

    // Радужная полоса оттенка (градиент статичен: сверху красный 0°, донизу
    // снова красный 360°) — палец мотает её вверх-вниз.
    _hueStrip = [[UIView alloc] initWithFrame:CGRectZero];
    _hueGradient = [CAGradientLayer layer];
    _hueGradient.startPoint = CGPointMake(0.5, 0.0);
    _hueGradient.endPoint = CGPointMake(0.5, 1.0);
    _hueGradient.colors = @[
        (id)HUDColor(1.000, 0.000, 0.000).CGColor,   // красный (0°)
        (id)HUDColor(1.000, 0.850, 0.000).CGColor,   // жёлтый (60°)
        (id)HUDColor(0.000, 1.000, 0.000).CGColor,   // зелёный (120°)
        (id)HUDColor(0.000, 0.900, 0.900).CGColor,   // голубой (180°)
        (id)HUDColor(0.000, 0.000, 1.000).CGColor,   // синий (240°)
        (id)HUDColor(0.850, 0.000, 0.850).CGColor,   // пурпурный (300°)
        (id)HUDColor(1.000, 0.000, 0.000).CGColor,   // снова красный (360°)
    ];
    _hueGradient.locations = @[ @0.0, @(1.0/6.0), @(2.0/6.0), @(3.0/6.0),
                                @(4.0/6.0), @(5.0/6.0), @1.0 ];
    [_hueStrip.layer addSublayer:_hueGradient];
    _hueMarker = [[UIView alloc] initWithFrame:CGRectZero];
    _hueMarker.backgroundColor = [UIColor whiteColor];
    _hueMarker.layer.shadowColor = [UIColor blackColor].CGColor;
    _hueMarker.layer.shadowOpacity = 0.8;
    _hueMarker.layer.shadowRadius = 2.0;
    _hueMarker.layer.shadowOffset = CGSizeZero;
    _hueMarker.userInteractionEnabled = NO;
    [_pickerCard addSubview:_hueStrip];
    [_pickerCard addSubview:_hueMarker];
}

/// Центр карточки пикера для сохранённого смещения (смещение — от центра
/// сцены, как у панели: так позиция переживает поворот экрана).
- (CGPoint)pickerCenterForOffset:(CGSize)offset
{
    CGRect stage = _stage.bounds;
    return CGPointMake(stage.size.width / 2.0 + offset.width,
                       stage.size.height / 2.0 + offset.height);
}

- (CGSize)pickerOffsetForCenter:(CGPoint)center
{
    CGRect stage = _stage.bounds;
    return CGSizeMake(center.x - stage.size.width / 2.0,
                      center.y - stage.size.height / 2.0);
}

/// Кламп: карточка целиком остаётся на сцене (как панель — по всем краям).
- (CGPoint)clampPickerCenter:(CGPoint)center
{
    CGRect stage = _stage.bounds;
    CGSize size = _pickerCard.bounds.size;
    CGFloat halfW = size.width / 2.0;
    CGFloat halfH = size.height / 2.0;
    center.x = MIN(MAX(center.x, halfW), MAX(stage.size.width - halfW, halfW));
    center.y = MIN(MAX(center.y, halfH), MAX(stage.size.height - halfH, halfH));
    return center;
}

/// Раскладка карточки пикера: поле 150×150 слева, полоса оттенка справа,
/// карточка — в сохранённой позиции (по умолчанию — по центру сцены, то есть
/// по центру экрана; сцена повёрнута вместе с игрой, поэтому в ландшафте
/// карточка тоже стоит «правильно»).
- (void)layoutPicker
{
    // Во время переноса карточки позицией распоряжается сам жест —
    // пересчитывать её на каждый кадр незачем (иначе карточка «прыгала» бы
    // обратно к сохранённой точке). Раскладка вернётся сразу после отпускания.
    if (_dragging && _rawMoved) { return; }

    CGRect stage = _stage.bounds;
    CGFloat inset = 14.0;
    CGFloat square = 150.0;
    CGFloat stripW = 18.0;
    CGFloat gap = 10.0;
    CGFloat cardW = inset + square + gap + stripW + inset;
    CGFloat cardH = inset + square + inset;
    _pickerCard.frame = CGRectMake(0.0, 0.0, cardW, cardH);
    // Смещение — из кэша, без чтения диска: раньше тут были два полных
    // парса plist на каждом открытии, и пикер «открывался с задержкой».
    CGSize offset = _pickerOffset;
    _pickerCard.center = [self clampPickerCenter:[self pickerCenterForOffset:offset]];
    // Кадры — без самопроизвольной анимации: голые слои градиентов
    // (CAGradientLayer) иначе анимируют своё появление 0.25 с при первом
    // открытии — пикер выглядел «открывающимся с задержкой». При повороте
    // экрана layoutPicker вызывается внутри UIView-анимации — там транзакцию
    // с запретом действий НЕ открываем, чтобы поворот остался плавным.
    BOOL turning = ([UIView inheritedAnimationDuration] > 0.0);
    if (!turning) { [CATransaction begin]; [CATransaction setDisableActions:YES]; }
    _svSquare.frame = CGRectMake(inset, inset, square, square);
    _svBase.frame = _svSquare.bounds;
    _svBase.cornerRadius = 6.0;
    _svShade.frame = _svSquare.bounds;
    _svShade.cornerRadius = 6.0;
    _hueStrip.frame = CGRectMake(inset + square + gap, inset, stripW, square);
    _hueGradient.frame = _hueStrip.bounds;
    _hueGradient.cornerRadius = 4.0;
    if (!turning) { [CATransaction commit]; }
    [self placeAccentSVMarker];
    [self placeAccentHueMarker];
}

- (void)togglePicker
{
    if (_pickerCard != nil && !_pickerCard.hidden) {
        [self closePicker];
    } else {
        [self openPicker];
    }
}

/// Открывает пикер всплывающей карточкой поверх меню (кнопка-квадратик
/// справа от надписи accent color). Карточку поднимаем наверх слоя, чтобы
/// она была поверх панели.
- (void)openPicker
{
    [self ensurePickerCard];
    [self layoutPicker];
    [self updateAccentUI];
    [_stage bringSubviewToFront:_pickerCard];
    _pickerCard.hidden = NO;
    AscentHUDLog(@"[accent] пикер открыт");
}

/// Закрывает пикер (тап мимо карточки, закрытие меню, запись экрана).
- (void)closePicker
{
    if (_pickerCard == nil || _pickerCard.hidden) { return; }
    // Сначала скрываем — кадр закрытия уходит сразу. Раньше здесь, ДО
    // скрытия, стояли синхронные записи в plist, и закрытие «подтормаживало».
    // Файл и так сохранён при каждом изменении цвета (тап или отпускание
    // пальца), поэтому пишем только если перенос успели прервать — см.
    // sMenuAccentSavePending.
    _pickerCard.hidden = YES;
    if (sMenuAccentSavePending) {
        sMenuAccentSavePending = NO;
        HUDMenuAccentSave();
    }
    AscentHUDLog(@"[accent] пикер закрыт, цвет h=%.0f s=%.2f v=%.2f",
                 sMenuAccentH, sMenuAccentS, sMenuAccentV);
}

- (void)sliderChanged:(UISlider *)sender
{
    HUDOverlaySetNumber(sender.accessibilityIdentifier, sender.value);
    [self updateSliderLabel:sender.accessibilityIdentifier];
}

#pragma mark - Конфиги (вкладка Config)

/// Список строк конфигов: имя → [[▶] запустить] [[✕] удалить]. Пересобираем
/// только по _configRowsDirty (файл читаем один раз, а не на каждой раскладке).
- (void)rebuildConfigRows
{
    _configRowsDirty = NO;
    for (UIView *row in _configRows) { [row removeFromSuperview]; }
    [_configRows removeAllObjects];
    [_configNames removeAllObjects];

    NSDictionary *configs = AscentConfigsRead();
    NSArray *sorted = [configs.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *name in sorted) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
        row.backgroundColor = HUDSoftFill();
        row.layer.cornerRadius = 10.0;
        row.layer.borderWidth = 1.0;
        row.layer.borderColor = HUDLine().CGColor;

        UILabel *nameLabel = HUDLabel(name, 12.5, UIFontWeightSemibold);
        nameLabel.tag = 1;
        nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:nameLabel];

        UILabel *runLabel = HUDLabel(@"▶", 11, UIFontWeightBold);
        runLabel.tag = 2;
        runLabel.textAlignment = NSTextAlignmentCenter;
        runLabel.textColor = HUDGreen();
        [row addSubview:runLabel];

        UILabel *delLabel = HUDLabel(@"✕", 13, UIFontWeightBold);
        delLabel.tag = 3;
        delLabel.textAlignment = NSTextAlignmentCenter;
        delLabel.textColor = HUDDim();
        [row addSubview:delLabel];

        [_scroll addSubview:row];
        [_configRows addObject:row];
        [_configNames addObject:name];
    }
    AscentHUDLog(@"[config] строк в списке: %lu", (unsigned long)_configRows.count);
}

/// «создать конфиг»: снимок всех переключателей и слайдеров под именем из
/// поля. Без имени — автоимя «Config N» с первым свободным номером:
/// удалили Config 1 → следующий безымянный снова станет Config 1.
- (void)createConfigTapped
{
    [_configNameField resignFirstResponder];

    NSString *name = [_configNameField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        NSDictionary *existing = AscentConfigsRead();
        NSInteger n = 1;
        while (existing[[NSString stringWithFormat:@"Config %ld", (long)n]] != nil) { n++; }
        name = [NSString stringWithFormat:@"Config %ld", (long)n];
    }

    NSMutableDictionary *configs = [AscentConfigsRead() mutableCopy];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (HUDFlatSwitch *toggle in _switches) {
        values[toggle.accessibilityIdentifier] = @(toggle.on ? 1 : 0);
    }
    for (UISlider *slider in _sliders) {
        values[slider.accessibilityIdentifier] = @(slider.value);
    }
    configs[name] = values;
    AscentConfigsWrite(configs);

    _configNameField.text = @"";
    _configRowsDirty = YES;
    [self setNeedsLayout];
    AscentHUDLog(@"[config] создан «%@»", name);
}

/// «Запуск» конфига: пишем сохранённые значения в общий plist (те же ключи,
/// что читают холст ESP и память игры) и сразу показываем их на элементах.
- (void)applyConfigAtIndex:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)_configNames.count) { return; }
    NSString *name = _configNames[index];
    NSDictionary *values = AscentConfigsRead()[name];
    if (![values isKindOfClass:[NSDictionary class]]) {
        _configRowsDirty = YES;   // строка вела себя в файл — пересоберём
        [self setNeedsLayout];
        return;
    }

    for (HUDFlatSwitch *toggle in _switches) {
        NSNumber *value = values[toggle.accessibilityIdentifier];
        if (value == nil) { continue; }
        BOOL on = value.doubleValue > 0.5;
        toggle.on = on;
        HUDOverlaySetFlag(toggle.accessibilityIdentifier, on);
    }
    // misc.overlay мог измениться через конфиг — применяем видимость сразу,
    // иначе при уже идущей записи панель останется на экране до события.
    [self applyCaptureVisibility];
    for (UISlider *slider in _sliders) {
        NSNumber *value = values[slider.accessibilityIdentifier];
        if (value == nil) { continue; }
        float v = (float)value.doubleValue;
        v = MAX(slider.minimumValue, MIN(slider.maximumValue, v));
        slider.value = v;
        HUDOverlaySetNumber(slider.accessibilityIdentifier, v);
        [self updateSliderLabel:slider.accessibilityIdentifier];
    }
    AscentHUDLog(@"[config] запущен «%@»", name);
}

/// Удаление: имя — в руки, строка — из списка, номер освобождается для
/// автоимени (см. createConfigTapped).
- (void)deleteConfigAtIndex:(NSInteger)index
{
    if (index < 0 || index >= (NSInteger)_configNames.count) { return; }
    NSString *name = _configNames[index];
    NSMutableDictionary *configs = [AscentConfigsRead() mutableCopy];
    [configs removeObjectForKey:name];
    AscentConfigsWrite(configs);
    _configRowsDirty = YES;
    [self setNeedsLayout];
    AscentHUDLog(@"[config] удалён «%@»", name);
}

/// Return на клавиатуре (Done): с именем — сразу создаём конфиг, без имени —
/// просто гасим клавиатуру (пустой конфиг по случайности не создать).
- (void)configNameReturnTapped
{
    NSString *name = [_configNameField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length > 0) {
        [self createConfigTapped];
    } else {
        [_configNameField resignFirstResponder];
    }
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_usesDeviceOrientationFallback) {
        [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    } else {
        [_orientationObserver invalidate];
    }
}

@end
