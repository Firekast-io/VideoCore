//
//  VCReplaySession.m
//  SampleBroadcaster
//
//  Created by Sopl’Wang on 2016/11/3.
//  Copyright © 2016年 videocore. All rights reserved.
//

#import "videocore/api/iOS/VCReplaySession.h"

#import <CoreAudio/CoreAudioTypes.h>

#include "videocore/rtmp/RTMPSession.h"
#include "videocore/sources/ISource.hpp"
#include "videocore/system/pixelBuffer/IPixelBuffer.hpp"
#include "videocore/system/pixelBuffer/Apple/PixelBuffer.h"
#include "videocore/transforms/RTMP/AACPacketizer.h"
#include "videocore/transforms/RTMP/H264Packetizer.h"

#ifdef __APPLE__
#   include "videocore/mixers/Apple/AudioMixer.h"
#   include "videocore/mixers/Apple/VideoMixer.h"
#   ifdef TARGET_OS_IPHONE
#       include "videocore/mixers/iOS/CIVideoMixer.h"
#       include "videocore/sources/iOS/CameraSource.h"
#       include "videocore/sources/iOS/MicSource.h"
#       include "videocore/transforms/iOS/AACEncode.h"
#       include "videocore/transforms/iOS/H264Encode.h"

#   else /* OS X */

#   endif
#else
#   include <videocore/mixers/GenericAudioMixer.h>
#endif

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)


#include <sstream>

static const int kMinVideoBitrate = 150000;


@interface VCReplaySession ()
{
    std::shared_ptr<videocore::iOS::CameraSource> m_replaySource;
    std::shared_ptr<videocore::iOS::MicSource>    m_appAudioSource;
    std::shared_ptr<videocore::iOS::MicSource>    m_micSource;

    std::shared_ptr<videocore::IVideoMixer> m_videoMixer;
    std::shared_ptr<videocore::IAudioMixer> m_audioMixer;

    std::shared_ptr<videocore::ITransform> m_h264Encoder;
    std::shared_ptr<videocore::ITransform> m_aacEncoder;
    std::shared_ptr<videocore::ITransform> m_h264Packetizer;
    std::shared_ptr<videocore::ITransform> m_aacPacketizer;

    std::shared_ptr<videocore::IOutputSession> m_outputSession;
    
    // properties
    dispatch_queue_t _graphManagementQueue;
    
    CGSize _videoSize;
    int    _bitrate;
    
    int    _fps;
    int    _bpsCeiling;
    int    _estimatedThroughput;
    
    BOOL   _useInterfaceOrientation;
    float  _videoZoomFactor;
    int    _audioChannelCount;
    float  _audioSampleRate;
    float  _micGain;
    
    VCCameraState _cameraState;
    VCAspectMode _aspectMode;
    VCSessionState _rtmpSessionState;

    BOOL  _orientationLocked;
    BOOL  _useAdaptiveBitrate;
}

- (void) setupGraph;

@end

@implementation VCReplaySession

// -----------------------------------------------------------------------------
//  Properties Methods
// -----------------------------------------------------------------------------
#pragma mark - Properties

- (CGSize) videoSize {
    return _videoSize;
}

- (void) setVideoSize:(CGSize)videoSize {
    _videoSize = videoSize;
}

- (int) bitrate {
    return _bitrate;
}

- (void) setBitrate:(int)bitrate {
    _bitrate = bitrate;
}

- (int) fps {
    return _fps;
}

- (void) setFps:(int)fps {
    _fps = fps;
}

- (BOOL) useInterfaceOrientation {
    return _useInterfaceOrientation;
}

- (void) setUseInterfaceOrientation:(BOOL)useInterfaceOrientation {
    _useInterfaceOrientation = useInterfaceOrientation;
}

- (BOOL) orientationLocked {
    return _orientationLocked;
}

- (void) setOrientationLocked:(BOOL)orientationLocked {
    _orientationLocked = orientationLocked;
}

- (void) setRtmpSessionState:(VCSessionState)rtmpSessionState {
    _rtmpSessionState = rtmpSessionState;
    if (self.delegate) {
        [self.delegate connectionStatusChanged:rtmpSessionState];
    }
}

- (VCSessionState) rtmpSessionState {
    return _rtmpSessionState;
}

- (float) videoZoomFactor {
    return _videoZoomFactor;
}

- (void) setVideoZoomFactor:(float)videoZoomFactor {
    _videoZoomFactor = videoZoomFactor;
}

- (void) setAudioChannelCount:(int)channelCount {
    _audioChannelCount = MIN(2, MIN(channelCount,2)); // We can only support a channel count of 2 with AAC
    
    if (m_audioMixer) {
        m_audioMixer->setChannelCount(channelCount);
    }
}

- (int) audioChannelCount {
    return _audioChannelCount;
}

- (void) setAudioSampleRate:(float)sampleRate {
    _audioSampleRate = (sampleRate > 33075 ? 44100 : 22050); // We can only support 44100 / 22050 with AAC + RTMP

    if (m_audioMixer) {
        m_audioMixer->setFrequencyInHz(sampleRate);
    }
}

- (float) audioSampleRate {
    return _audioSampleRate;
}

- (void) setMicGain:(float)micGain {
    if (m_audioMixer) {
        m_audioMixer->setSourceGain(m_appAudioSource, micGain);
        m_audioMixer->setSourceGain(m_micSource, micGain);
        _micGain = micGain;
    }
}

- (float) micGain {
    return _micGain;
}

- (BOOL) useAdaptiveBitrate {
    return _useAdaptiveBitrate;
}

- (void) setUseAdaptiveBitrate:(BOOL)useAdaptiveBitrate {
    _useAdaptiveBitrate = useAdaptiveBitrate;
    _bpsCeiling = _bitrate;
}

- (int) estimatedThroughput {
    return _estimatedThroughput;
}


// -----------------------------------------------------------------------------
//  Public Methods
// -----------------------------------------------------------------------------
#pragma mark - Public Methods

- (instancetype) initWithVideoSize:(CGSize)videoSize
                         frameRate:(int)fps
                           bitrate:(int)bps
{
    if ((self = [super init])) {
        [self initInternalWithVideoSize:videoSize
                              frameRate:fps
                                bitrate:bps
                useInterfaceOrientation:NO
                             aspectMode:VCAspectModeFit];
    }
    return self;
}

- (void) initInternalWithVideoSize:(CGSize)videoSize
                         frameRate:(int)fps
                           bitrate:(int)bps
           useInterfaceOrientation:(BOOL)useInterfaceOrientation
                        aspectMode:(VCAspectMode)aspectMode
{
    self.bitrate = bps;
    self.videoSize = videoSize;
    self.fps = fps;
    self.useInterfaceOrientation = useInterfaceOrientation;
    self.micGain = 1.f;
    self.audioChannelCount = 1;
    self.audioSampleRate = 44100.;
    self.useAdaptiveBitrate = YES;

    _graphManagementQueue = dispatch_queue_create("com.videocore.replay.graph", 0);
    
    __block VCReplaySession* bSelf = self;

    dispatch_async(_graphManagementQueue, ^{
        [bSelf setupGraph];
    });
}

- (void) dealloc
{
    [self endRtmpSessionInternal];
    m_videoMixer.reset();
    m_audioMixer.reset();
    m_replaySource.reset();
    m_micSource.reset();
    m_appAudioSource.reset();

    dispatch_release(_graphManagementQueue);
    
    [super dealloc];
}

- (void) startRtmpSessionWithURL:(NSString *)rtmpUrl
                    andStreamKey:(NSString *)streamKey
{
    __block VCReplaySession* bSelf = self;

    dispatch_async(_graphManagementQueue, ^{
        [bSelf startSessionInternal:rtmpUrl streamKey:streamKey];
    });
}

- (void) startSessionInternal: (NSString*) rtmpUrl
                    streamKey: (NSString*) streamKey
{
    std::stringstream uri ;
    uri << (rtmpUrl ? [rtmpUrl UTF8String] : "") << "/" << (streamKey ? [streamKey UTF8String] : "");
    
    m_outputSession.reset(new videocore::RTMPSession(uri.str(),
                                                     [=](videocore::RTMPSession& session, ClientState_t state) {
                                                         
                                                         DLog("ClientState: %d\n", state);
                                                         
                                                         switch(state) {
                                                             case kClientStateConnected:
                                                                 self.rtmpSessionState = VCSessionStateStarting;
                                                                 break;
                                                                 
                                                             case kClientStateSessionStarted: {
                                                                 __block VCReplaySession* bSelf = self;

                                                                 dispatch_async(_graphManagementQueue, ^{
                                                                     [bSelf addEncodersAndPacketizers];
                                                                 });
                                                                 self.rtmpSessionState = VCSessionStateStarted;
                                                                 break;
                                                             }

                                                             case kClientStateError:
                                                                 self.rtmpSessionState = VCSessionStateError;
                                                                 [self endRtmpSessionInternal];
                                                                 break;
                                                                 
                                                             case kClientStateNotConnected:
                                                                 self.rtmpSessionState = VCSessionStateEnded;
                                                                 [self endRtmpSessionInternal];
                                                                 break;
                                                                 
                                                             default:
                                                                 break;
                                                         }
                                                         
                                                     }) );
    
    VCReplaySession* bSelf = self;

    _bpsCeiling = _bitrate;
    
    if ( self.useAdaptiveBitrate ) {
        _bitrate = 500000;
    }
    
    m_outputSession->setBandwidthCallback([=](float vector, float predicted, int inst)
                                          {
                                              auto video = std::dynamic_pointer_cast<videocore::IEncoder>(bSelf->m_h264Encoder);
                                              auto audio = std::dynamic_pointer_cast<videocore::IEncoder>(bSelf->m_aacEncoder);

                                              bSelf->_estimatedThroughput = predicted;

                                              if (video && audio && bSelf.useAdaptiveBitrate) {
                                                  
                                                  if ([bSelf.delegate respondsToSelector:@selector(detectedThroughput:)]) {
                                                      [bSelf.delegate detectedThroughput:predicted];
                                                  }
                                                  if ([bSelf.delegate respondsToSelector:@selector(detectedThroughput:videoRate:)]) {
                                                      [bSelf.delegate detectedThroughput:predicted videoRate:video->bitrate()];
                                                  }
                                                  
                                                  int videoBr = 0;
                                                  
                                                  if (vector != 0) {
                                                      vector = vector < 0 ? -1 : 1 ;
                                                      videoBr = video->bitrate();
                                                      
                                                      if (audio) {
                                                          if ( videoBr > 500000 ) {
                                                              audio->setBitrate(128000);
                                                          } else if (videoBr <= 500000 && videoBr > 250000) {
                                                              audio->setBitrate(96000);
                                                          } else {
                                                              audio->setBitrate(80000);
                                                          }
                                                      }
                                                      
                                                      if(videoBr > 1152000) {
                                                          video->setBitrate(std::min(int((videoBr / 384000 + vector )) * 384000, bSelf->_bpsCeiling) );
                                                      }
                                                      else if( videoBr > 512000 ) {
                                                          video->setBitrate(std::min(int((videoBr / 128000 + vector )) * 128000, bSelf->_bpsCeiling) );
                                                      }
                                                      else if( videoBr > 128000 ) {
                                                          video->setBitrate(std::min(int((videoBr / 64000 + vector )) * 64000, bSelf->_bpsCeiling) );
                                                      }
                                                      else {
                                                          video->setBitrate(std::max(std::min(int((videoBr / 32000 + vector )) * 32000, bSelf->_bpsCeiling), kMinVideoBitrate) );
                                                      }
                                                      DLog("\n(%f) AudioBR: %d VideoBR: %d (%f)\n", vector, audio->bitrate(), video->bitrate(), predicted);
                                                  } /* if(vector != 0) */
                                                  
                                              } /* if(video && audio && m_adaptiveBREnabled) */
                                              
                                          });
    
    videocore::RTMPSessionParameters_t sp(0.);

    sp.setData(self.videoSize.width,
               self.videoSize.height,
               1. / static_cast<double>(self.fps),
               self.bitrate,
               self.audioSampleRate,
               (self.audioChannelCount == 2));
    
    m_outputSession->setSessionParameters(sp);
}

- (void) endRtmpSession
{
    __block VCReplaySession* bSelf = self;
    
    dispatch_sync(_graphManagementQueue, ^{
        [bSelf endRtmpSessionInternal];
    });
}

- (void) endRtmpSessionInternal
{
    m_videoMixer->setOutput(nullptr);
    m_audioMixer->setOutput(nullptr);

    m_h264Encoder.reset();
    m_aacEncoder.reset();
    m_h264Packetizer.reset();
    m_aacPacketizer.reset();
    
    m_outputSession.reset();
    
    if ( self.useAdaptiveBitrate ) {
        _bitrate = _bpsCeiling;
    }
    self.rtmpSessionState = VCSessionStateEnded;
}

// -----------------------------------------------------------------------------
//  Private Methods
// -----------------------------------------------------------------------------
#pragma mark - Private Methods


- (void) setupGraph
{
    const double frameDuration = 1. / static_cast<double>(self.fps);
    
    {
        // Add audio mixer
        const double aacPacketTime = 1024. / self.audioSampleRate;
        
        m_audioMixer = std::make_shared<videocore::Apple::AudioMixer>(self.audioChannelCount,
                                                                      self.audioSampleRate,
                                                                      16,
                                                                      aacPacketTime);
        
        // The H.264 Encoder introduces about 2 frames of latency, so we will set the minimum audio buffer duration to 2 frames.
        // ReplayKit makes about 0.5s latency to post data for us.
        m_audioMixer->setMinimumBufferDuration(frameDuration*2 + .5);
    }
#ifdef __APPLE__
#ifdef TARGET_OS_IPHONE
    
    {
        // Add video mixer
        m_videoMixer = std::make_shared<videocore::iOS::CIVideoMixer>(self.videoSize.width,
                                                                      self.videoSize.height,
                                                                      frameDuration);
    }
    
#else
#endif // TARGET_OS_IPHONE
#endif // __APPLE__
    // Create sources
    {
        // Add replay source
        m_replaySource = std::make_shared<videocore::iOS::CameraSource>();
        m_replaySource->setOrientationLocked(self.orientationLocked);
        m_replaySource->setOutput(m_videoMixer);
    }
    
    {
        // Add app audio source
        m_appAudioSource = std::make_shared<videocore::iOS::MicSource>(self.audioSampleRate, self.audioChannelCount);
        m_appAudioSource->setOutput(m_audioMixer);
    }

    {
        // Add mic source
        m_micSource = std::make_shared<videocore::iOS::MicSource>(self.audioSampleRate, self.audioChannelCount);
        m_micSource->setOutput(m_audioMixer);
    }

    {
        // Start mixers
        const auto epoch = std::chrono::steady_clock::now();
        
        m_audioMixer->setEpoch(epoch);
        m_videoMixer->setEpoch(epoch);
        
        m_audioMixer->start();
        m_videoMixer->start();
    }
}

- (void) addEncodersAndPacketizers
{
    int ctsOffset = 2000 / self.fps; // 2 * frame duration

    {
        // Add encoders
        m_aacEncoder = std::make_shared<videocore::iOS::AACEncode>(self.audioSampleRate, self.audioChannelCount, 96000);
        m_h264Encoder =std::make_shared<videocore::iOS::H264Encode>(self.videoSize.width,
                                                                    self.videoSize.height,
                                                                    self.fps,
                                                                    self.bitrate);
        m_audioMixer->setOutput(m_aacEncoder);
        m_videoMixer->setOutput(m_h264Encoder);
    }
    {
        m_h264Packetizer = std::make_shared<videocore::rtmp::H264Packetizer>(ctsOffset);
        m_aacPacketizer = std::make_shared<videocore::rtmp::AACPacketizer>(self.audioSampleRate, self.audioChannelCount, ctsOffset);
        
        m_h264Encoder->setOutput(m_h264Packetizer);
        m_aacEncoder->setOutput(m_aacPacketizer);
    }

    m_h264Packetizer->setOutput(m_outputSession);
    m_aacPacketizer->setOutput(m_outputSession);
}

- (void) pushVideoSample:(CMSampleBufferRef) sampleBuffer
             orientation:(VCReplayOrientation) orient
{
    if (self.rtmpSessionState != VCSessionStateStarted) return;

    if (m_replaySource && sampleBuffer && CMSampleBufferDataIsReady(sampleBuffer)) {
        m_replaySource->bufferCaptured(CMSampleBufferGetImageBuffer(sampleBuffer), orient);
    }
}

- (void) pushAudioSample:(CMSampleBufferRef) sampleBuffer
                     Mic:(bool) isMic
{
    if (self.rtmpSessionState != VCSessionStateStarted) return;

    if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer;
    
    OSStatus rc = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                                                                          NULL,
                                                                          &audioBufferList,
                                                                          sizeof(audioBufferList),
                                                                          NULL,
                                                                          NULL,
                                                                          0,
                                                                          &blockBuffer
                                                                          );
    if (rc != noErr) {
        NSLog(@"CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer: error (%d)", rc);
        return;
    }
    
    videocore::AudioBufferMetadata md (0.);
    
    for (int i = 0; i < audioBufferList.mNumberBuffers; i++) {
        AudioBuffer audioBuffer = audioBufferList.mBuffers[i];
        uint8_t *data = (uint8_t*)audioBuffer.mData;
        size_t size = audioBuffer.mDataByteSize;
        int numFrames = size / 2;
        
#if VC_DEBUG_DUMP_AUDIO
        if (!isMic) {
            NSLog(@"DUMP: audio size: %ld, chan: %d", size, audioBuffer.mNumberChannels);
            [self uploadAudio:data len:size];
        }
#endif
        if (isMic && m_micSource) {
            m_micSource->inputCallback(data, size, numFrames);
        }
        else if (!isMic && m_appAudioSource) {
            for (auto ptr = reinterpret_cast<uint16_t*>(data), endp = ptr + numFrames; ptr < endp; ++ptr) {
                *ptr = CFSwapInt16BigToHost(*ptr);
            }
            m_appAudioSource->inputCallback(data, size, numFrames);
        }
    }

    //Release the buffer when done with the samples
    //(retained by CMSampleBufferGetAudioBufferListWithRetainedblockBuffer)
    CFRelease(blockBuffer);
}

- (void) broadcastPaused {
    if (self.rtmpSessionState == VCSessionStateNone) return;
    
    auto audioMixer = std::dynamic_pointer_cast<videocore::Apple::AudioMixer>(m_audioMixer);
    auto videoMixer = std::dynamic_pointer_cast<videocore::iOS::CIVideoMixer>(m_videoMixer);
    audioMixer->mixPaused(true);
    videoMixer->mixPaused(true);
}

- (void) broadcastResumed {
    if (self.rtmpSessionState == VCSessionStateNone) return;
    
    auto audioMixer = std::dynamic_pointer_cast<videocore::Apple::AudioMixer>(m_audioMixer);
    auto videoMixer = std::dynamic_pointer_cast<videocore::iOS::CIVideoMixer>(m_videoMixer);
    audioMixer->mixPaused(false);
    videoMixer->mixPaused(false);
}

#if VC_DEBUG_DUMP_AUDIO
- (void) uploadAudio:(uint8_t*)pcm len:(size_t)length {

    NSData *data = [NSData dataWithBytes:pcm length:length];

    // Get the endpoint URL supplied by the UI extension in the service info dictionary
    NSURL *endpointURL = [NSURL URLWithString:@"http://172.0.0.82:3000/upload"];
    
    // Set up the request
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:endpointURL];
    [request setHTTPMethod:@"POST"];
    
    // Upload the movie file with an upload task
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionUploadTask *uploadTask = [session uploadTaskWithRequest:request fromData:data completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSLog(@"uploadAudio: uploaded");
    }];
    
    [uploadTask resume];
}
#endif

@end
