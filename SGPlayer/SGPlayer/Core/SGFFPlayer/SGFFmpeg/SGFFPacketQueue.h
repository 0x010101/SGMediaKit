//
//  SGFFPacketQueue.h
//  SGMediaKit
//
//  Created by Single on 18/01/2017.
//  Copyright © 2017 single. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "avformat.h"

@interface SGFFPacketQueue : NSObject

+ (instancetype)packetQueueWithTimebase:(NSTimeInterval)timebase;

@property (nonatomic, assign, readonly) NSUInteger count;
@property (nonatomic, assign, readonly) int size;
@property (atomic, assign, readonly) NSTimeInterval duration;
@property (nonatomic, assign, readonly) NSTimeInterval timebase;

- (void)putPacket:(AVPacket)packet;
- (AVPacket)getPacket;

- (void)flush;
- (void)destroy;

@end
