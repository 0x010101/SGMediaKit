//
//  SGVideoCapture.m
//  SGMediaKit
//
//  Created by Single on 23/11/2016.
//  Copyright © 2016 single. All rights reserved.
//

#import "SGVideoCapture.h"
#import <GPUImage/GPUImageFramework.h>
#import "SGVideoCapturePreview.h"

@interface SGVideoCapture ()

@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL recording;
@property (nonatomic, strong) GPUImageVideoCamera * videoCamera;
@property (nonatomic, strong) GPUImageFilter * filter;
@property (nonatomic, strong) GPUImageMovieWriter * writer;
@property (nonatomic, copy) NSURL * fileURL;
@property (nonatomic, strong) SGVideoCapturePreview * preview;

@end

@implementation SGVideoCapture

- (void)reloadFilter
{
    [self.filter removeTarget:self.preview.gpuImageView];
    self.filter = [[GPUImageFilter alloc] init];
    [self.filter addTarget:self.preview.gpuImageView];
    [self tryAddWriterToFilter];
    [self.videoCamera addTarget:self.filter];
}

- (void)startRunning
{
    if (!self.running) {
        [self reloadFilter];
        if ([self.delegate respondsToSelector:@selector(videoCaptureWillStartRunning:)]) {
            [self.delegate videoCaptureWillStartRunning:self];
        }
        self.running = YES;
        [self.videoCamera startCameraCapture];
        if ([self.delegate respondsToSelector:@selector(videoCaptureDidStartRunning:)]) {
            [self.delegate videoCaptureDidStartRunning:self];
        }
    }
}

- (void)stopRunning
{
    if (self.running) {
        if ([self.delegate respondsToSelector:@selector(videoCaptureWillStopRunning:)]) {
            [self.delegate videoCaptureWillStopRunning:self];
        }
        self.running = NO;
        [self.videoCamera stopCameraCapture];
        if ([self.delegate respondsToSelector:@selector(videoCaptureDidStopRunning:)]) {
            [self.delegate videoCaptureDidStopRunning:self];
        }
    }
}

- (BOOL)startRecordingWithFileURL:(NSURL *)fileURL error:(NSError *__autoreleasing *)error
{
    if (self.recording) {
        NSError * err = [NSError errorWithDomain:@"已经在在录制" code:SGVideoCaptureErrorCodeRecording userInfo:nil];
        * error = err;
        return NO;
    }
    if (!fileURL.isFileURL) {
        NSError * err = [NSError errorWithDomain:@"fileURL 不是可用的文件URL" code:SGVideoCaptureErrorCodeRecording userInfo:nil];
        * error = err;
        return NO;
    }
    
    self.fileURL = fileURL;
    [self setupWriter];
    self.recording = YES;
    [self.writer startRecording];
    return YES;
}

- (void)finishRecordingWithCompletionHandler:(void (^)(NSURL *, NSError *))completionHandler
{
    if (self.recording) {
        self.recording = NO;
        __weak typeof(self) weakSelf = self;
        [self.writer finishRecordingWithCompletionHandler:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (completionHandler) {
                completionHandler(strongSelf.fileURL, nil);
            }
            strongSelf.fileURL = nil;
            [self cleanWriter];
        }];
    } else {
        if (completionHandler) {
            NSError * error = [NSError errorWithDomain:@"没有开始录制" code:SGVideoCaptureErrorCodeRecording userInfo:nil];
            completionHandler(nil, error);
        }
    }
}

- (void)setupWriter
{
    self.writer = [[GPUImageMovieWriter alloc] initWithMovieURL:self.fileURL size:CGSizeMake(100, 100)];
    self.writer.encodingLiveVideo = YES;
    self.writer.shouldPassthroughAudio = YES;
    self.videoCamera.audioEncodingTarget = self.writer;
    [self tryAddWriterToFilter];
}

- (void)cleanWriter
{
    if (self.writer) {
        if ([self.filter.targets containsObject:self.writer]) {
            [self.filter removeTarget:self.writer];
        }
        self.writer = nil;
    }
}

- (void)tryAddWriterToFilter
{
    if (self.writer) {
        if (![self.filter.targets containsObject:self.writer]) {
            [self.filter addTarget:self.writer];
        }
    }
}

- (GPUImageVideoCamera *)videoCamera
{
    if(!_videoCamera) {
        _videoCamera = [[GPUImageVideoCamera alloc] initWithSessionPreset:AVCaptureSessionPreset640x480 cameraPosition:AVCaptureDevicePositionFront];
        _videoCamera.outputImageOrientation = UIInterfaceOrientationPortrait;
        _videoCamera.horizontallyMirrorFrontFacingCamera = NO;
        NSString * filePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"SGVideoCaptureTemp.mp4"];
        NSURL * url = [NSURL fileURLWithPath:filePath];
        _videoCamera.audioEncodingTarget = [[GPUImageMovieWriter alloc] initWithMovieURL:url size:CGSizeMake(1, 1)];
    }
    return _videoCamera;
}

- (UIView *)view
{
    return self.preview;
}

- (SGVideoCapturePreview *)preview
{
    if (!_preview) {
        _preview = [[SGVideoCapturePreview alloc] initWithFrame:CGRectZero];
    }
    return _preview;
}

@end