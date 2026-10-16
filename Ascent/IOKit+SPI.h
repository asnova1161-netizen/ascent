#ifndef IOKit_SPI_h
#define IOKit_SPI_h

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceRef;
typedef void (*IOHIDEventCallback)(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event);

IOHIDEventRef IOHIDEventCreate(CFAllocatorRef allocator);
void IOKitStart(void);

#endif
