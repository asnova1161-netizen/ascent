#import <notify.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "pac_helper.h"
#import "UIEventFetcher.h"
#import "UIEventDispatcher.h"
#import "HUDMainApplication.h"
#import "UIApplication+Private.h"

@implementation HUDMainApplication

// A plugin application does not get UIKit's normal event pipeline, so we
// install the private `UIEventDispatcher` run-loop sources and hook a
// `UIEventFetcher` up to it. That is what makes synthesized HID events
// (see TSEventFetcher) reach the HUD window's views.
- (instancetype)init
{
    if (self = [super init])
    {
        UIEventDispatcher *dispatcher = nil;
        @try {
            dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
        } @catch (__unused NSException *e) {
            dispatcher = nil;
        }

        if (dispatcher && [dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)])
        {
            [dispatcher _installEventRunLoopSources:CFRunLoopGetMain()];
        }

        if (dispatcher)
        {
            Class fetcherClass = objc_getClass("UIEventFetcher");
            if (fetcherClass)
            {
                UIEventFetcher *fetcher = [[fetcherClass alloc] init];
                [dispatcher setValue:fetcher forKey:@"eventFetcher"];

                if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)])
                {
                    [fetcher setEventFetcherSink:dispatcher];
                }
                else
                {
                    @try {
                        [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
                    } @catch (__unused NSException *e) {}
                }

                [self setValue:fetcher forKey:@"eventFetcher"];
            }
        }
    }
    return self;
}

@end
