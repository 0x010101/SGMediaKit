//
//  SGNotification.h
//  SGPlayer
//
//  Created by Single on 16/8/15.
//  Copyright © 2016年 single. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SGPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface SGPlayer (SGNotification)
@property (nonatomic, strong, nullable) SGError * error;
@end

@interface SGNotification : NSObject

+ (void)postPlayer:(SGPlayer *)player error:(SGError *)error;
+ (void)postPlayer:(SGPlayer *)player statePrevious:(SGPlayerState)previous current:(SGPlayerState)current;
+ (void)postPlayer:(SGPlayer *)player progressPercent:(NSNumber *)percent current:(NSNumber *)current total:(NSNumber *)total;
+ (void)postPlayer:(SGPlayer *)player playablePercent:(NSNumber *)percent current:(NSNumber *)current total:(NSNumber *)total;

@end

NS_ASSUME_NONNULL_END
