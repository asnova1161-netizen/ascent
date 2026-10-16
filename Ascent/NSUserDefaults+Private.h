#import <Foundation/Foundation.h>

@interface NSUserDefaults (Private)

- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
- (void)registerDefaults:(NSDictionary *)registrationDictionary;

@end
