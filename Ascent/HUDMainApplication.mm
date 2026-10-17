#import <notify.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "pac_helper.h"
#import "UIEventFetcher.h"
#import "UIEventDispatcher.h"
#import "HUDMainApplication.h"
#import "HUDHelper.h"
#import "UIApplication+Private.h"

@implementation HUDMainApplication

// A plugin application does not get UIKit's normal event pipeline, so we
// install the private `UIEventDispatcher` run-loop sources and hook a
// `UIEventFetcher` up to it. That is what makes synthesized HID events
// (see TSEventFetcher) reach the HUD window's views.
//
// ВАЖНО: если источников не будет вообще, `CFRunLoopRun()` в HUDApp.mm
// вернётся сразу и процесс оверлея выйдет — квадрат пропадёт через долю
// секунды. Поэтому про каждый шаг пишем в журнал.
- (instancetype)init
{
    if (self = [super init])
    {
        UIEventDispatcher *dispatcher = nil;
        @try {
            dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
        } @catch (NSException *exception) {
            AscentHUDLog(@"HUDMainApplication: eventDispatcher бросил исключение: %@", exception.reason);
        }

        AscentHUDLog(@"HUDMainApplication: eventDispatcher=%p", (__bridge void *)dispatcher);

        if (!dispatcher)
        {
            AscentHUDLog(@"!!! HUDMainApplication: eventDispatcher недоступен — run loop останется без источников событий");
            return self;
        }

        if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)])
        {
            CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
            [dispatcher _installEventRunLoopSources:mainRunLoop];
            AscentHUDLog(@"HUDMainApplication: источники событий установлены, runLoop=%p", mainRunLoop);
        }
        else
        {
            AscentHUDLog(@"!!! HUDMainApplication: _installEventRunLoopSources: недоступен на этой iOS");
        }

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
                } @catch (NSException *exception) {
                    AscentHUDLog(@"HUDMainApplication: eventFetcherSink не выставлен: %@", exception.reason);
                }
            }

            [self setValue:fetcher forKey:@"eventFetcher"];
            AscentHUDLog(@"HUDMainApplication: eventFetcher подключён");
        }
        else
        {
            AscentHUDLog(@"!!! HUDMainApplication: класс UIEventFetcher не найден");
        }
    }
    return self;
}

@end
