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
#import <AVFoundation/AVFoundation.h>

#include "videocore/transforms/Apple/MP4Multiplexer.h"
#include "videocore/mixers/IAudioMixer.hpp"

//CMFormatDescription.h
#define ROMAIN_AUDIO



namespace videocore { namespace Apple {
 
    
    MP4Multiplexer::MP4Multiplexer() : m_assetWriter(nullptr), m_videoInput(nullptr), m_audioInput(nullptr), m_videoFormat(nullptr), m_audioFormat(nullptr), m_fps(30), m_framecount(0), m_firstAudioSample(true)
    {
        
    }
    MP4Multiplexer::~MP4Multiplexer()
    {
        if(m_videoInput) {
            NSLog(@"Romain: finish video");
            [(AVAssetWriterInput*)m_videoInput markAsFinished];
        }
        if(m_audioInput) {
            NSLog(@"Romain: finish audio");
            [(AVAssetWriterInput*)m_audioInput markAsFinished];
        }
        if(m_assetWriter) {
            __block AVAssetWriter* writer = (AVAssetWriter*)m_assetWriter;
            [writer finishWritingWithCompletionHandler:^{
                NSLog(@"Romain: release");
                [writer release];
            }];
            
        }
        if(m_videoFormat) {
            CFRelease(m_videoFormat);
        }
    }
    
    void
    MP4Multiplexer::setSessionParameters(videocore::IMetadata &parameters)
    {
        auto & parms = dynamic_cast<videocore::Apple::MP4SessionParameters_t&>(parameters);
        
        auto filename = parms.getData<kMP4SessionFilename>()  ;
        m_fps = parms.getData<kMP4SessionFPS>();
        m_width = parms.getData<kMP4SessionWidth>();
        m_height = parms.getData<kMP4SessionHeight>();
        NSLog(@"(%d, %d, %d)", m_fps, m_width, m_height);
        m_filename = filename;
        
#ifdef ROMAIN_AUDIO
        CMFormatDescriptionRef audioDesc;
#endif
        CMFormatDescriptionRef videoDesc;

#ifdef ROMAIN_AUDIO
        CMFormatDescriptionCreate(kCFAllocatorDefault, kCMMediaType_Audio, 'aac ', NULL, &audioDesc);
#endif
        CMFormatDescriptionCreate(kCFAllocatorDefault, kCMMediaType_Video, 'avc1', NULL, &videoDesc);
        
        AVAssetWriterInput* video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:nil];
#ifdef ROMAIN_AUDIO
        AVAssetWriterInput* audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:nil];
#endif
        
        NSURL* fileUrl = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filename.c_str()]];
        NSLog(@"MP4 output file: %@", [fileUrl absoluteString]);
        AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:fileUrl fileType:AVFileTypeQuickTimeMovie error:nil];
        video.expectsMediaDataInRealTime = YES;
#ifdef ROMAIN_AUDIO
        audio.expectsMediaDataInRealTime = YES;
#endif
        
        if ([writer canAddInput:video])
            NSLog(@"Can add video input");
        else{
            NSLog(@"Can't add video input");
        }
        [writer addInput:video];
        
#ifdef ROMAIN_AUDIO
        if ([writer canAddInput:audio])
            NSLog(@"Can add audio input");
        else{
            NSLog(@"Can't add audio input");
        }
        [writer addInput:audio];
#endif
        
        CMTime time = {0};
        time.timescale = m_fps;
        time.flags = kCMTimeFlags_Valid;
        
        [writer startWriting];
        [writer startSessionAtSourceTime:time];
        
        m_assetWriter = writer;
#ifdef ROMAIN_AUDIO
        m_audioInput = audio;
#endif
        m_videoInput = video;
        
    }
    
    void
    MP4Multiplexer::setBandwidthCallback(BandwidthCallback callback) {
      // TODO
    }
    
    void
    MP4Multiplexer::pushBuffer(const uint8_t *const data, size_t size, videocore::IMetadata &metadata)
    {
        if (((AVAssetWriter*)m_assetWriter).status > AVAssetWriterStatusWriting) {
            if (((AVAssetWriter*)m_assetWriter).status == AVAssetWriterStatusFailed) {
                NSLog(@"Error: %@", ((AVAssetWriter*)m_assetWriter).error);
            }
        }
        
        switch(metadata.type()) {
            case 'vide':
                // Process video
                pushVideoBuffer(data,size,metadata);
                break;
            case 'soun':
                // Process audio
                pushAudioBuffer(data,size,metadata);
                break;
            default:
                break;
        }
    }
    
    void
    MP4Multiplexer::pushVideoBuffer(const uint8_t* const data, size_t size, IMetadata& metadata)
    {
        const int nalu_type = data[4] & 0x1F;
        
        if( nalu_type == 7 && m_sps.empty() ) {
            m_sps.insert(m_sps.end(), &data[4], &data[size]);
            if(!m_pps.empty()) {
                createAVCC();
            }
        }
        else if( nalu_type == 8 && m_pps.empty() ) {
            m_pps.insert(m_pps.end(), &data[4], &data[size]);
            if(!m_sps.empty()) {
                createAVCC();
            }
        }
        else if (nalu_type <= 5)
        {
            //Romain: start with an idr
            
            std::vector<uint8_t> data2;
            data2.reserve(size);
            uint32_t dataLength32 = htonl(size-4);
            data2.resize(sizeof(uint32_t));
            memcpy(data2.data(), &dataLength32, sizeof(uint32_t));
            data2.insert(data2.end(), data+4, data+size);
            assert(data2.size() == size);
            
            CMSampleBufferRef sample;
            CMBlockBufferRef buffer;
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, data2.data(), size, kCFAllocatorDefault, NULL, 0, size, kCMBlockBufferAssureMemoryNowFlag, &buffer);
            
            CMSampleTimingInfo videoSampleTimingInformation;
            videoSampleTimingInformation.duration = CMTimeMake(1, m_fps);
            videoSampleTimingInformation.presentationTimeStamp = CMTimeMake(metadata.timestampDelta, 1000.);
            videoSampleTimingInformation.decodeTimeStamp = CMTimeMake(metadata.dts, 1000.);
            
            CMSampleBufferCreate(kCFAllocatorDefault, buffer, true, NULL, NULL, (CMFormatDescriptionRef)m_videoFormat, 1, 1, &videoSampleTimingInformation, 1, &size, &sample);
            
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
            CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            if (nalu_type == 5) { /* non-IDR => non-sync sample */
                CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
            }
            CMSampleBufferMakeDataReady(sample);
            
            AVAssetWriterInput* video = (AVAssetWriterInput*)m_videoInput;
            
            NSLog(@"Appending video %d", (int)metadata.timestampDelta);
            do {
            if(video.readyForMoreMediaData) {
                if (![video appendSampleBuffer:sample]) {
                    NSLog(@"Appending video error");
                } else
                    break;
            } else {
                NSLog(@"Appending video: not ready for more media %d", (int)metadata.timestampDelta);
            }
                
            [NSThread sleepForTimeInterval:0.01f];
                
            } while (!video.readyForMoreMediaData);
                
            NSLog(@"Done video");
            CFRelease(sample);
        }
        
    }
    
    void
    MP4Multiplexer::pushAudioBuffer(const uint8_t *const data, size_t size, videocore::IMetadata &metadata)
    {
        if (!m_audioFormat) {
            AudioBufferMetadata& md = dynamic_cast<AudioBufferMetadata&>(metadata);
            AudioStreamBasicDescription asbd = {0};
            asbd.mFormatID = kAudioFormatMPEG4AAC;
            asbd.mFormatFlags = kMPEG4Object_AAC_Main;
            asbd.mFramesPerPacket = 1024;
            asbd.mSampleRate = md.getData<kAudioMetadataFrequencyInHz>();
            asbd.mChannelsPerFrame = md.getData<kAudioMetadataChannelCount>();
            
            OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, NULL, NULL/*size, data*/, NULL, (CMAudioFormatDescriptionRef*)&m_audioFormat);
            NSLog(@"\t\t Creation of CMAudioFormatDescriptionCreate: %@", (status == noErr) ? @"successful!" : @"failed...");
            if (status != noErr)
                NSLog(@"\t\t Format Description ERROR type: %d", (int)status);
        } else {
            AudioBufferMetadata& md = dynamic_cast<AudioBufferMetadata&>(metadata);
            CMSampleTimingInfo audioSampleTimingInformation;
            audioSampleTimingInformation.duration = CMTimeMake(1024, md.getData<kAudioMetadataFrequencyInHz>());
            audioSampleTimingInformation.presentationTimeStamp = CMTimeMake(metadata.timestampDelta, 1000.);
            audioSampleTimingInformation.decodeTimeStamp = CMTimeMake(metadata.dts, 1000.);
            
            CMSampleBufferRef sample;
            CMBlockBufferRef buffer;
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, (void*)data, size, kCFAllocatorDefault, NULL, 0, size, kCMBlockBufferAssureMemoryNowFlag, &buffer);
    

            CMSampleBufferCreate(kCFAllocatorDefault,
                                 buffer,
                                 true,
                                 NULL,
                                 NULL,
                                 (CMFormatDescriptionRef)m_audioFormat,
                                 1,
                                 1,
                                 &audioSampleTimingInformation,
                                 1,
                                 &size,
                                 &sample);
            
            CFDictionaryRef dict = CMTimeCopyAsDictionary(CMTimeMake(1024, 44100), kCFAllocatorDefault);
            if (m_firstAudioSample) {
                CMSetAttachment(sample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, dict, kCMAttachmentMode_ShouldNotPropagate);
                m_firstAudioSample = false;
            }
            CMSampleBufferMakeDataReady(sample);
            AVAssetWriterInput* audio = (AVAssetWriterInput*)m_audioInput;
            
            NSLog(@"Appending audio");
            if(audio.readyForMoreMediaData) {
                if (![audio appendSampleBuffer:sample]) {
                    NSLog(@"Appending audio error");
                }
            } else {
                NSLog(@"Appending audio: not ready for more media");
            }
            NSLog(@"Done audio");
            CFRelease(sample);
            CFRelease(dict);
        }
    }
    
    void
    MP4Multiplexer::createAVCC()
    {
        uint8_t const * const parameterSetPointers[2] = {m_sps.data(), m_pps.data()};
        size_t parameterSetSizes[2] = { m_sps.size(), m_pps.size() };
        
        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2,
                                                                     parameterSetPointers,
                                                                     parameterSetSizes, 4,
                                                                     (CMVideoFormatDescriptionRef*)&m_videoFormat);
        
        NSLog(@"\t\t Creation of CMVideoFormatDescription: %@", (status == noErr) ? @"successful!" : @"failed...");
        if (status != noErr)
            NSLog(@"\t\t Format Description ERROR type: %d", (int)status);
        
        NSLog(@"Romain: created AVCC");
    }
    
}
}
