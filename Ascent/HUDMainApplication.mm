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
// install the private `UIEventDispatcher` run-loop sources. Структура ровно
// как в рабочем TrollSpeed: если селектора у объекта нет, реализацию ищем
// разбором -[UIApplication _run], и в любом случае подключаем eventFetcher.
- (instancetype)init
{
    if (self = [super init])
    {
        do {
            UIEventDispatcher *dispatcher = NULL;

            @try {
                dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
            } @catch (NSException *exception) {
                AscentHUDLog(@"!!! HUDMainApplication: eventDispatcher не читается: %@", exception.reason);
            }

            AscentHUDLog(@"HUDMainApplication: eventDispatcher=%p", (__bridge void *)dispatcher);

            if (!dispatcher)
            {
                AscentHUDLog(@"!!! HUDMainApplication: eventDispatcher недоступен — run loop останется без источников событий");
                break;
            }

            if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)])
            {
                CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
                [dispatcher _installEventRunLoopSources:mainRunLoop];
                AscentHUDLog(@"HUDMainApplication: источники событий установлены, runLoop=%p", mainRunLoop);
            }
            else
            {
                // На этой iOS у объекта селектора нет, но реализация существует
                // и вызывается из -[UIApplication _run]. Без источников run loop
                // оверлея пустой. Разбор инструкций ниже — тот же, что в
                // рабочем TrollSpeed: ищем пару «mov x2, x0; mov x0, x?» и
                // следующий за ней bl на нужную реализацию.
                AscentHUDLog(@"!!! HUDMainApplication: селектор не отвечает — ищу реализацию в -[UIApplication _run]");

                IMP runMethodIMP = class_getMethodImplementation([self class], @selector(_run));
                if (runMethodIMP == NULL)
                {
                    AscentHUDLog(@"!!! HUDMainApplication: -[UIApplication _run] не найден");
                    break;
                }

                uint32_t *runMethodPtr = (uint32_t *)make_sym_readable((void *)runMethodIMP);
                void (*installRunLoopSources)(id, SEL, CFRunLoopRef) = NULL;

                for (int index = 0; index < 0x140; index++)
                {
                    // mov x2, x0
                    // mov x0, x?
                    if (runMethodPtr[index] != 0xaa0003e2 || (runMethodPtr[index + 1] & 0xff000000) != 0xaa000000)
                    {
                        continue;
                    }

                    // bl -[UIEventDispatcher _installEventRunLoopSources:]
                    uint32_t *branchPointer = &runMethodPtr[index + 2];
                    uint32_t branchInstruction = *branchPointer;
                    if ((branchInstruction & 0xfc000000) != 0x94000000)
                    {
                        AscentHUDLog(@"HUDMainApplication: не bl: 0x%x (%p)", branchInstruction, branchPointer);
                        continue;
                    }

                    int32_t branchOffset = branchInstruction & 0x03ffffff;
                    if (branchOffset & 0x02000000)
                    {
                        branchOffset |= 0xfc000000;
                    }
                    branchOffset <<= 2;

                    uint64_t targetAddress = (uint64_t)branchPointer + branchOffset;
                    uint32_t *target = (uint32_t *)make_sym_readable((void *)targetAddress);

                    // cbz x0, ... — признак начала функции.
                    if ((*target & 0xff000000) != 0xb4000000)
                    {
                        AscentHUDLog(@"HUDMainApplication: не cbz: 0x%x (%p)", *target, target);
                        continue;
                    }

                    AscentHUDLog(@"HUDMainApplication: реализация найдена, адрес=%p", (void *)targetAddress);
                    installRunLoopSources = (void (*)(id, SEL, CFRunLoopRef))make_sym_callable((void *)targetAddress);
                }

                if (installRunLoopSources == NULL)
                {
                    AscentHUDLog(@"!!! HUDMainApplication: реализация не найдена — run loop останется без источников событий");
                    break;
                }

                CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
                installRunLoopSources(dispatcher, @selector(_installEventRunLoopSources:), mainRunLoop);
                AscentHUDLog(@"HUDMainApplication: источники событий установлены вручную, runLoop=%p", mainRunLoop);
            }

            Class fetcherClass = objc_getClass("UIEventFetcher");
            if (fetcherClass == NULL)
            {
                AscentHUDLog(@"!!! HUDMainApplication: класс UIEventFetcher не найден");
                break;
            }

            UIEventFetcher *fetcher = [[fetcherClass alloc] init];
            [dispatcher setValue:fetcher forKey:@"eventFetcher"];

            if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)])
            {
                [fetcher setEventFetcherSink:dispatcher];
            }
            else
            {
                // Как в TrollSpeed: на iOS 15.1.1 и ниже сеттер приватный.
                @try {
                    [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
                } @catch (NSException *exception) {
                    AscentHUDLog(@"!!! HUDMainApplication: eventFetcherSink не выставлен: %@", exception.reason);
                }
            }

            [self setValue:fetcher forKey:@"eventFetcher"];
            AscentHUDLog(@"HUDMainApplication: eventFetcher подключён");
        } while (false);
    }
    return self;
}

@end
