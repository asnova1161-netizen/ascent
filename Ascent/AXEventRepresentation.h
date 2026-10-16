#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class AXEventPathInfoRepresentation;

@interface AXEventHandInfoRepresentation : NSObject

@property (nonatomic, copy, readonly) NSArray<AXEventPathInfoRepresentation *> *paths;

@end

@interface AXEventPathInfoRepresentation : NSObject

@property (nonatomic, readonly) NSInteger pathIdentity;

@end

@interface AXEventRepresentation : NSObject

+ (instancetype)representationWithHIDEvent:(id)event hidStreamIdentifier:(NSString *)identifier;

@property (nonatomic, readonly) CGPoint location;
@property (nonatomic, readonly) BOOL isTouchDown;
@property (nonatomic, readonly) BOOL isMove;
@property (nonatomic, readonly) BOOL isLift;
@property (nonatomic, readonly) BOOL isCancel;
@property (nonatomic, readonly) BOOL isInRange;
@property (nonatomic, readonly) BOOL isInRangeLift;
@property (nonatomic, readonly) AXEventHandInfoRepresentation *handInfo;

@end
