//
//  SampleHandler.m
//  SampleBroadcastUpload
//
//  Created by Sopl’Wang on 2016/10/10.
//  Copyright © 2016年 videocore. All rights reserved.
//


#import "SampleHandler.h"

#import <videocore/api/iOS/VCReplaySession.h>


//  To handle samples with a subclass of RPBroadcastSampleHandler set the following in the extension's Info.plist file:
//  - RPBroadcastProcessMode should be set to RPBroadcastProcessModeSampleBuffer
//  - NSExtensionPrincipalClass should be set to this class

@implementation SampleHandler

+ (id) sharedSession
{
    static VCReplaySession *sharedSession = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedSession = [[VCReplaySession alloc] initWithVideoSize:CGSizeMake(368, 640) frameRate:20 bitrate:650000];
    });
    return sharedSession;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *,NSObject *> *)setupInfo {
    // User has requested to start the broadcast. Setup info from the UI extension will be supplied.
    NSLog(@"broadcastStartedWithSetupInfo");

    NSLog(@"Starting RTMP session");
    [[SampleHandler sharedSession] startRtmpSessionWithURL:@"rtmp://192.168.1.1" andStreamKey:@"test"];
}

- (void)broadcastPaused {
    // User has requested to pause the broadcast. Samples will stop being delivered.
    NSLog(@"broadcastPaused");
}

- (void)broadcastResumed {
    // User has requested to resume the broadcast. Samples delivery will resume.
    NSLog(@"broadcastResumed");
}

- (void)broadcastFinished {
    // User has requested to finish the broadcast.
    NSLog(@"broadcastFinished");

    NSLog(@"Ending RTMP session");
    [[SampleHandler sharedSession] endRtmpSession];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {

    NSLog(@"processSampleBuffer:withType: %ld", (long)sampleBufferType);

    switch (sampleBufferType) {
        case RPSampleBufferTypeVideo:
            [[SampleHandler sharedSession] pushVideoSample:sampleBuffer];
            break;
        case RPSampleBufferTypeAudioApp:
            [[SampleHandler sharedSession] pushAudioSample:sampleBuffer Mic:NO];
            break;
        case RPSampleBufferTypeAudioMic:
            [[SampleHandler sharedSession] pushAudioSample:sampleBuffer Mic:YES];
            break;
        default:
            break;
    }
}

@end
