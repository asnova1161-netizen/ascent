#import <Foundation/Foundation.h>

@interface UIEventFetcher : NSObject

- (void)setEventFetcherSink:(id)sink;
- (void)setValue:(id)value forKey:(NSString *)key;

@end
