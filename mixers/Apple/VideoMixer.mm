/*
 
 Video Core
 Copyright (c) 2014 James G. Hurley
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 
 */


#include "videocore/mixers/Apple/VideoMixer.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <CoreVideo/CoreVideo.h>


#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)


@interface VideoMixObjCCallback : NSObject
{
    videocore::Apple::VideoMixer* _mixer;
}
- (void) setMixer: (videocore::Apple::VideoMixer*) mixer;
@end

@implementation VideoMixObjCCallback
- (instancetype) init {
    if((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(notification:) name:UIApplicationWillEnterForegroundNotification object:nil];
        
    }
    return self;
}
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
- (void) notification: (NSNotification*) notification {
    if([notification.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        
        _mixer->mixPaused(true);
        
    } else if([notification.name isEqualToString:UIApplicationWillEnterForegroundNotification]) {
        
        _mixer->mixPaused(false);
        
    }
}
- (void) setMixer: (videocore::Apple::VideoMixer*) mixer
{
    _mixer = mixer;
}
@end

namespace videocore { namespace Apple {
    
    // -------------------------------------------------------------------------
    //
    //
    //
    //
    // -------------------------------------------------------------------------
    VideoMixer::VideoMixer(int frame_w,
                           int frame_h,
                           double frameDuration)
    : m_bufferDuration(frameDuration),
    m_frameW(frame_w),
    m_frameH(frame_h),
    m_exiting(false),
    m_paused(false),
    m_epoch(std::chrono::steady_clock::now())
    {
        this->setup();

        m_callbackSession = [[VideoMixObjCCallback alloc] init];
        [(VideoMixObjCCallback*)m_callbackSession setMixer:this];
    }
    
    VideoMixer::~VideoMixer()
    {
        m_output.reset();
        m_exiting = true;
        m_mixThreadCond.notify_all();
        DLog("VideoMixer::~VideoMixer()");

        if(m_mixThread.joinable()) {
            m_mixThread.join();
        }
        [(id)m_callbackSession release];
    }
    
    void
    VideoMixer::setup() {
        CVPixelBufferRef blankPixelBufferRef = NULL;

        NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                              (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{} };

        CVPixelBufferCreate(kCFAllocatorDefault, m_frameW, m_frameH, kCVPixelFormatType_32BGRA, (CFDictionaryRef)pixelBufferOptions, &blankPixelBufferRef);

        auto ref = std::make_shared<Apple::PixelBuffer>(blankPixelBufferRef, true);
        ref->setState(kVCPixelBufferStateAcquired);

        m_currentBuffer = ref;
        CVPixelBufferRelease(blankPixelBufferRef);
    }
    
    void
    VideoMixer::start() {
        m_mixThread = std::thread([this](){ this->mixThread(); });
    }
    
    void
    VideoMixer::registerSource(std::shared_ptr<ISource> source,
                              size_t bufferSize)
    { }
    
    void
    VideoMixer::unregisterSource(std::shared_ptr<ISource> source)
    { }
    
    void
    VideoMixer::pushBuffer(const uint8_t *const data,
                             size_t size,
                             videocore::IMetadata &metadata)
    {
        if(m_paused.load()) {
            return;
        }

        std::unique_lock<std::mutex> l(m_mutex);
        auto ref = *(Apple::PixelBufferRef*) data;

        if(m_currentBuffer) {
            m_currentBuffer->setState(kVCPixelBufferStateAvailable);
        }
        ref->setState(kVCPixelBufferStateAcquired);

        m_currentBuffer = ref;
    }
    
    void
    VideoMixer::setOutput(std::shared_ptr<IOutput> output)
    {
        m_output = output;
    }
    
    void
    VideoMixer::mixThread()
    {
        const auto us = std::chrono::microseconds(static_cast<long long>(m_bufferDuration * 1000000.));
        const auto us_25 = std::chrono::microseconds(static_cast<long long>(m_bufferDuration * 250000.));

        m_us25 = us_25;
        m_nextMixTime = m_epoch;

        pthread_setname_np("com.videocore.compositeloop");
        
        while (!m_exiting.load())
        {
            std::unique_lock<std::mutex> l(m_mutex);
            const auto now = std::chrono::steady_clock::now();
            
            auto currentTime = m_nextMixTime;
            if (now < m_nextMixTime) goto wait;
            
            if (!m_shouldSync) {
                m_nextMixTime += us;
            } else {
                m_nextMixTime = m_syncPoint > m_nextMixTime ? m_syncPoint + us : m_nextMixTime + us;
            }
            
            if (!m_paused.load()) {
                auto lout = m_output.lock();
                if (lout && m_currentBuffer && m_currentBuffer->cvBuffer()) {
                    MetaData<'vide'> md(std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - m_epoch).count());
                    CVPixelBufferRef ref = m_currentBuffer->cvBuffer();
                    lout->pushBuffer((uint8_t*)ref, sizeof(ref), md);
                }
            }
        wait:
            m_mixThreadCond.wait_until(l, m_nextMixTime);
        }
    }

    void
    VideoMixer::mixPaused(bool paused)
    {
        m_paused = paused;
    }

    void
    VideoMixer::sync() {
        m_syncPoint = std::chrono::steady_clock::now();
        m_shouldSync = true;
    }
}
}
