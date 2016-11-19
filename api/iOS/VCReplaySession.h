//
//  VCReplaySession.h
//  SampleBroadcaster
//
//  Created by Sopl’Wang on 2016/11/3.
//  Copyright © 2016年 videocore. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <videocore/api/iOS/VCSimpleSession.h>


typedef NS_ENUM(NSInteger, VCRotateMode)
{
    VCRotateMode0Degrees = 0,
    VCRotateMode90Degrees = 1,
    VCRotateMode180Degrees = 2,
    VCRotateMode270Degrees = 3,
};


// VCReplaySessionDelegate ----------------------------------------------------

@protocol VCReplaySessionDelegate <NSObject>

@required
- (void) connectionStatusChanged: (VCSessionState) sessionState;

@optional
- (void) detectedThroughput: (NSInteger) throughputInBytesPerSecond; //Depreciated, should use method below
- (void) detectedThroughput: (NSInteger) throughputInBytesPerSecond videoRate:(NSInteger) rate;

@end


// VCReplaySession ------------------------------------------------------------

@interface VCReplaySession : NSObject

@property (nonatomic, assign) id<VCReplaySessionDelegate> delegate;

- (instancetype) initWithVideoSize:(CGSize)videoSize
                         frameRate:(int)fps
                           bitrate:(int)bps;

- (void) startRtmpSessionWithURL:(NSString*) rtmpUrl
                    andStreamKey:(NSString*) streamKey;

- (void) endRtmpSession;

- (void) pushVideoSample:(CMSampleBufferRef) sampleBuffer
                rotation:(VCRotateMode) r;

- (void) pushAudioSample:(CMSampleBufferRef) sampleBuffer
                     Mic:(bool) isMic;

@end
