#ifndef BackboardServices_h
#define BackboardServices_h

#ifdef __cplusplus
extern "C" {
#endif

void BKSDisplayServicesStart(void);
void BKSHIDEventRegisterEventCallback(void (*callback)(void *target, void *refcon, void *service, void *event));
void GSInitialize(void);
void GSEventInitialize(unsigned int flags);
void GSEventPushRunLoopMode(CFStringRef mode);
void UIApplicationInitialize(void);
void UIApplicationInstantiateSingleton(Class cls);

#ifdef __cplusplus
}
#endif

#endif
