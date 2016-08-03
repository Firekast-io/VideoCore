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


#include <videocore/mixers/iOS/CIVideoMixer.h>
#include <videocore/filters/FilterFactory.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <CoreVideo/CoreVideo.h>
#include <CoreImage/CoreImage.h>

// glm fix for cocoapods
#include <../Public/glm/gtc/matrix_transform.hpp>

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)


// Convenience macro to dispatch an CoreImage job to the created videocore::JobQueue
#define PERF_CI(x, dispatch) do {\
m_ciJobQueue.dispatch([=](){\
x; \
});\
} while(0)
// Dispatch and execute synchronously
#define PERF_CI_sync(x) PERF_CI((x), enqueue_sync);
// Dispatch and execute asynchronously
#define PERF_CI_async(x) PERF_CI((x), enqueue);

@interface CIObjCCallback : NSObject
{
    videocore::iOS::CIVideoMixer* _mixer;
}
- (void) setMixer: (videocore::iOS::CIVideoMixer*) mixer;
@end
@implementation CIObjCCallback
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
- (void) setMixer: (videocore::iOS::CIVideoMixer*) mixer
{
    _mixer = mixer;
}
@end
namespace videocore { namespace iOS {
    
    // -------------------------------------------------------------------------
    //
    //  SourceBuffer::setBuffer
    //      Creates a related GLES texture and keeps track of the first-in-line
    //      texture.  Textures unused for more than 1 second will be released.
    //
    // -------------------------------------------------------------------------

    void
    CISourceBuffer::setBuffer(Apple::PixelBufferRef ref)
    {
        if(m_currentBuffer) {
            m_currentBuffer->setState(kVCPixelBufferStateAvailable);
        }
        ref->setState(kVCPixelBufferStateAcquired);

        m_currentBuffer = ref;
        m_time = std::chrono::steady_clock::now();
    }
    
    CISourceBuffer::~CISourceBuffer() {
        if (m_currentBuffer) {
            m_currentBuffer->setState(kVCPixelBufferStateAvailable);
            m_currentBuffer = nullptr;
        }
    }

    // -------------------------------------------------------------------------
    //
    //
    //
    //
    // -------------------------------------------------------------------------
    CIVideoMixer::CIVideoMixer(int frame_w,
                               int frame_h,
                               double frameDuration,
                               CVPixelBufferPoolRef pool)
    : m_bufferDuration(frameDuration),
    m_frameW(frame_w),
    m_frameH(frame_h),
    m_exiting(false),
    m_mixing(false),
    m_pixelBufferPool(pool),
    m_paused(false),
    m_ciJobQueue("com.videocore.composite"),
    m_catchingUp(false),
    m_epoch(std::chrono::steady_clock::now())
    {
        PERF_CI_sync({
            this->setup();
        });

        m_zRange.first = INT_MAX;
        m_zRange.second = INT_MIN;
        
        m_callbackSession = [[CIObjCCallback alloc] init];
        [(CIObjCCallback*)m_callbackSession setMixer:this];
    }
    
    CIVideoMixer::~CIVideoMixer()
    {
        m_output.reset();
        m_exiting = true;
        m_mixThreadCond.notify_all();
        DLog("CIVideoMixer::~CIVideoMixer()");

        PERF_CI_sync({
            m_sourceBuffers.clear();
            CVPixelBufferRelease(m_pixelBuffer[0]);
            CVPixelBufferRelease(m_pixelBuffer[1]);
        });
        
        if(m_mixThread.joinable()) {
            m_mixThread.join();
        }
        m_ciJobQueue.mark_exiting();
        m_ciJobQueue.enqueue_sync([](){});

        [(id)m_callbackSession release];
    }
    
    void
    CIVideoMixer::start() {
        m_mixThread = std::thread([this](){ this->mixThread(); });
    }

    void
    CIVideoMixer::setup()
    {
        if(!m_pixelBufferPool) {
            NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                                  (NSString*) kCVPixelBufferWidthKey : @(m_frameW),
                                                  (NSString*) kCVPixelBufferHeightKey : @(m_frameH),
                                                  (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                                  (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
            
            CVPixelBufferCreate(kCFAllocatorDefault, m_frameW, m_frameH, kCVPixelFormatType_32BGRA, (CFDictionaryRef)pixelBufferOptions, &m_pixelBuffer[0]);
            CVPixelBufferCreate(kCFAllocatorDefault, m_frameW, m_frameH, kCVPixelFormatType_32BGRA, (CFDictionaryRef)pixelBufferOptions, &m_pixelBuffer[1]);
        }
        else {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, m_pixelBufferPool, &m_pixelBuffer[0]);
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, m_pixelBufferPool, &m_pixelBuffer[1]);
        }
    }

    void
    CIVideoMixer::registerSource(std::shared_ptr<ISource> source,
                                   size_t bufferSize)
    {
        const auto hash = std::hash< std::shared_ptr<ISource> > () (source);
        bool registered = false;
        
        for ( auto it : m_sources) {
            auto lsource = it.lock();
            if(lsource) {
                const auto shash = std::hash< std::shared_ptr<ISource> >() (lsource);
                if(shash == hash) {
                    registered = true;
                    break;
                }
            }
        }
        if(!registered)
        {
            m_sources.push_back(source);
        }
    }

    void
    CIVideoMixer::releaseBuffer(std::weak_ptr<ISource> source)
    {
        DLog("CIVideoMixer::releaseBuffer");
        const auto h = hash(source);
        auto it = m_sourceBuffers.find(h) ;
        if(it != m_sourceBuffers.end()) {
            m_sourceBuffers.erase(it);
        }
        
    }

    void
    CIVideoMixer::unregisterSource(std::shared_ptr<ISource> source)
    {
        DLog("CIVideoMixer::unregisterSource");
        releaseBuffer(source);
        
        auto it = m_sources.begin();
        const auto h = std::hash<std::shared_ptr<ISource> >()(source);
        for ( ; it != m_sources.end() ; ++it ) {
            
            const auto shash = hash(*it);
            
            if(h == shash) {
                m_sources.erase(it);
                break;
            }
            
        }
        {
            auto iit = m_sourceBuffers.find(h);
            if(iit != m_sourceBuffers.end()) {
                m_sourceBuffers.erase(iit);
            }
        }
        for ( int i = m_zRange.first ; i <= m_zRange.second ; ++i )
        {
            for ( auto iit = m_layerMap[i].begin() ; iit!= m_layerMap[i].end() ; ++iit) {
                if((*iit) == h) {
                    m_layerMap[i].erase(iit);
                    break;
                }
            }
        }
        
    }

    void
    CIVideoMixer::pushBuffer(const uint8_t *const data,
                               size_t size,
                               videocore::IMetadata &metadata)
    {
        if(m_paused.load()) {
            return;
        }
        
        VideoBufferMetadata &md = dynamic_cast<VideoBufferMetadata&>(metadata);
        const int zIndex = md.getData<kVideoMetadataZIndex>();
        
        const glm::mat4 mat = md.getData<kVideoMetadataMatrix>();
        
        if(zIndex < m_zRange.first) {
            m_zRange.first = zIndex;
        }
        if(zIndex > m_zRange.second) {
            m_zRange.second = zIndex;
        }
        
        std::weak_ptr<ISource> source = md.getData<kVideoMetadataSource>();
        
        const auto h = hash(source);
        
        
        auto inPixelBuffer = *(Apple::PixelBufferRef*)data ;

        m_sourceBuffers[h].setBuffer(inPixelBuffer);
        m_sourceBuffers[h].setBlends(md.getData<kVideoMetadataBlends>());
        
        auto it = std::find(this->m_layerMap[zIndex].begin(), this->m_layerMap[zIndex].end(), h);
        if(it == this->m_layerMap[zIndex].end()) {
            this->m_layerMap[zIndex].push_back(h);
        }
        this->m_sourceMats[h] = mat;
    }

    void
    CIVideoMixer::setOutput(std::shared_ptr<IOutput> output)
    {
        m_output = output;
    }

    const std::size_t
    CIVideoMixer::hash(std::weak_ptr<ISource> source) const
    {
        const auto l = source.lock();
        if (l) {
            return std::hash< std::shared_ptr<ISource> >()(l);
        }
        return 0;
    }

    void
    CIVideoMixer::mixThread()
    {
        const auto us = std::chrono::microseconds(static_cast<long long>(m_bufferDuration * 1000000.));
        const auto us_25 = std::chrono::microseconds(static_cast<long long>(m_bufferDuration * 250000.));
        m_us25 = us_25;
        
        pthread_setname_np("com.videocore.compositeloop");
        
        int current_fb = 0;
        
        bool locked[2] = {false};

        @autoreleasepool {

            EAGLContext *mixEAGLContext = [[[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2] autorelease];
            NSDictionary *options = @{ kCIContextWorkingColorSpace : [NSNull null] };

            CIContext *mixContext = [CIContext contextWithEAGLContext:mixEAGLContext options:options];
            
            m_nextMixTime = m_epoch;
            
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
                
                if (m_mixing.load() || m_paused.load()) goto wait;
                
                locked[current_fb] = true;

                m_mixing = true;
                
                PERF_CI_async({
                    CIImage *ciImage = nil;

                    for ( int i = m_zRange.first ; i <= m_zRange.second ; ++i) {
                        for ( auto it = this->m_layerMap[i].begin() ; it != this->m_layerMap[i].end() ; ++ it) {
                            auto iip = this->m_sourceBuffers.find(*it);
                            if (iip == this->m_sourceBuffers.end() || !iip->second.currentBuffer()) continue;
                            
                            if (i == 1 || !ciImage) {
                                ciImage = [CIImage imageWithCVPixelBuffer:iip->second.currentBuffer()->cvBuffer()];
                                ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeRotation(-M_PI/2)];
                                ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeTranslation(0, ciImage.extent.size.height)];

                            } else if (i >= 2) {
                                CIImage *ciImage2 = [CIImage imageWithCVPixelBuffer:iip->second.currentBuffer()->cvBuffer()];
                                ciImage2 = [ciImage2 imageByApplyingTransform:CGAffineTransformMakeTranslation(10, 10)];
                                ciImage = [ciImage2 imageByCompositingOverImage:ciImage];

                            }
                            //mat = this->m_sourceMats[*it];
                        }
                    }

                    if (ciImage) {
                        [mixContext render:ciImage toCVPixelBuffer:this->m_pixelBuffer[current_fb]];
                    }

                    auto lout = this->m_output.lock();
                    if (lout) {
                        MetaData<'vide'> md(std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - m_epoch).count());
                        lout->pushBuffer((uint8_t*)this->m_pixelBuffer[current_fb], sizeof(this->m_pixelBuffer[current_fb]), md);
                    }
                    this->m_mixing = false;
                    
                });
                current_fb = !current_fb;
                
            wait:
                m_mixThreadCond.wait_until(l, m_nextMixTime);
            }
        }
    }
    
    void
    CIVideoMixer::mixPaused(bool paused)
    {
        m_paused = paused;
    }
    
    void
    CIVideoMixer::setSourceFilter(std::weak_ptr<ISource> source, IVideoFilter *filter) {
        auto h = hash(source);
        m_sourceFilters[h] = filter;
    }
    
    void
    CIVideoMixer::sync() {
        m_syncPoint = std::chrono::steady_clock::now();
        m_shouldSync = true;
    }
}
}
