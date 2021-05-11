import AVFoundation

public protocol MovieInputDelegate: class {
    func didFinishMovie()
    func didReadVideoFrame(_ sampleBuffer: CMSampleBuffer)
}

enum MovieInputError: Error {
    case cannotCreateAssetReader
}

public class MovieInput: ImageSource {
    public let targets = TargetContainer()
    public var runBenchmark = false
    
    public weak var delegate: MovieInputDelegate?
    
    public private(set) var audioEncodingTarget: AudioEncodingTarget?
    
    let yuvConversionShader: ShaderProgram
    public let asset: AVAsset
    let videoComposition: AVVideoComposition?
    var playAtActualSpeed: Bool
    
    // Time in the video where it should start. It will be reset when looping.
    var requestedStartTime: CMTime?
    // Time in the video where it should start for trimmed start.
    var trimmedStartTime: CMTime?
    // Time in the video where it started.
    var startTime: CMTime?
    // Duration of the video from startTime for trimming.
    var trimmedDuration: CMTime?
    // Time according to device clock when the video started.
    var actualStartTime: DispatchTime?
    // Last sample time that played.
    private(set) public var currentTime: CMTime?
    
    public var loop: Bool
    public var playrate: Double
    
    // Called after the video finishes. Not called when cancel() or pause() is called.
    public var completion: ((Error?) -> Void)?
    public var startProcessingCallback: (() -> Void)?
    // Progress block of the video with a paramater value of 0-1.
    // Can be used to check video encoding progress. Not called from main thread.
    public var progress: ((Double) -> Void)?
    
    public var synchronizedMovieOutput: MovieOutput? {
        didSet {
            self.enableSynchronizedEncoding()
        }
    }
    public var synchronizedEncodingDebug = false {
        didSet {
            self.synchronizedMovieOutput?.synchronizedEncodingDebug = self.synchronizedEncodingDebug
        }
    }
    let conditionLock = NSCondition()
    var readingShouldWait = false
    var videoInputStatusObserver: NSKeyValueObservation?
    var audioInputStatusObserver: NSKeyValueObservation?
    let maxFPS: Float?
    lazy var framebufferGenerator = FramebufferGenerator()
    
    public var useRealtimeThreads = false
    public var transcodingOnly = false {
        didSet {
            if transcodingOnly, let movieOutput = synchronizedMovieOutput, let transform = asset.tracks(withMediaType: .video).first?.preferredTransform {
                movieOutput.preferredTransform = transform
            }
        }
    }
    var timebaseInfo = mach_timebase_info_data_t()
    var currentThread: Thread?
    
    var totalFramesSent = 0
    var totalFrameTimeDuringCapture: Double = 0.0
    
    var audioSettings: [String: Any]?
    
    var movieFramebuffer: Framebuffer?
    public var framebufferUserInfo: [AnyHashable: Any]?
    public var processSteps: [PictureInputProcessStep]?
    
    #if DEBUG
    public var debugRenderInfo: String = ""
    #endif
    
    // TODO: Someone will have to add back in the AVPlayerItem logic, because I don't know how that works
    public init(asset: AVAsset, videoComposition: AVVideoComposition?, playAtActualSpeed: Bool = false, loop: Bool = false, playrate: Double = 1.0, audioSettings: [String: Any]? = nil, maxFPS: Float? = nil) throws {
        debugPrint("movie input init \(asset)")

        self.asset = asset
        self.videoComposition = videoComposition
        self.playAtActualSpeed = playAtActualSpeed
        self.loop = loop
        self.playrate = playrate
        self.yuvConversionShader = crashOnShaderCompileFailure("MovieInput") { try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader: YUVConversionFullRangeFragmentShader) }
        self.audioSettings = audioSettings
        self.maxFPS = maxFPS
    }

    public convenience init(url: URL, playAtActualSpeed: Bool = false, loop: Bool = false, playrate: Double = 1.0, audioSettings: [String: Any]? = nil) throws {
        let inputOptions = [AVURLAssetPreferPreciseDurationAndTimingKey: NSNumber(value: true)]
        let inputAsset = AVURLAsset(url: url, options: inputOptions)
        try self.init(asset: inputAsset, videoComposition: nil, playAtActualSpeed: playAtActualSpeed, loop: loop, playrate: playrate, audioSettings: audioSettings)
    }
    
    deinit {
        debugPrint("movie input deinit \(asset)")
        
        self.movieFramebuffer?.unlock()
        self.cancel()
        
        self.videoInputStatusObserver?.invalidate()
        self.audioInputStatusObserver?.invalidate()
    }
    
    public var videoOrientation: ImageOrientation {
        return asset.imageOrientation ?? .portrait
    }

    // MARK: -
    // MARK: Playback control
    
    public func start(atTime: CMTime, duration: CMTime? = nil, isTrimming: Bool = false) {
        if !isTrimming {
            requestedStartTime = atTime
        } else {
            trimmedStartTime = atTime
            trimmedDuration = duration
        }
        
        self.start()
    }
    
    @objc public func start() {
        if let currentThread = self.currentThread,
            currentThread.isExecuting,
            !currentThread.isCancelled {
            // If the current thread is running and has not been cancelled, bail.
            return
        }
        // Cancel the thread just to be safe in the event we somehow get here with the thread still running.
        self.currentThread?.cancel()
        
        self.currentThread = Thread(target: self, selector: #selector(beginReading), object: nil)
        self.currentThread?.start()
    }
    
    public func cancel() {
        self.currentThread?.cancel()
        self.currentThread = nil
        (self.audioEncodingTarget as? MovieOutput)?.cancelRecodingImmediately()
        synchronizedEncodingDebugPrint("MovieInput cancel")
    }
    
    public func pause() {
        self.cancel()
        self.requestedStartTime = self.currentTime
        synchronizedEncodingDebugPrint("MovieInput pause")
    }
    
    public func pauseWithoutCancel() {
        requestedStartTime = currentTime
        conditionLock.lock()
        readingShouldWait = true
        conditionLock.unlock()
        synchronizedEncodingDebugPrint("MovieInput pauseWithoutCancel")
    }
    
    public func resume() {
        conditionLock.lock()
        readingShouldWait = false
        conditionLock.signal()
        conditionLock.unlock()
        synchronizedEncodingDebugPrint("MovieInput resume")
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    func createReader() -> AVAssetReader? {
        do {
            let outputSettings: [String: AnyObject] =
                [(kCVPixelBufferPixelFormatTypeKey as String): NSNumber(value: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
            
            let assetReader = try AVAssetReader(asset: self.asset)
            
            try NSObject.catchException {
                if self.videoComposition == nil {
                    let readerVideoTrackOutput = AVAssetReaderTrackOutput(track: self.asset.tracks(withMediaType: .video).first!, outputSettings: outputSettings)
                    readerVideoTrackOutput.alwaysCopiesSampleData = false
                    assetReader.add(readerVideoTrackOutput)
                } else {
                    let readerVideoTrackOutput = AVAssetReaderVideoCompositionOutput(videoTracks: self.asset.tracks(withMediaType: .video), videoSettings: outputSettings)
                    readerVideoTrackOutput.videoComposition = self.videoComposition
                    readerVideoTrackOutput.alwaysCopiesSampleData = false
                    assetReader.add(readerVideoTrackOutput)
                }
                
                if let audioTrack = self.asset.tracks(withMediaType: .audio).first,
                    let _ = self.audioEncodingTarget {
                    let readerAudioTrackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: self.audioSettings)
                    readerAudioTrackOutput.alwaysCopiesSampleData = false
                    assetReader.add(readerAudioTrackOutput)
                }
                
                self.startTime = self.requestedStartTime
                if let startTime = self.requestedStartTime ?? self.trimmedStartTime {
                    if let trimmedDuration = self.trimmedDuration, trimmedDuration.seconds > 0, CMTimeAdd(startTime, trimmedDuration) <= self.asset.duration {
                        assetReader.timeRange = CMTimeRange(start: startTime, duration: trimmedDuration)
                    } else {
                        assetReader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
                    }
                }
            }
            
            self.requestedStartTime = nil
            self.currentTime = nil
            self.actualStartTime = nil
            
            return assetReader
        } catch {
            print("ERROR: Unable to create asset reader: \(error)")
        }
        return nil
    }
    
    @objc func beginReading() {
        if let startProcessingCallback = startProcessingCallback {
            DispatchQueue.main.sync {
                startProcessingCallback()
            }
        }
        
        let thread = Thread.current
        
        mach_timebase_info(&timebaseInfo)
        
        if useRealtimeThreads {
            self.configureThread()
        } else if playAtActualSpeed {
            thread.qualityOfService = .userInitiated
        } else {
             // This includes synchronized encoding since the above vars will be disabled for it.
            thread.qualityOfService = .default
        }
        
        guard let assetReader = self.createReader() else {
            completion?(MovieInputError.cannotCreateAssetReader)
            return // A return statement in this frame will end thread execution.
        }
        
        do {
            try NSObject.catchException {
                guard assetReader.startReading() else {
                    print("ERROR: Unable to start reading: \(String(describing: assetReader.error))")
                    self.completion?(assetReader.error)
                    return
                }
            }
        } catch {
            print("ERROR: Unable to start reading: \(error)")
            completion?(error)
            return
        }
        
        var readerVideoTrackOutput: AVAssetReaderOutput?
        var readerAudioTrackOutput: AVAssetReaderOutput?
        
        for output in assetReader.outputs {
            if output.mediaType == .video {
                readerVideoTrackOutput = output
            }
            if output.mediaType == .audio {
                readerAudioTrackOutput = output
            }
        }
        
        while assetReader.status == .reading {
            if thread.isCancelled { break }
            autoreleasepool {
                if let movieOutput = self.synchronizedMovieOutput {
                    self.conditionLock.lock()
                    if self.readingShouldWait {
                        self.synchronizedEncodingDebugPrint("Disable reading")
                        self.conditionLock.wait()
                        self.synchronizedEncodingDebugPrint("Enable reading")
                    }
                    self.conditionLock.unlock()
                    
                    if movieOutput.assetWriterVideoInput.isReadyForMoreMediaData {
                        self.readNextVideoFrame(with: assetReader, from: readerVideoTrackOutput!)
                    }
                    if movieOutput.assetWriterAudioInput?.isReadyForMoreMediaData ?? false {
                        if let readerAudioTrackOutput = readerAudioTrackOutput {
                            self.readNextAudioSample(with: assetReader, from: readerAudioTrackOutput)
                        }
                    }
                } else {
                    self.readNextVideoFrame(with: assetReader, from: readerVideoTrackOutput!)
                    if let readerAudioTrackOutput = readerAudioTrackOutput,
                        self.audioEncodingTarget?.readyForNextAudioBuffer() ?? true {
                        self.readNextAudioSample(with: assetReader, from: readerAudioTrackOutput)
                    }
                }
            }
        }
        
        assetReader.cancelReading()
        
        let readerPostAction = {
            // Since only the main thread will cancel and create threads jump onto it to prevent
            // the current thread from being cancelled in between the below if statement and creating the new thread.
            DispatchQueue.main.async {
                assetReader.cancelReading()
                
                // Start the video over so long as it wasn't cancelled.
                if self.loop && !thread.isCancelled {
                    self.currentThread = Thread(target: self, selector: #selector(self.beginReading), object: nil)
                    self.currentThread?.start()
                } else {
                    self.synchronizedEncodingDebugPrint("MovieInput finished reading")
                    self.synchronizedEncodingDebugPrint("MovieInput total frames sent: \(self.totalFramesSent)")
                    self.delegate?.didFinishMovie()
                    self.completion?(nil)
                    if thread.isCancelled && self.synchronizedMovieOutput != nil {
                        self.synchronizedMovieOutput?.cancelRecording()
                    }
                }
            }
        }
        
        if synchronizedMovieOutput != nil {
            // Make sure all image processing task is finished when encoding
            sharedImageProcessingContext.runOperationAsynchronously(readerPostAction)
        } else {
            readerPostAction()
        }
    }
    
    func readNextVideoFrame(with assetReader: AVAssetReader, from videoTrackOutput: AVAssetReaderOutput) {
        guard let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() else {
            if let movieOutput = self.synchronizedMovieOutput {
                MovieOutput.movieProcessingContext.runOperationAsynchronously {
                    // Documentation: "Clients that are monitoring each input's readyForMoreMediaData value must call markAsFinished on an input when they are done
                    // appending buffers to it. This is necessary to prevent other inputs from stalling, as they may otherwise wait forever
                    // for that input's media data, attempting to complete the ideal interleaving pattern."
                    movieOutput.markIsFinishedAfterProcessing = true
                }
            }
            return
        }
        
        if delegate != nil {
            sharedImageProcessingContext.runOperationSynchronously { [weak self] in
                self?.delegate?.didReadVideoFrame(sampleBuffer)
            }
        }
        
        var currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        currentTime = currentSampleTime
        
        var duration = asset.duration // Only used for the progress block so its acuracy is not critical
        if let startTime = startTime {
            // Make sure our samples start at kCMTimeZero if the video was started midway.
            currentSampleTime = CMTimeSubtract(currentSampleTime, startTime)
            if let trimmedDuration = trimmedDuration, startTime.seconds > 0, CMTimeAdd(startTime, trimmedDuration) <= duration {
                duration = trimmedDuration
            } else {
                duration = CMTimeSubtract(duration, startTime)
            }
        }
        
        progress?(currentSampleTime.seconds / duration.seconds)
        
        if transcodingOnly, let movieOutput = synchronizedMovieOutput {
            movieOutput.processVideoBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: false)
            return
        }
        
        // NOTE: When calculating frame pre second, floating point maybe rounded, so we have to add tolerance manually
        if let fps = maxFPS, let currentTime = currentTime, (currentSampleTime.seconds - currentTime.seconds) < 1 / Double(fps) - 0.0000001 {
            return
        }
        
        if synchronizedMovieOutput != nil {
            // For synchrozied transcoding, separate AVAssetReader thread and OpenGL thread to improve performance
            sharedImageProcessingContext.runOperationAsynchronously { [weak self] in
                self?.processNextVideoSampleOnGLThread(sampleBuffer, currentSampleTime: currentSampleTime)
                CMSampleBufferInvalidate(sampleBuffer)
            }
        } else {
            processNextVideoSampleOnGLThread(sampleBuffer, currentSampleTime: currentSampleTime)
            CMSampleBufferInvalidate(sampleBuffer)
        }
    }
    
    func processNextVideoSampleOnGLThread(_ sampleBuffer: CMSampleBuffer, currentSampleTime: CMTime) {
        synchronizedEncodingDebugPrint("Process video frame input. Time:\(CMTimeGetSeconds(currentSampleTime))")
        
        if playAtActualSpeed {
            let currentSampleTimeNanoseconds = Int64(currentSampleTime.seconds * 1_000_000_000 / playrate)
            let currentActualTime = DispatchTime.now()
            
            if actualStartTime == nil {
                actualStartTime = currentActualTime
            }
            
            // Determine how much time we need to wait in order to display the frame at the right currentActualTime such that it will match the currentSampleTime.
            // The reason we subtract the actualStartTime from the currentActualTime is so the actual time starts at zero relative to the video start.
            let delay = currentSampleTimeNanoseconds - Int64(currentActualTime.uptimeNanoseconds - actualStartTime!.uptimeNanoseconds)
            
            // print("currentSampleTime: \(currentSampleTimeNanoseconds) currentTime: \((currentActualTime.uptimeNanoseconds-self.actualStartTime!.uptimeNanoseconds)) delay: \(delay)")
            
            if delay > 0 {
                mach_wait_until(mach_absolute_time() + nanosToAbs(UInt64(delay)))
            } else {
                // This only happens if we aren't given enough processing time for playback
                // but is necessary otherwise the playback will never catch up to its timeline.
                // If we weren't adhearing to the sample timline and used the old timing method
                // the video would still lag during an event like this.
                // print("Dropping frame in order to catch up")
                return
            }
        }
        
        sharedImageProcessingContext.runOperationSynchronously {
            self.process(movieFrame: sampleBuffer)
        }
    }
    
    func readNextAudioSample(with assetReader: AVAssetReader, from audioTrackOutput: AVAssetReaderOutput) {
        let shouldInvalidate = !transcodingOnly
        guard let sampleBuffer = audioTrackOutput.copyNextSampleBuffer() else {
            if let movieOutput = self.synchronizedMovieOutput {
                MovieOutput.movieProcessingContext.runOperationAsynchronously {
                    movieOutput.flushPendingAudioBuffers(shouldInvalidateSampleWhenDone: shouldInvalidate)
                    movieOutput.audioEncodingIsFinished = true
                    movieOutput.assetWriterAudioInput?.markAsFinished()
                }
            }
            return
        }
        
        self.synchronizedEncodingDebugPrint("Process audio sample input. Time:\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))")
        
        if synchronizedMovieOutput != nil {
            MovieOutput.movieProcessingContext.runOperationAsynchronously { [weak self] in
                guard let self = self else { return }
                self.audioEncodingTarget?.processAudioBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: shouldInvalidate)
            }
        } else {
            audioEncodingTarget?.processAudioBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: shouldInvalidate)
        }
    }
    
    func process(movieFrame frame: CMSampleBuffer) {
        let currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(frame)
        let movieFrame = CMSampleBufferGetImageBuffer(frame)!
        
        self.process(movieFrame: movieFrame, withSampleTime: currentSampleTime)
    }
    
    func process(movieFrame: CVPixelBuffer, withSampleTime: CMTime) {
        let startTime = CACurrentMediaTime()
        var outputFramebuffer: Framebuffer?
        if let processSteps = processSteps, !processSteps.isEmpty {
            outputFramebuffer = framebufferGenerator.processAndGenerateFromBuffer(movieFrame, frameTime: withSampleTime, processSteps: processSteps, videoOrientation: videoOrientation)
        } else {
            outputFramebuffer = framebufferGenerator.generateFromYUVBuffer(movieFrame, frameTime: withSampleTime, videoOrientation: videoOrientation)
        }
        guard let framebuffer = outputFramebuffer else {
            print("Cannot generate framebuffer from YUVBuffer")
            return
        }
        #if DEBUG
        debugRenderInfo = """
{
    MovieInput: {
        input: \(CVPixelBufferGetWidth(movieFrame))x\(CVPixelBufferGetHeight(movieFrame)), input_type: CVPixelBuffer,
        output: { size: \(framebuffer.debugRenderInfo), time: \((CACurrentMediaTime() - startTime) * 1000.0)ms }
    }
},
"""
        #endif
        framebuffer.userInfo = framebufferUserInfo
        self.movieFramebuffer = framebuffer
        self.updateTargetsWithFramebuffer(framebuffer)
        
        if self.runBenchmark || self.synchronizedEncodingDebug {
            self.totalFramesSent += 1
        }
        
        if self.runBenchmark {
            let currentFrameTime = (CACurrentMediaTime() - startTime)
            self.totalFrameTimeDuringCapture += currentFrameTime
            print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.totalFramesSent)) ms")
            print("Current frame time : \(1000.0 * currentFrameTime) ms")
        }
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // Not needed for movie inputs
    }
    
    public func transmitPreviousFrame() {
        sharedImageProcessingContext.runOperationAsynchronously {
            if let movieFramebuffer = self.movieFramebuffer {
                self.updateTargetsWithFramebuffer(movieFramebuffer)
            }
        }
    }
    
    public func setAudioEncodingTarget(_ target: AudioEncodingTarget?) throws {
        audioEncodingTarget = target
        
        guard let audioEncodingTarget = audioEncodingTarget else {
             return
         }

        try audioEncodingTarget.activateAudioTrack()
         
         // Call enableSynchronizedEncoding() again if they didn't set the audioEncodingTarget before setting synchronizedMovieOutput.
         if synchronizedMovieOutput != nil { self.enableSynchronizedEncoding() }
    }
    
    // MARK: -
    // MARK: Synchronized encoding
    
    func enableSynchronizedEncoding() {
        self.synchronizedMovieOutput?.encodingLiveVideo = false
        self.synchronizedMovieOutput?.synchronizedEncodingDebug = self.synchronizedEncodingDebug
        self.playAtActualSpeed = false
        self.loop = false
        
        // Subscribe to isReadyForMoreMediaData changes
        self.setupObservers()
        // Set the intial state of the lock
        self.updateLock()
    }
    
    func setupObservers() {
        self.videoInputStatusObserver?.invalidate()
        self.audioInputStatusObserver?.invalidate()
        
        guard let movieOutput = self.synchronizedMovieOutput else { return }
        
        self.videoInputStatusObserver = movieOutput.assetWriterVideoInput.observe(\.isReadyForMoreMediaData, options: [.new, .old]) { [weak self] _, _ in
            guard let weakSelf = self else { return }
            weakSelf.updateLock()
        }
        self.audioInputStatusObserver = movieOutput.assetWriterAudioInput?.observe(\.isReadyForMoreMediaData, options: [.new, .old]) { [weak self] _, _ in
            guard let weakSelf = self else { return }
            weakSelf.updateLock()
        }
    }
    
    func updateLock() {
        guard let movieOutput = self.synchronizedMovieOutput else { return }
        
        self.conditionLock.lock()
        // Allow reading if either input is able to accept data, prevent reading if both inputs are unable to accept data.
        if movieOutput.assetWriterVideoInput.isReadyForMoreMediaData || movieOutput.assetWriterAudioInput?.isReadyForMoreMediaData ?? false {
            self.readingShouldWait = false
            self.conditionLock.signal()
        } else {
            self.readingShouldWait = true
        }
        self.conditionLock.unlock()
    }
    
    // MARK: -
    // MARK: Thread configuration
    
    func configureThread() {
        let clock2abs = Double(timebaseInfo.denom) / Double(timebaseInfo.numer) * Double(NSEC_PER_MSEC)
        
        // http://docs.huihoo.com/darwin/kernel-programming-guide/scheduler/chapter_8_section_4.html
        //
        // To see the impact of adjusting these values, uncomment the print statement above mach_wait_until() in self.readNextVideoFrame()
        //
        // Setup for 5 ms of work.
        // The anticpated frame render duration is in the 1-3 ms range on an iPhone 6 for 1080p without filters and 1-7 ms range with filters
        // If the render duration is allowed to exceed 16ms (the duration of a frame in 60fps video)
        // the 60fps video will no longer be playing in real time.
        let computation = UInt32(5 * clock2abs)
        // Tell the scheduler the next 20 ms of work needs to be done as soon as possible.
        let period      = UInt32(0 * clock2abs)
        // According to the above scheduling chapter this constraint only appears relevant
        // if preemtible is set to true and the period is not 0. If this is wrong, please let me know.
        let constraint = UInt32(5 * clock2abs)
        
        // print("period: \(period) computation: \(computation) constraint: \(constraint)")
        
        let THREAD_TIME_CONSTRAINT_POLICY_COUNT = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        
        var policy = thread_time_constraint_policy()
        var ret: Int32
        let thread: thread_port_t = pthread_mach_thread_np(pthread_self())
        
        policy.period = period
        policy.computation = computation
        policy.constraint = constraint
        policy.preemptible = 0
        
        ret = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(THREAD_TIME_CONSTRAINT_POLICY_COUNT)) {
                thread_policy_set(thread, UInt32(THREAD_TIME_CONSTRAINT_POLICY), $0, THREAD_TIME_CONSTRAINT_POLICY_COUNT)
            }
        }
        
        if ret != KERN_SUCCESS {
            mach_error("thread_policy_set:", ret)
            print("Unable to configure thread")
        }
    }
    
    func nanosToAbs(_ nanos: UInt64) -> UInt64 {
        return nanos * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
    }
    
    func synchronizedEncodingDebugPrint(_ string: String) {
        if synchronizedMovieOutput != nil && synchronizedEncodingDebug { print(string) }
    }
}
