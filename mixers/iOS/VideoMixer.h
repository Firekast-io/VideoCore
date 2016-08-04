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


#ifndef __videocore__VideoMixer__
#define __videocore__VideoMixer__

#include <iostream>
#include <videocore/mixers/IVideoMixer.hpp>
#include <videocore/system/pixelBuffer/Apple/PixelBuffer.h>

#include <thread>
#include <mutex>
#include <CoreVideo/CoreVideo.h>

namespace videocore { namespace iOS {
    
    /*
     *  Takes CVPixelBufferRef inputs and outputs a single CVPixelBufferRef that has been composited from the various sources.
     *  Sources must output VideoBufferMetadata with their buffers. This compositor uses homogeneous coordinates.
     */
    class VideoMixer : public IVideoMixer
    {
        
    public:
        /*! Constructor.
         *
         *  \param frame_w          The width of the output frame
         *  \param frame_h          The height of the output frame
         *  \param frameDuration    The duration of time a frame is presented, in seconds. 30 FPS would be (1/30)
         */
        VideoMixer(int frame_w,
                   int frame_h,
                   double frameDuration);
        
        /*! Destructor */
        ~VideoMixer();
        
        /*! IMixer::registerSource */
        void registerSource(std::shared_ptr<ISource> source,
                            size_t bufferSize = 0)  ;
        
        /*! IMixer::unregisterSource */
        void unregisterSource(std::shared_ptr<ISource> source);
        
        /*! IVideoMixer::setSourceFilter */
        void setSourceFilter(std::weak_ptr<ISource> source, IVideoFilter *filter) { }
        
        /*! IVideoMixer::sync */
        void sync();
        
        /*! IVideoMixer::filterFactory */
        FilterFactory& filterFactory() { return nullptr; }
        
        /*! IOutput::pushBuffer */
        void pushBuffer(const uint8_t* const data,
                        size_t size,
                        IMetadata& metadata);
        
        /*! ITransform::setOutput */
        void setOutput(std::shared_ptr<IOutput> output);
        
        /*! ITransform::setEpoch */
        void setEpoch(const std::chrono::steady_clock::time_point epoch) {
            m_epoch = epoch;
            m_nextMixTime = epoch;
        }
        
        void start();
        
    public:
        
        void mixPaused(bool paused);

    private:
        /*! Start the compositor thread */
        void mixThread();
        
        /*!
         * Setup the mixer.
         */
        void setup();
        
        
    private:
        
        double m_bufferDuration;
        
        std::weak_ptr<IOutput> m_output;
        
        std::thread m_mixThread;
        std::mutex  m_mutex;
        std::condition_variable m_mixThreadCond;
                
        void* m_callbackSession;
        
        int m_frameW;
        int m_frameH;

        Apple::PixelBufferRef m_currentBuffer;
        
        std::chrono::steady_clock::time_point m_syncPoint;
        std::chrono::steady_clock::time_point m_epoch;
        std::chrono::steady_clock::time_point m_nextMixTime;
        std::chrono::microseconds m_us25;
        
        std::atomic<bool> m_exiting;
        std::atomic<bool> m_paused;
        
        bool              m_shouldSync;
    };
    
}
}
#endif /* defined(__videocore__VideoMixer__) */
