//
//  UITouch+Private.h
//  FakeTouch / KIF
//

#import <UIKit/UIKit.h>
#import "IOKit+SPI.h"

@interface UITouch (Private)

- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)touchPhase;
- (void)setGestureView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)firstTouchForView;
- (void)_setIsTapToClick:(BOOL)isTapToClick;

- (void)_setHidEvent:(IOHIDEventRef)event;

@end
