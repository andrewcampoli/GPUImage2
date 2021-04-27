//
//  MovieCache.swift
//  GPUImage2
//
//  Created by 陈品霖 on 2020/3/27.
//

import Foundation
import AVFoundation

public enum MovieCacheError: Error, Equatable, CustomStringConvertible {
    case invalidState
    case sameState
    case emptyMovieOutput
    case unmatchedVideoID
    case movieOutputError(Error)
    
    public var description: String {
        switch self {
        case .invalidState: return "invalidState"
        case .sameState: return "sameState"
        case .emptyMovieOutput: return "emptyMovieOutput"
        case .movieOutputError: return "movieOutputError"
        case .unmatchedVideoID: return "unmatchedVideoID"
        }
    }
    
    public static func == (lhs: MovieCacheError, rhs: MovieCacheError) -> Bool {
        return lhs.description == rhs.description
    }
}

public class MovieCache: ImageConsumer, AudioEncodingTarget {
    public typealias Completion = (Result<MovieOutput?, MovieCacheError>) -> Void
    public let sources = SourceContainer()
    public let maximumInputs: UInt = 1
    public private(set) var movieOutput: MovieOutput?
    public private(set) lazy var framebufferCache = [Framebuffer]()
    public private(set) lazy var videoSampleBufferCache = NSMutableArray()
    public private(set) lazy var audioSampleBufferCache = [CMSampleBuffer]()
    public private(set) var cacheBuffersDuration: TimeInterval = 0
    public enum State: String {
        case unknown
        case idle
        case caching
        case writing
        case stopped
        case canceled
    }
    public private(set) var state = State.unknown
    private var writingCallback: Completion?
    public var isReadyToWrite: Bool {
        guard let movieOutput = movieOutput else { return false }
        return movieOutput.writerStatus == .unknown
    }
    private var startingVideoID: String?
    #if DEBUG
    public var debugRenderInfo: String = "{ MovieCache: passthrough },"
    #endif
    
    public init() {
        print("MovieCache init")
    }
    
    deinit {
        if movieOutput?.writerStatus == .writing {
            print("[WARNING] movieOutput is still writing, cancel it now")
            movieOutput?.cancelRecording()
        }
    }
    
    public func startCaching(duration: TimeInterval) {
        MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
            self?._startCaching(duration: duration)
        }
    }
    
    public func setMovieOutputIfNotReady(url: URL,
                                         fps: Double,
                                         size: Size,
                                         needAlignAV: Bool,
                                         fileType: AVFileType = .mov,
                                         liveVideo: Bool = false,
                                         videoSettings: [String: Any]? = nil,
                                         videoNaturalTimeScale: CMTimeScale? = nil,
                                         optimizeForNetworkUse: Bool = false,
                                         disablePixelBufferAttachments: Bool = true,
                                         audioSettings: [String: Any]? = nil,
                                         audioSourceFormatHint: CMFormatDescription? = nil,
                                         _ configure: ((MovieOutput) -> Void)? = nil) {
        MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
            self?._setMovieOutputIfNotReady(url: url,
                                            fps: fps,
                                            size: size,
                                            needAlignAV: needAlignAV,
                                            fileType: fileType,
                                            liveVideo: liveVideo,
                                            videoSettings: videoSettings,
                                            videoNaturalTimeScale: videoNaturalTimeScale,
                                            optimizeForNetworkUse: optimizeForNetworkUse,
                                            disablePixelBufferAttachments: disablePixelBufferAttachments,
                                            audioSettings: audioSettings,
                                            audioSourceFormatHint: audioSourceFormatHint,
                                            configure)
        }
    }
    
    public func startWriting(videoID: String?, _ completionCallback: Completion? = nil) {
        MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
            self?._startWriting(videoID: videoID, completionCallback)
        }
    }
    
    public func stopWriting(videoID: String?, _ completionCallback: ((MovieOutput?, MovieCacheError?) -> Void)? = nil) {
        MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
            self?._stopWriting(videoID: videoID, completionCallback)
        }
    }
    
    public func cancelWriting(videoID: String?, _ completionCallback: Completion? = nil) {
        MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
            self?._cancelWriting(videoID: videoID, completionCallback)
        }
    }
    
    public func stopCaching(needsCancel: Bool = false, _ completionCallback: Completion? = nil) {
        MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
            self?._stopCaching(needsCancel: needsCancel, completionCallback)
        }
    }
}

extension MovieCache {
    public func newFramebufferAvailable(_ framebuffer: Framebuffer, fromSourceIndex: UInt) {
//        debugPrint("get new framebuffer time:\(framebuffer.timingStyle.timestamp?.asCMTime.seconds ?? .zero)")
        guard shouldProcessBuffer else { return }
        glFinish()
        _cacheFramebuffer(framebuffer)
        _writeFramebuffers()
    }
    
    public func activateAudioTrack() throws {
        try movieOutput?.activateAudioTrack()
    }
    
    public func processAudioBuffer(_ sampleBuffer: CMSampleBuffer, shouldInvalidateSampleWhenDone: Bool) {
        guard shouldProcessBuffer else { return }
        _cacheAudioSampleBuffer(sampleBuffer)
        _writeAudioSampleBuffers(shouldInvalidateSampleWhenDone)
    }
    
    public func processVideoBuffer(_ sampleBuffer: CMSampleBuffer, shouldInvalidateSampleWhenDone: Bool) {
        guard shouldProcessBuffer else { return }
        _cacheVideoSampleBuffer(sampleBuffer)
        _writeVideoSampleBuffers(shouldInvalidateSampleWhenDone)
    }
    
    public func readyForNextAudioBuffer() -> Bool {
        guard shouldProcessBuffer else { return false }
        return true
    }
}

private extension MovieCache {
    var shouldProcessBuffer: Bool {
        return state != .unknown && state != .idle
    }
    
    func _tryTransitingState(to newState: State, _ errorCallback: Completion? = nil) -> MovieCacheError? {
        if state == newState {
            // NOTE: for same state, just do nothing and callback
            print("WARNING: Same state transition for:\(state)")
            errorCallback?(.success(movieOutput))
            return .sameState
        }
        switch (state, newState) {
        case (.unknown, .idle), (.unknown, .caching), (.unknown, .writing), (.unknown, .stopped),
             (.idle, .caching), (.idle, .writing),
             (.caching, .writing), (.caching, .stopped), (.caching, .idle),
             (.writing, .stopped),
             (.stopped, .idle), (.stopped, .caching), (.stopped, .writing),
             (.canceled, .idle), (.canceled, .caching), (.canceled, .writing), (.canceled, .stopped),
             (_, .canceled): // any state can transite to canceled
            debugPrint("state transite from:\(state) to:\(newState)")
            state = newState
            return nil
        default:
            assertionFailure()
            print("ERROR: invalid state transition from:\(state) to:\(newState)")
            errorCallback?(.failure(.invalidState))
            return .invalidState
        }
    }
    
    func _startCaching(duration: TimeInterval) {
        let error = _tryTransitingState(to: .caching)
        guard error == nil else { return }
        print("start caching")
        cacheBuffersDuration = duration
    }
    
    func _setMovieOutputIfNotReady(url: URL,
                                   fps: Double,
                                   size: Size,
                                   needAlignAV: Bool,
                                   fileType: AVFileType = .mov,
                                   liveVideo: Bool = false,
                                   videoSettings: [String: Any]? = nil,
                                   videoNaturalTimeScale: CMTimeScale? = nil,
                                   optimizeForNetworkUse: Bool = false,
                                   disablePixelBufferAttachments: Bool = true,
                                   audioSettings: [String: Any]? = nil,
                                   audioSourceFormatHint: CMFormatDescription? = nil,
                                   _ configure: ((MovieOutput) -> Void)? = nil) {
        guard !isReadyToWrite else {
            print("No need to create MovieOutput")
            return
        }
        if let currentMovieOutput = movieOutput, movieOutput?.writerStatus == .writing {
            print("MovieOutput is still writing, skip set MovieOutput. state:\(state) currentURL:\(currentMovieOutput.url) newURL:\(url)")
            return
        }
        do {
            let newMovieOutput = try MovieOutput(URL: url,
                                                 fps: fps,
                                                 size: size,
                                                 needAlignAV: needAlignAV,
                                                 fileType: fileType,
                                                 liveVideo: liveVideo,
                                                 videoSettings: videoSettings,
                                                 videoNaturalTimeScale: videoNaturalTimeScale,
                                                 optimizeForNetworkUse: optimizeForNetworkUse,
                                                 disablePixelBufferAttachments: disablePixelBufferAttachments,
                                                 audioSettings: audioSettings,
                                                 audioSourceFormatHint: audioSourceFormatHint)
            self.movieOutput = newMovieOutput
            print("set movie output")
            configure?(newMovieOutput)
            if state == .writing {
                print("it is already writing, start MovieOutput recording immediately, videoID:\(String(describing: startingVideoID))")
                _startMovieOutput(videoID: startingVideoID, writingCallback)
                startingVideoID = nil
            }
        } catch {
            print("[ERROR] can't create movie output")
        }
    }
    
    func _startWriting(videoID: String?, _ completionCallback: Completion? = nil) {
        guard _tryTransitingState(to: .writing) == nil else { return }
        guard movieOutput != nil else {
            print("movie output is not ready yet, waiting...")
            writingCallback = completionCallback
            startingVideoID = videoID
            return
        }
        print("start writing, videoID:\(String(describing: videoID))")
        _startMovieOutput(videoID: videoID, completionCallback)
    }
    
    func _startMovieOutput(videoID: String?, _ completionCallback: Completion? = nil) {
        guard let movieOutput = movieOutput else {
            completionCallback?(.failure(.emptyMovieOutput))
            return
        }
        movieOutput.videoID = videoID
        movieOutput.startRecording(sync: true) { _, error in
            if let error = error {
                completionCallback?(.failure(.movieOutputError(error)))
            } else {
                completionCallback?(.success(movieOutput))
            }
        }
    }
    
    func _stopWriting(videoID: String?, _ completionCallback: ((MovieOutput?, MovieCacheError?) -> Void)? = nil) {
        guard videoID == movieOutput?.videoID else {
            print("stopWriting failed. Unmatched videoID:\(String(describing: videoID)) movieOutput?.videoID:\(String(describing: movieOutput?.videoID))")
            completionCallback?(movieOutput, .unmatchedVideoID)
            return
        }
        guard _tryTransitingState(to: .stopped) == nil else {
            completionCallback?(movieOutput, .invalidState)
            return
        }
        guard let movieOutput = movieOutput else {
            completionCallback?(nil, .emptyMovieOutput)
            return
        }
        print("stop writing. videoID:\(String(describing: videoID)) videoFramebuffers:\(framebufferCache.count) audioSampleBuffers:\(audioSampleBufferCache.count) videoSampleBuffers:\(videoSampleBufferCache.count)")
        movieOutput.finishRecording(sync: true) {
            if let error = movieOutput.writerError {
                completionCallback?(movieOutput, .movieOutputError(error))
            } else {
                completionCallback?(movieOutput, nil)
            }
        }
        self.movieOutput = nil
        writingCallback = nil
    }
    
    func _cancelWriting(videoID: String?, _ completionCallback: Completion? = nil) {
        guard videoID == movieOutput?.videoID else {
            print("cancelWriting failed. Unmatched videoID:\(String(describing: videoID)) movieOutput?.videoID:\(String(describing: movieOutput?.videoID))")
            completionCallback?(.failure(.unmatchedVideoID))
            return
        }
        defer {
            movieOutput = nil
            writingCallback = nil
        }
        guard _tryTransitingState(to: .canceled) == nil else { return }
        guard let movieOutput = movieOutput else {
            completionCallback?(.success(self.movieOutput))
            return
        }
        print("cancel writing, videoID:\(String(describing: videoID))")
        movieOutput.cancelRecording(sync: true) {
            completionCallback?(.success(movieOutput))
        }
    }
    
    func _stopCaching(needsCancel: Bool, _ completionCallback: Completion?) {
        let movieOutput = self.movieOutput
        if needsCancel && state == .writing {
            _cancelWriting(videoID: nil)
            startingVideoID = nil
        }
        defer {
            completionCallback?(.success(movieOutput))
        }
        guard _tryTransitingState(to: .idle) == nil else { return }
        print("stop caching")
        _cleanBufferCaches()
    }
    
    func _cleanBufferCaches() {
        print("Clean all buffers framebufferCache:\(framebufferCache.count) audioSampleBuffer:\(audioSampleBufferCache.count) videoSampleBuffers:\(videoSampleBufferCache.count)")
        sharedImageProcessingContext.runOperationSynchronously {
            self.framebufferCache.forEach { $0.unlock() }
            self.framebufferCache.removeAll()
            self.videoSampleBufferCache.removeAllObjects()
            self.audioSampleBufferCache.removeAll()
        }
    }
    
    func _cacheFramebuffer(_ framebuffer: Framebuffer) {
        guard let frameTime = framebuffer.timingStyle.timestamp?.asCMTime else {
            print("Cannot get timestamp from framebuffer, dropping frame")
            return
        }
        framebufferCache.append(framebuffer)
        while let firstBufferTime = framebufferCache.first?.timingStyle.timestamp?.asCMTime, CMTimeSubtract(frameTime, firstBufferTime).seconds > cacheBuffersDuration {
//            debugPrint("dropping oldest video framebuffer time:\(firstBufferTime.seconds)")
            _ = framebufferCache.removeFirst()
        }
    }
    
    func _writeFramebuffers() {
        guard state == .writing else { return }
        var appendedBufferCount = 0
        for framebuffer in framebufferCache {
            guard movieOutput?._processFramebuffer(framebuffer) == true else { break }
            appendedBufferCount += 1
            framebuffer.unlock()
            // NOTE: don't occupy too much GPU time, if it is already accumulate lots of framebuffer.
            // So that it can reduce frame drop and video frames brightness flashing.
            guard sharedImageProcessingContext.alreadyExecuteTime < 1.0 / 40.0 else { break }
        }
        framebufferCache.removeFirst(appendedBufferCount)
    }
    
    func _cacheAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let frameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        audioSampleBufferCache.append(sampleBuffer)
        while let firstBuffer = audioSampleBufferCache.first, CMTimeSubtract(frameTime, CMSampleBufferGetPresentationTimeStamp(firstBuffer)).seconds > cacheBuffersDuration {
//            debugPrint("dropping oldest audio buffer time:\(CMSampleBufferGetPresentationTimeStamp(firstBuffer)).seconds))")
            _ = audioSampleBufferCache.removeFirst()
        }
    }
    
    func _writeAudioSampleBuffers(_ shouldInvalidateSampleWhenDone: Bool) {
        guard state == .writing else { return }
        var appendedBufferCount = 0
        for audioBuffer in audioSampleBufferCache {
            //                        debugPrint("[Caching] appending audio buffer \(i+1)/\(self.audioSampleBufferCache.count) at:\(CMSampleBufferGetOutputPresentationTimeStamp(audioBuffer).seconds)")
            guard movieOutput?._processAudioSampleBuffer(audioBuffer, shouldInvalidateSampleWhenDone: shouldInvalidateSampleWhenDone) == true else { break }
            appendedBufferCount += 1
        }
        audioSampleBufferCache.removeFirst(appendedBufferCount)
    }
    
    func _cacheVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let frameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        videoSampleBufferCache.add(sampleBuffer)
        //            debugPrint("[Caching] cache new video sample buffer at:\(frameTime.seconds)")
        if videoSampleBufferCache.count >= 13 {
            // Be careful of caching too much sample buffers from camera captureOutput. iOS has a hard limit of camera buffer count: 15.
            //                debugPrint("WARNING: almost reach system buffer limit: \(self.videoSampleBufferCache.count)/15")
        }
        while let firstBuffer = videoSampleBufferCache.firstObject, CMTimeSubtract(frameTime, CMSampleBufferGetPresentationTimeStamp(firstBuffer as! CMSampleBuffer)).seconds > cacheBuffersDuration {
//            debugPrint("dropping oldest video buffer time:\(CMSampleBufferGetPresentationTimeStamp(firstBuffer as! CMSampleBuffer).seconds)")
            videoSampleBufferCache.removeObject(at: 0)
        }
    }
    
    private func _writeVideoSampleBuffers(_ shouldInvalidateSampleWhenDone: Bool) {
        guard state == .writing else { return }
        var appendedBufferCount = 0
        // Drain all cached buffers at first
        for sampleBufferObject in videoSampleBufferCache {
            let sampleBuffer = sampleBufferObject as! CMSampleBuffer
            guard movieOutput?._processVideoSampleBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: shouldInvalidateSampleWhenDone) == true else { break }
            appendedBufferCount += 1
        }
        videoSampleBufferCache.removeObjects(in: NSRange(0..<appendedBufferCount))
    }
}
