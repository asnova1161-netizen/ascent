#ifndef IOHIDEvent_KIF_h
#define IOHIDEvent_KIF_h

#import <Foundation/Foundation.h>
#import "IOKit+SPI.h"

/// Builds a fake multi-touch HID event out of an array of `UITouch` objects.
/// Used to synthesise touches that can be pushed through `-[UIApplication sendEvent:]`.
IOHIDEventRef kif_IOHIDEventWithTouches(NSArray *touches) CF_RETURNS_RETAINED;

#endif
