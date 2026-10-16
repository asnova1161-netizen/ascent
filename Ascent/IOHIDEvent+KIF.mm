//
//  IOHIDEvent+KIF.mm
//  KIF (adapted for ascent HUD)
//

#import "IOHIDEvent+KIF.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>

#define IOHIDEventFieldBase(type) (type << 16)

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

typedef UInt32 IOOptionBits;
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOHIDEventField;
typedef uint32_t IOHIDEventType;

void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef childEvent);
void IOHIDEventSetIntegerValue(IOHIDEventRef event, IOHIDEventField field, int value);
void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t sender);

enum {
    kIOHIDDigitizerTransducerTypeHand = 0,
    kIOHIDDigitizerTransducerTypeFinger,
};

enum {
    kIOHIDEventTypeDigitizer = 11,
};

enum {
    kIOHIDDigitizerEventRange = 1 << 0,
    kIOHIDDigitizerEventTouch = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
};

enum {
    kIOHIDEventFieldDigitizerX = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer),
    kIOHIDEventFieldDigitizerY,
    kIOHIDEventFieldDigitizerZ,
    kIOHIDEventFieldDigitizerButtonMask,
    kIOHIDEventFieldDigitizerType,
    kIOHIDEventFieldDigitizerIndex,
    kIOHIDEventFieldDigitizerIdentity,
    kIOHIDEventFieldDigitizerEventMask,
    kIOHIDEventFieldDigitizerRange,
    kIOHIDEventFieldDigitizerTouch,
    kIOHIDEventFieldDigitizerPressure,
    kIOHIDEventFieldDigitizerAuxiliaryPressure,
    kIOHIDEventFieldDigitizerTwist,
    kIOHIDEventFieldDigitizerTiltX,
    kIOHIDEventFieldDigitizerTiltY,
    kIOHIDEventFieldDigitizerAltitude,
    kIOHIDEventFieldDigitizerAzimuth,
    kIOHIDEventFieldDigitizerQuality,
    kIOHIDEventFieldDigitizerDensity,
    kIOHIDEventFieldDigitizerIrregularity,
    kIOHIDEventFieldDigitizerMajorRadius,
    kIOHIDEventFieldDigitizerMinorRadius,
    kIOHIDEventFieldDigitizerCollection,
    kIOHIDEventFieldDigitizerCollectionChord,
    kIOHIDEventFieldDigitizerChildEventMask,
    kIOHIDEventFieldDigitizerIsDisplayIntegrated,
    kIOHIDEventFieldDigitizerQualityRadiiAccuracy,
};

IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, AbsoluteTime timeStamp,
    IOHIDDigitizerTransducerType type, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y,
    IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, IOOptionBits options);

IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
    CFAllocatorRef allocator, AbsoluteTime timeStamp, uint32_t index,
    uint32_t identity, uint32_t eventMask, IOHIDFloat x, IOHIDFloat y,
    IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    IOHIDFloat minorRadius, IOHIDFloat majorRadius, IOHIDFloat quality,
    IOHIDFloat density, IOHIDFloat irregularity, Boolean range, Boolean touch,
    IOOptionBits options);

IOHIDEventRef kif_IOHIDEventWithTouches(NSArray *touches)
{
    uint64_t abTime = mach_absolute_time();
    AbsoluteTime timeStamp;
    timeStamp.hi = (UInt32)(abTime >> 32);
    timeStamp.lo = (UInt32)(abTime);

    IOHIDEventRef handEvent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timeStamp,
        kIOHIDDigitizerTransducerTypeHand,
        0,                                 // index
        0,                                 // identity
        kIOHIDDigitizerEventTouch,         // eventMask
        0,                                 // buttonMask
        0,                                 // x
        0,                                 // y
        0,                                 // z
        0,                                 // tipPressure
        0,                                 // barrelPressure
        0,                                 // range
        true,                              // touch
        0);                                // options

    IOHIDEventSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, true);

    for (UITouch *touch in touches) {
        uint32_t eventMask = (touch.phase == UITouchPhaseMoved)
            ? kIOHIDDigitizerEventPosition
            : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

        uint32_t isTouching = (touch.phase == UITouchPhaseEnded) ? 0 : 1;
        CGPoint location = [touch locationInView:touch.window];

        IOHIDEventRef fingerEvent = IOHIDEventCreateDigitizerFingerEventWithQuality(
            kCFAllocatorDefault,
            timeStamp,
            (UInt32)[touches indexOfObject:touch] + 1,
            2,
            eventMask,
            (IOHIDFloat)location.x,
            (IOHIDFloat)location.y,
            0.0,
            0,
            0,
            5.0,
            5.0,
            1.0,
            1.0,
            1.0,
            (IOHIDFloat)isTouching,
            (IOHIDFloat)isTouching,
            0);

        IOHIDEventSetIntegerValue(fingerEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

        IOHIDEventAppendEvent(handEvent, fingerEvent);
        CFRelease(fingerEvent);
    }

    return handEvent;
}
