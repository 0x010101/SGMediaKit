//
//  SGAVPlayer.m
//  SGPlayer
//
//  Created by Single on 16/6/28.
//  Copyright © 2016年 single. All rights reserved.
//

#import "SGAVPlayer.h"
#import "SGPlayer+DisplayView.h"
#import "SGPlayerMacro.h"
#import "SGNotification.h"
#import <AVFoundation/AVFoundation.h>

static CGFloat const PixelBufferRequestInterval = 0.03f;

@interface SGAVPlayer ()

@property (nonatomic, weak) SGPlayer * abstractPlayer;

@property (nonatomic, assign) SGPlayerState state;
@property (nonatomic, assign) NSTimeInterval playableTime;
@property (nonatomic, assign) BOOL seeking;

@property (atomic, strong) id playBackTimeObserver;
@property (nonatomic, strong) AVPlayer * avPlayer;
@property (nonatomic, strong) AVPlayerItem * avPlayerItem;
@property (atomic, strong) AVAsset * avAsset;
@property (atomic, strong) AVPlayerItemVideoOutput * avOutput;
@property (atomic, assign) NSTimeInterval readyToPlayTime;

@property (atomic, assign) BOOL needPlay;        // seek and buffering use
@property (atomic, assign) BOOL autoNeedPlay;    // background use
@property (atomic, assign) BOOL hasPixelBuffer;

@end

@implementation SGAVPlayer

+ (instancetype)playerWithAbstractPlayer:(SGPlayer *)abstractPlayer
{
    return [[self alloc] initWithAbstractPlayer:abstractPlayer];
}

- (instancetype)initWithAbstractPlayer:(SGPlayer *)abstractPlayer
{
    if (self = [super init]) {
        self.abstractPlayer = abstractPlayer;
        [self setupAVPlayer];
    }
    return self;
}

#pragma mark - play control

- (void)play
{
    if (self.state == SGPlayerStateFailed || self.state == SGPlayerStateFinished) {
        [self replaceEmpty];
    }
    
    [self tryReplaceVideo];
    
    switch (self.state) {
        case SGPlayerStateNone:
            self.state = SGPlayerStateBuffering;
            break;
        case SGPlayerStateSuspend:
        case SGPlayerStateReadyToPlay:
            self.state = SGPlayerStatePlaying;
        default:
            break;
    }
    
    [self.avPlayer play];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        switch (self.state) {
            case SGPlayerStateBuffering:
            case SGPlayerStatePlaying:
            case SGPlayerStateReadyToPlay:
                [self.avPlayer play];
            default:
                break;
        }
    });
}

- (void)setAutoPlayIfNeed
{
    switch (self.state) {
        case SGPlayerStatePlaying:
        case SGPlayerStateBuffering:
            self.state = SGPlayerStateSuspend;
            self.autoNeedPlay = YES;
            [self pause];
            break;
        default:
            break;
    }
}

- (void)cancelAutoPlayIfNeed
{
    if (self.autoNeedPlay) {
        self.autoNeedPlay = NO;
    }
}

- (void)autoPlayIfNeed
{
    if (self.autoNeedPlay) {
        [self play];
        self.autoNeedPlay = NO;
    }
}

- (void)setPlayIfNeed
{
    switch (self.state) {
        case SGPlayerStatePlaying:
            self.state = SGPlayerStateBuffering;
        case SGPlayerStateBuffering:
            self.needPlay = YES;
            [self.avPlayer pause];
            break;
        default:
            break;
    }
}

- (void)cancelPlayIfNeed
{
    if (self.needPlay) {
        self.needPlay = NO;
    }
}

- (void)playIfNeed
{
    if (self.needPlay) {
        self.state = SGPlayerStatePlaying;
        [self.avPlayer play];
        self.needPlay = NO;
    }
}

- (void)pause
{
    if (self.state == SGPlayerStateFailed) return;
    self.state = SGPlayerStateSuspend;
    [self cancelPlayIfNeed];
    [self.avPlayer pause];
}

- (void)seekToTime:(NSTimeInterval)time
{
    [self seekToTime:time completeHandler:nil];
}

- (void)seekToTime:(NSTimeInterval)time completeHandler:(void (^)(BOOL))completeHandler
{
    if (self.avPlayerItem.status != AVPlayerItemStatusReadyToPlay) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setPlayIfNeed];
        self.seeking = YES;
        SGWeakSelf
        [self.avPlayerItem seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.seeking = NO;
                [weakSelf playIfNeed];
                if (completeHandler) {
                    completeHandler(finished);
                }
                SGPlayerLog(@"SGAVPlayer seek success");
            });
        }];
    });
}

- (void)stop
{
    [self replaceEmpty];
}

- (NSTimeInterval)progress
{
    return CMTimeGetSeconds(self.avPlayerItem.currentTime);
}

- (NSTimeInterval)duration
{
    return CMTimeGetSeconds(self.avPlayerItem.duration);
}

#pragma mark - Setter/Getter

- (void)setState:(SGPlayerState)state
{
    if (_state != state) {
        SGPlayerState temp = _state;
        _state = state;
        if (_state != SGPlayerStateFailed) {
            self.abstractPlayer.error = nil;
        }
        [SGNotification postPlayer:self.abstractPlayer statePrevious:temp current:_state];
    }
}

- (void)reloadVolume
{
    self.avPlayer.volume = self.abstractPlayer.volume;
}

- (void)reloadPlayableTime
{
    if (self.avPlayerItem.status == AVPlayerItemStatusReadyToPlay) {
        CMTimeRange range = [self.avPlayerItem.loadedTimeRanges.firstObject CMTimeRangeValue];
        NSTimeInterval start = CMTimeGetSeconds(range.start);
        NSTimeInterval duration = CMTimeGetSeconds(range.duration);
        self.playableTime = (start + duration);
    } else {
        self.playableTime = 0;
    }
}

- (void)setPlayableTime:(NSTimeInterval)playableTime
{
    if (_playableTime != playableTime) {
        _playableTime = playableTime;
        CGFloat duration = self.duration;
        [SGNotification postPlayer:self.abstractPlayer playablePercent:@(playableTime/duration) current:@(playableTime) total:@(duration)];
    }
}

- (CGSize)presentationSize
{
    if (self.avPlayerItem) {
        return self.avPlayerItem.presentationSize;
    }
    return CGSizeZero;
}

- (UIImage *)snapshotAtCurrentTime
{
    switch (self.abstractPlayer.videoType) {
        case SGVideoTypeNormal:
        {
            AVAssetImageGenerator * imageGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:self.avAsset];
            imageGenerator.appliesPreferredTrackTransform = YES;
            imageGenerator.requestedTimeToleranceBefore = kCMTimeZero;
            imageGenerator.requestedTimeToleranceAfter = kCMTimeZero;
            
            NSError * error = nil;
            CMTime time = self.avPlayerItem.currentTime;
            CMTime actualTime;
            CGImageRef cgImage = [imageGenerator copyCGImageAtTime:time actualTime:&actualTime error:&error];
            UIImage * image = [UIImage imageWithCGImage:cgImage];
            return image;
        }
            break;
        case SGVideoTypeVR:
        {
            return nil;
        }
            break;
    }
}

- (CVPixelBufferRef)pixelBufferAtCurrentTime
{
    if (self.seeking) return nil;
    
    BOOL hasNewPixelBuffer = [self.avOutput hasNewPixelBufferForItemTime:self.avPlayerItem.currentTime];
    if (!hasNewPixelBuffer) {
        if (self.hasPixelBuffer) return nil;
        [self trySetupOutput];
        return nil;
    }
    
    CVPixelBufferRef pixelBuffer = [self.avOutput copyPixelBufferForItemTime:self.avPlayerItem.currentTime itemTimeForDisplay:nil];
    if (!pixelBuffer) {
        [self trySetupOutput];
    } else {
        self.hasPixelBuffer = YES;
    }
    return pixelBuffer;
}

#pragma mark - play state change

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object == self.avPlayerItem) {
            if ([keyPath isEqualToString:@"status"])
            {
                switch (self.avPlayerItem.status) {
                    case AVPlayerItemStatusUnknown:
                    {
                        self.state = SGPlayerStateBuffering;
                        SGPlayerLog(@"SGAVPlayer item status unknown");
                    }
                        break;
                    case AVPlayerItemStatusReadyToPlay:
                    {
                        SGPlayerLog(@"SGAVPlayer item status ready to play");
                        self.readyToPlayTime = [NSDate date].timeIntervalSince1970;
                        switch (self.state) {
                            case SGPlayerStateBuffering:
                                self.state = SGPlayerStatePlaying;
                            case SGPlayerStatePlaying:
                                [self playIfNeed];
                                break;
                            case SGPlayerStateSuspend:
                            case SGPlayerStateFinished:
                            case SGPlayerStateFailed:
                                break;
                            default:
                                self.state = SGPlayerStateReadyToPlay;
                                break;
                        }
                    }
                        break;
                    case AVPlayerItemStatusFailed:
                    {
                        SGPlayerLog(@"SGAVPlayer item status failed");
                        self.readyToPlayTime = 0;
                        SGError * error = [[SGError alloc] init];
                        if (self.avPlayerItem.error) {
                            error.error = self.avPlayerItem.error;
                            if (self.avPlayerItem.errorLog.extendedLogData.length > 0) {
                                error.extendedLogData = self.avPlayerItem.errorLog.extendedLogData;
                                error.extendedLogDataStringEncoding = self.avPlayerItem.errorLog.extendedLogDataStringEncoding;
                            }
                            if (self.avPlayerItem.errorLog.events.count > 0) {
                                NSMutableArray <SGErrorEvent *> * array = [NSMutableArray arrayWithCapacity:self.avPlayerItem.errorLog.events.count];
                                for (AVPlayerItemErrorLogEvent * obj in self.avPlayerItem.errorLog.events) {
                                    SGErrorEvent * event = [[SGErrorEvent alloc] init];
                                    event.date = obj.date;
                                    event.URI = obj.URI;
                                    event.serverAddress = obj.serverAddress;
                                    event.playbackSessionID = obj.playbackSessionID;
                                    event.errorStatusCode = obj.errorStatusCode;
                                    event.errorDomain = obj.errorDomain;
                                    event.errorComment = obj.errorComment;
                                    [array addObject:event];
                                }
                                error.errorEvents = array;
                            }
                        } else if (self.avPlayer.error) {
                            error.error = self.avPlayer.error;
                        } else {
                            error.error = [NSError errorWithDomain:@"AVPlayer playback error" code:-1 userInfo:nil];
                        }
                        self.abstractPlayer.error = error;
                        self.state = SGPlayerStateFailed;
                        [SGNotification postPlayer:self.abstractPlayer error:error];
                    }
                        break;
                }
            }
            else if ([keyPath isEqualToString:@"playbackBufferEmpty"])
            {
                if (self.avPlayerItem.playbackBufferEmpty) {
                    [self setPlayIfNeed];
                }
            }
            else if ([keyPath isEqualToString:@"loadedTimeRanges"])
            {
                [self reloadPlayableTime];
                if ((self.playableTime - self.progress) > self.abstractPlayer.playableBufferInterval) {
                    [self playIfNeed];
                }
            }
        }
    });
}

- (void)avplayerItemDidPlayToEnd:(NSNotification *)notification
{
    self.state = SGPlayerStateFinished;
}

- (void)avAssetPrepareFailed:(NSError *)error
{
    SGPlayerLog(@"%s", __func__);
}

#pragma mark - replace video

- (void)tryReplaceVideo
{
    if (!self.avPlayerItem) {
        [self replaceVideo];
    }
}

- (void)replaceVideo
{
    [self replaceEmpty];
    if (!self.abstractPlayer.contentURL) return;
    
    self.avAsset = [AVAsset assetWithURL:self.abstractPlayer.contentURL];
    switch (self.abstractPlayer.videoType) {
        case SGVideoTypeNormal:
            [self setupAVPlayerItemAutoLoadedAsset:YES];
            self.abstractPlayer.displayView.rendererType = SGDisplayRendererTypeAVPlayerLayer;
            break;
        case SGVideoTypeVR:
        {
            [self setupAVPlayerItemAutoLoadedAsset:NO];
            self.abstractPlayer.displayView.rendererType = SGDisplayRendererTypeAVPlayerPixelBufferVR;
            SGWeakSelf
            [self.avAsset loadValuesAsynchronouslyForKeys:[self.class AVAssetloadKeys] completionHandler:^{
                SGStrongSelf
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (NSString * loadKey in [strongSelf.class AVAssetloadKeys]) {
                        NSError * error = nil;
                        AVKeyValueStatus keyStatus = [strongSelf.avAsset statusOfValueForKey:loadKey error:&error];
                        if (keyStatus == AVKeyValueStatusFailed) {
                            [strongSelf avAssetPrepareFailed:error];
                            SGPlayerLog(@"AVAsset load failed");
                            return;
                        }
                    }
                    NSError * error = nil;
                    AVKeyValueStatus trackStatus = [strongSelf.avAsset statusOfValueForKey:@"tracks" error:&error];
                    if (trackStatus == AVKeyValueStatusLoaded) {
                        [strongSelf setupOutput];
                    } else {
                        SGPlayerLog(@"AVAsset load failed");
                    }
                });
            }];
        }
            break;
    }
}

#pragma mark - setup/clean

- (void)setupAVPlayer
{
    self.avPlayer = [[AVPlayer alloc] init];
    if ([UIDevice currentDevice].systemVersion.floatValue >= 10.0) {
        self.avPlayer.automaticallyWaitsToMinimizeStalling = NO;
    }
    SGWeakSelf
    self.playBackTimeObserver = [self.avPlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        SGStrongSelf
        if (strongSelf.state == SGPlayerStatePlaying) {
            CGFloat current = CMTimeGetSeconds(time);
            CGFloat duration = strongSelf.duration;
            [SGNotification postPlayer:strongSelf.abstractPlayer progressPercent:@(current/duration) current:@(current) total:@(duration)];
        }
    }];
    self.abstractPlayer.displayView.sgavplayer = self;
    [self reloadVolume];
}

- (void)replaceEmptyAVPlayer
{
    [self.avPlayer replaceCurrentItemWithPlayerItem:nil];
}

- (void)cleanAVPlayer
{
    if (self.playBackTimeObserver) {
        [self.avPlayer removeTimeObserver:self.playBackTimeObserver];
        self.playBackTimeObserver = nil;
    }
    self.avPlayer = nil;
}

- (void)setupAVPlayerItemAutoLoadedAsset:(BOOL)autoLoadedAsset
{
    [self cleanAVPlayerItem];
    
    if (autoLoadedAsset) {
        self.avPlayerItem = [AVPlayerItem playerItemWithAsset:self.avAsset automaticallyLoadedAssetKeys:[self.class AVAssetloadKeys]];
    } else {
        self.avPlayerItem = [AVPlayerItem playerItemWithAsset:self.avAsset];
    }
    
    [self.avPlayerItem addObserver:self forKeyPath:@"status" options:0 context:NULL];
    [self.avPlayerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew context:NULL];
    [self.avPlayerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:NULL];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(avplayerItemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:_avPlayerItem];
    
    [self.avPlayer replaceCurrentItemWithPlayerItem:self.avPlayerItem];
}

- (void)cleanAVPlayerItem
{
    if (self.avPlayerItem) {
        [self.avPlayerItem removeObserver:self forKeyPath:@"status"];
        [self.avPlayerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
        [self.avPlayerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
        [self.avPlayerItem removeOutput:self.avOutput];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.avPlayerItem];
    }
    self.avPlayerItem = nil;
}

- (void)trySetupOutput
{
    BOOL isReadyToPlay = self.avPlayerItem.status == AVPlayerStatusReadyToPlay && self.readyToPlayTime > 10 && (([NSDate date].timeIntervalSince1970 - self.readyToPlayTime) > 0.3);
    if (isReadyToPlay) {
        [self setupOutput];
    }
}

- (void)setupOutput
{
    [self cleanOutput];
    
    NSDictionary * pixelBuffer = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.avOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelBuffer];
    [self.avOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:PixelBufferRequestInterval];
    [self.avPlayerItem addOutput:self.avOutput];
    
    SGPlayerLog(@"SGAVPlayer add output success");
}

- (void)cleanOutput
{
    if (self.avPlayerItem) {
        [self.avPlayerItem removeOutput:self.avOutput];
    }
    self.avOutput = nil;
    self.hasPixelBuffer = NO;
}

- (void)replaceEmpty
{
    [SGNotification postPlayer:self.abstractPlayer playablePercent:@(0) current:@(0) total:@(0)];
    [SGNotification postPlayer:self.abstractPlayer progressPercent:@(0) current:@(0) total:@(0)];
    [self cleanOutput];
    [self replaceEmptyAVPlayer];
    [self cleanAVPlayerItem];
    self.avAsset = nil;
    self.state = SGPlayerStateNone;
    self.needPlay = NO;
    self.seeking = NO;
    self.playableTime = 0;
    self.readyToPlayTime = 0;
    [self.abstractPlayer.displayView cleanEmptyBuffer];
}

+ (NSArray <NSString *> *)AVAssetloadKeys
{
    static NSArray * keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys =@[@"tracks", @"playable"];
    });
    return keys;
}

- (void)dealloc
{
    SGPlayerLog(@"SGAVPlayer release");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self replaceEmpty];
    [self cleanAVPlayer];
}

@end
