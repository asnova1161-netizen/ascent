#import "HUDRootViewController.h"
#import <SwiftUI/SwiftUI.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-module-import"
#import "Ascent-Swift.h"
#pragma clang diagnostic pop

@implementation HUDRootViewController

static BOOL _passthroughMode = NO;

+ (BOOL)passthroughMode {
    return _passthroughMode;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    
    Class HUDContainerViewClass = NSClassFromString(@"Ascent.HUDContainerView");
    id container = [[HUDContainerViewClass alloc] init];
    if ([container respondsToSelector:@selector(initWithMenuOpen:)]) {
        container = [[HUDContainerViewClass alloc] initWithMenuOpen:NO];
    } else if ([container respondsToSelector:@selector(initWithMenuOpen:)]) {
        // try
    }
    Class UIHostingControllerClass = NSClassFromString(@"_TtGC7SwiftUI19UIHostingControllerGVS_15ModifiedContentVS_7AnyViewVS_12RootModifier__");
    if (UIHostingControllerClass == nil) {
        UIHostingControllerClass = NSClassFromString(@"UIHostingController");
    }
    id hosting = [[UIHostingControllerClass alloc] initWithRootView:container];
    if ([hosting respondsToSelector:@selector(setViewBackgroundColor:)]) {
        [hosting setViewBackgroundColor:[UIColor clearColor]];
    } else {
        [hosting view].backgroundColor = [UIColor clearColor];
    }
    
    [self addChildViewController:hosting];
    [self.view addSubview:[hosting view]];
    [[hosting view] setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[[hosting view] topAnchor] constraintEqualToAnchor:self.view.topAnchor],
        [[[hosting view] leadingAnchor] constraintEqualToAnchor:self.view.leadingAnchor],
        [[[hosting view] trailingAnchor] constraintEqualToAnchor:self.view.trailingAnchor],
        [[[hosting view] bottomAnchor] constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [hosting didMoveToParentViewController:self];
}

@end
