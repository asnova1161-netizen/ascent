#import "HUDRootViewController.h"
#import <UIKit/UIKit.h>
#import "HUDHelper.h"

@implementation HUDRootViewController

static BOOL _passthroughMode = NO;

+ (BOOL)passthroughMode {
    return _passthroughMode;
}

+ (void)setPassthroughMode:(BOOL)value {
    _passthroughMode = value;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // Содержимое оверлея (квадрат и панель) рисует HUDOverlayView прямо в окне.
    // Пустой корневой вью не должен перехватывать касания: пусть они уходят
    // приложению под оверлеем.
    self.view.userInteractionEnabled = NO;

    AscentHUDLog(@"rootVC: viewDidLoad, bounds=%@ (контент рисует HUDOverlayView)",
                 NSStringFromCGRect(self.view.bounds));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    AscentHUDLog(@"rootVC: viewDidAppear, окно=%@", self.view.window);
}

// Окно держим строго портретным: контент оверлея (квадрат и панель) сам
// поворачивается вслед за устройством внутри HUDOverlayView. Так же делает
// TrollSpeed — иначе окно и контент крутились бы дважды.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return NO;
}

@end
