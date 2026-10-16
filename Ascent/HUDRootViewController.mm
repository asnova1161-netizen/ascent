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
    
    HUDContainerView *container = [[HUDContainerView alloc] initWithMenuOpen:NO];
    UIHostingController *hosting = [[UIHostingController alloc] initWithRootView:container];
    hosting.view.backgroundColor = [UIColor clearColor];
    
    [self addChildViewController:hosting];
    [self.view addSubview:hosting.view];
    hosting.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [hosting.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [hosting.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [hosting.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [hosting.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [hosting didMoveToParentViewController:self];
}

@end
