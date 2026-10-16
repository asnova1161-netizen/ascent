//
//  IOHIDEvent+KIF.mm
//  KIF (adapted for ascent HUD)
//
//  The IOHIDEvent SPI lives in IOKit.framework, which we do not link against,
//  so every entry point is resolved dynamically at runtime.
//

#import "IOHIDEvent+KIF.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

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

typedef void (*IOHIDEventAppendEventFn)(IOHIDEventRef event, IOHIDEventRef childEvent);
typedef void (*IOHIDEventSetIntegerValueFn)(IOHIDEventRef event, IOHIDEventField field, int value);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFn)(
    CFAllocatorRef allocator, AbsoluteTime timeStamp,
    IOHIDDigitizerTransducerType type, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y,
    IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, IOOptionBits options);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventWithQualityFn)(
    CFAllocatorRef allocator, AbsoluteTime timeStamp, uint32_t index,
    uint32_t identity, uint32_t eventMask, IOHIDFloat x, IOHIDFloat y,
    IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    IOHIDFloat minorRadius, IOHIDFloat majorRadius, IOHIDFloat quality,
    IOHIDFloat density, IOHIDFloat irregularity, Boolean range, Boolean touch,
    IOOptionBits options);

static IOHIDEventAppendEventFn _IOHIDEventAppendEvent = NULL;
static IOHIDEventSetIntegerValueFn _IOHIDEventSetIntegerValue = NULL;
static IOHIDEventCreateDigitizerEventFn _IOHIDEventCreateDigitizerEvent = NULL;
static IOHIDEventCreateDigitizerFingerEventWithQualityFn _IOHIDEventCreateDigitizerFingerEventWithQuality = NULL;

static void *AscentResolveSymbol(const char *name)
{
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol == NULL) {
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        if (handle != NULL) {
            symbol = dlsym(handle, name);
        }
    }
    return symbol;
}

// Derived from
// https://opensource.apple.com/source/IOHIDFamily/IOHIDFamily-606.1.7/IOHIDFamily/IOHIDEventTypes.h

enum {
    kIOHIDDigitizerTransducerTypeStylus = 0,
    kIOHIDDigitizerTransducerTypePuck,
    kIOHIDDigitizerTransducerTypeFinger,
    kIOHIDDigitizerTransducerTypeHand,
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

IOHIDEventRef kif_IOHIDEventWithTouches(NSArray *touches)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _IOHIDEventAppendEvent = (IOHIDEventAppendEventFn)AscentResolveSymbol("IOHIDEventAppendEvent");
        _IOHIDEventSetIntegerValue = (IOHIDEventSetIntegerValueFn)AscentResolveSymbol("IOHIDEventSetIntegerValue");
        _IOHIDEventCreateDigitizerEvent = (IOHIDEventCreateDigitizerEventFn)AscentResolveSymbol("IOHIDEventCreateDigitizerEvent");
        _IOHIDEventCreateDigitizerFingerEventWithQuality = (IOHIDEventCreateDigitizerFingerEventWithQualityFn)AscentResolveSymbol("IOHIDEventCreateDigitizerFingerEventWithQuality");
    });

    if (_IOHIDEventAppendEvent == NULL ||
        _IOHIDEventSetIntegerValue == NULL ||
        _IOHIDEventCreateDigitizerEvent == NULL ||
        _IOHIDEventCreateDigitizerFingerEventWithQuality == NULL) {
        return NULL;
    }

    uint64_t abTime = mach_absolute_time();
    AbsoluteTime timeStamp;
    timeStamp.hi = (UInt32)(abTime >> 32);
    timeStamp.lo = (UInt32)(abTime);

    IOHIDEventRef handEvent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timeStamp,
        kIOHIDDigitizerTransducerTypeHand,
        0,                          // index
        0,                          // identity
        kIOHIDDigitizerEventTouch,  // eventMask
        0,                          // buttonMask
        0,                          // x
        0,                          // y
        0,                          // z
        0,                          // tipPressure
        0,                          // barrelPressure
        0,                          // range
        true,                       // touch
        0);                         // options

    _IOHIDEventSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, true);

    for (UITouch *touch in touches) {
        uint32_t eventMask = (touch.phase == UITouchPhaseMoved)
            ? kIOHIDDigitizerEventPosition
            : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

        Boolean isTouching = (touch.phase == UITouchPhaseEnded) ? false : true;
        CGPoint location = [touch locationInView:touch.window];

        IOHIDEventRef fingerEvent = _IOHIDEventCreateDigitizerFingerEventWithQuality(
            kCFAllocatorDefault,
            timeStamp,
            (uint32_t)[touches indexOfObject:touch] + 1,
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
            isTouching,
            isTouching,
            0);

        _IOHIDEventSetIntegerValue(fingerEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        _IOHIDEventAppendEvent(handEvent, fingerEvent);

        CFRelease(fingerEvent);
    }

    return handEvent;
}
