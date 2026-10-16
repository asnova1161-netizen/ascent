#import <UIKit/UIKit.h>

@interface UIEvent (Private)

- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;

@end
