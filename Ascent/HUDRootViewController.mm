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

    // The SwiftUI hosting controller is generic, so it cannot be referenced
    // statically from Objective-C. Ask the Swift factory to build it for us.
    id factory = (id)NSClassFromString(@"Ascent.HUDHostFactory");
    if (factory == nil) { factory = (id)NSClassFromString(@"HUDHostFactory"); }
    AscentHUDLog(@"rootVC: viewDidLoad, фабрика HUDHostFactory=%@", factory);
    if (factory == nil) { return; }

    id hostingObject = [factory performSelector:@selector(makeHostingController)];
    AscentHUDLog(@"rootVC: hosting controller=%@", hostingObject);
    if (hostingObject == nil) { return; }

    UIViewController *hosting = (UIViewController *)hostingObject;

    [self addChildViewController:hosting];
    [self.view addSubview:hosting.view];
    hosting.view.backgroundColor = [UIColor clearColor];
    hosting.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [hosting.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [hosting.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [hosting.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [hosting.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [hosting didMoveToParentViewController:self];
    AscentHUDLog(@"rootVC: SwiftUI-вью встроена, bounds=%@", NSStringFromCGRect(self.view.bounds));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    AscentHUDLog(@"rootVC: viewDidAppear, окно=%@", self.view.window);
}

@end
