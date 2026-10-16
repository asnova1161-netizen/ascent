#import <UIKit/UIKit.h>

@interface UIApplication (Private)

+ (void)initialize;
+ (void)instantiateSingleton:(Class)singletonClass;
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
- (void)_enqueueHIDEvent:(id)event;
- (id)_touchesEvent;
- (void)sendEvent:(UIEvent *)event;
- (id)valueForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;

@end
