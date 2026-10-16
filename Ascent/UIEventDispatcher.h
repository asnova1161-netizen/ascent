#import <Foundation/Foundation.h>

@interface UIEventDispatcher : NSObject

- (void)_installEventRunLoopSources:(CFRunLoopRef)runLoop;

@end
