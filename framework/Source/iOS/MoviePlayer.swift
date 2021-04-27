//
//  MoviePlayer.swift
//  DayCam
//
//  Created by 陈品霖 on 2019/1/30.
//  Copyright © 2019 rocry. All rights reserved.
//
import AVFoundation

public protocol MoviePlayerDelegate: class {
    func moviePlayerDidReadPixelBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime)
}

public typealias MoviePlayerTimeObserverCallback = (CMTime) -> Void

public struct MoviePlayerTimeObserver {
    let targetTime: CMTime
    let callback: MoviePlayerTimeObserverCallback
    let observerID: String
    init(targetTime: CMTime, callback: @escaping MoviePlayerTimeObserverCallback) {
        self.targetTime = targetTime
        self.callback = callback
        observerID = UUID.init().uuidString
    }
}

public class MoviePlayer: AVQueuePlayer, ImageSource {
    static var looperDict = [MoviePlayer: AVPlayerLooper]()
    public let targets = TargetContainer()
    public var runBenchmark = false
    public var logEnabled = false
    public weak var delegate: MoviePlayerDelegate?
    public var startTime: CMTime?
    public var actualStartTime: CMTime { startTime ?? .zero }
    public var endTime: CMTime?
    public var actualEndTime: CMTime { endTime ?? CMTimeSubtract(assetDuration, actualStartTime) }
    public var actualDuration: CMTime { actualEndTime - actualStartTime }
    /// Whether to loop play.
    public var loop = false
    private var previousPlayerActionAtItemEnd: AVPlayer.ActionAtItemEnd?
    public var asset: AVAsset? { return playableItem?.asset }
    public private(set) var isPlaying = false
    public var lastPlayerItem: AVPlayerItem?
    public var playableItem: AVPlayerItem? { currentItem ?? lastPlayerItem }
    
    var displayLink: CADisplayLink?
    
    lazy var framebufferGenerator = FramebufferGenerator()
    
    var totalTimeObservers = [MoviePlayerTimeObserver]()
    var timeObserversQueue = [MoviePlayerTimeObserver]()
    
    var timebaseInfo = mach_timebase_info_data_t()
    var totalFramesSent = 0
    var totalFrameTime: Double = 0.0
    public var dropFrameBeforeTime: CMTime?
    public var playrate: Float = 1.0
    public var assetDuration: CMTime {
        if asset?.statusOfValue(forKey: "duration", error: nil) == .loaded {
            return asset?.duration ?? .zero
        } else {
            return .zero
        }
    }
    public var isReadyToPlay: Bool {
        return status == .readyToPlay
    }
    public var videoOrientation: ImageOrientation {
        guard let asset = asset else { return .portrait }
        return asset.imageOrientation ?? .portrait
    }
    // NOTE: be careful, this property might block your thread since it needs to access currentTime
    public var didPlayToEnd: Bool {
        return currentItem == nil || (currentItem?.currentTime() ?? .zero >= assetDuration)
    }
    public var hasTarget: Bool { targets.count > 0 }
    
    var framebufferUserInfo: [AnyHashable: Any]?
    var observations = [NSKeyValueObservation]()
    
    #if DEBUG
    public var debugRenderInfo: String = ""
    #endif
    
    struct SeekingInfo: Equatable {
        let time: CMTime
        let toleranceBefore: CMTime
        let toleranceAfter: CMTime
        let shouldPlayAfterSeeking: Bool
        
        public static func == (lhs: MoviePlayer.SeekingInfo, rhs: MoviePlayer.SeekingInfo) -> Bool {
            return lhs.time.seconds == rhs.time.seconds
                && lhs.toleranceBefore.seconds == rhs.toleranceBefore.seconds
                && lhs.toleranceAfter.seconds == rhs.toleranceAfter.seconds
                && lhs.shouldPlayAfterSeeking == rhs.shouldPlayAfterSeeking
        }
    }
    var nextSeeking: SeekingInfo?
    public var isSeeking = false
    public var enableVideoOutput = false
    public private(set) var isProcessing = false
    private var needAddItemAfterDidEndNotify = false
    private lazy var pendingNewItems = [AVPlayerItem]()
    private var pendingSeekInfo: SeekingInfo?
    private var shouldUseLooper: Bool {
        // NOTE: if video duration too short, it will cause OOM. So it is better to use "actionItemAtEnd=.none + playToEnd + seek" solution.
        return false
    }
    private var didTriggerEndTimeObserver = false
    private var didRegisterPlayerNotification = false
    private var didNotifyEndedItem: AVPlayerItem?
    private var retryPlaying = false
    /// Return the current item. If currentItem was played to end, will return next one
    public var actualCurrentItem: AVPlayerItem? {
        let playerItems = items()
        guard playerItems.count > 0 else { return nil }
        if didPlayToEnd {
            if playerItems.count == 1 {
                if actionAtItemEnd == .advance {
                    return nil
                } else {
                    return playerItems[0]
                }
            } else {
                return playerItems[1]
            }
        } else {
            return playerItems[0]
        }
    }
    
    public override init() {
        print("[MoviePlayer] init")
        // Make sure player it intialized on the main thread, or it might cause KVO crash
        assert(Thread.isMainThread)
        super.init()
    }
    
    deinit {
        print("[MoviePlayer] deinit \(String(describing: asset))")
        assert(observations.isEmpty, "observers must be removed before deinit")
        pause()
        displayLink?.invalidate()
        if hasTarget {
            sharedImageProcessingContext.framebufferCache.purgeAllUnassignedFramebuffers()
        }
    }
    
    // MARK: Data Source
    public func replaceCurrentItem(with url: URL) {
        replaceCurrentItem(with: url, enableVideoOutput: enableVideoOutput)
    }
    
    public func replaceCurrentItem(with url: URL, enableVideoOutput: Bool) {
        let inputAsset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: inputAsset, automaticallyLoadedAssetKeys: [AVURLAssetPreferPreciseDurationAndTimingKey])
        replaceCurrentItem(with: playerItem, enableVideoOutput: enableVideoOutput)
    }
    
    override public func insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) {
        insert(item, after: afterItem, enableVideoOutput: enableVideoOutput)
    }
    
    public func insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?, enableVideoOutput: Bool) {
        if enableVideoOutput {
            _setupPlayerItemVideoOutput(for: item)
        }
        if item.audioTimePitchAlgorithm == .lowQualityZeroLatency {
            item.audioTimePitchAlgorithm = _audioPitchAlgorithm()
        }
        lastPlayerItem = item
        self.enableVideoOutput = enableVideoOutput
        _setupPlayerObservers(playerItem: item)
        if shouldDelayAddPlayerItem && didNotifyEndedItem != nil && didNotifyEndedItem != item && didNotifyEndedItem != items().last {
            needAddItemAfterDidEndNotify = true
            pendingNewItems.append(item)
            print("[MoviePlayer] pending insert. pendingNewItems:\(pendingNewItems)")
        } else {
            // Append previous pending items at first
            if needAddItemAfterDidEndNotify {
                needAddItemAfterDidEndNotify = false
                pendingNewItems.forEach { insert($0, after: nil) }
                pendingNewItems.removeAll()
            }
            remove(item)
            super.insert(item, after: afterItem)
            print("[MoviePlayer] insert new item(\(item.duration.seconds)s):\(item) afterItem:\(String(describing: afterItem)) enableVideoOutput:\(enableVideoOutput) itemsAfter:\(items().count)")
        }
        didNotifyEndedItem = nil
    }
    
    public func seekItem(_ item: AVPlayerItem, to time: CMTime, toleranceBefore: CMTime = .zero, toleranceAfter: CMTime = .zero, completionHandler: ((Bool) -> Void)? = nil) {
        print("[MoviePlayer] [player] seek item:\(item) to time:\(time.seconds) toleranceBefore:\(toleranceBefore.seconds) toleranceAfter:\(toleranceAfter.seconds)")
        let seekCurrentItem = item == currentItem
        guard !seekCurrentItem || !isSeeking else { return }
        if seekCurrentItem {
            isSeeking = true
            dropFrameBeforeTime = time
            _setupDisplayLinkIfNeeded()
        }
        item.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { [weak self] success in
            if seekCurrentItem {
                self?.isSeeking = false
            }
            completionHandler?(success)
        }
        didNotifyEndedItem = nil
    }
    
    override public func replaceCurrentItem(with item: AVPlayerItem?) {
        replaceCurrentItem(with: item, enableVideoOutput: enableVideoOutput)
    }
    
    public func replaceCurrentItem(with item: AVPlayerItem?, enableVideoOutput: Bool) {
        didNotifyEndedItem = nil
        dropFrameBeforeTime = nil
        lastPlayerItem = item
        // Stop looping before replacing
        if shouldUseLooper && MoviePlayer.looperDict[self] != nil {
            removeAllItems()
        }
        if let item = item {
            if enableVideoOutput {
                _setupPlayerItemVideoOutput(for: item)
            }
            if item.audioTimePitchAlgorithm == .lowQualityZeroLatency {
                item.audioTimePitchAlgorithm = _audioPitchAlgorithm()
            }
            _setupPlayerObservers(playerItem: item)
        } else {
            _removePlayerObservers()
        }
        self.enableVideoOutput = enableVideoOutput
        if shouldDelayAddPlayerItem && item != nil {
            needAddItemAfterDidEndNotify = true
            pendingNewItems.append(item!)
            print("[MoviePlayer] pending replace. pendingNewItems:\(pendingNewItems)")
        } else {
            super.replaceCurrentItem(with: item)
        }
        print("[MoviePlayer] replace current item with newItem(\(item?.duration.seconds ?? 0)s)):\(String(describing: item)) enableVideoOutput:\(enableVideoOutput) itemsAfter:\(items().count) ")
    }
    
    public func replayLastItem() {
        guard let playerItem = lastPlayerItem else { return }
        replaceCurrentItem(with: playerItem)
        if playerItem.currentTime() != actualStartTime {
            seekToTime(actualStartTime, shouldPlayAfterSeeking: true)
        } else {
            play()
        }
        print("[MoviePlayer] replay last item:\(playerItem)")
    }
    
    override public func remove(_ item: AVPlayerItem) {
        super.remove(item)
        pendingNewItems.removeAll { $0 == item }
        print("[MoviePlayer] remove item:\(item)")
    }
    
    override public func removeAllItems() {
        _stopLoopingIfNeeded()
        super.removeAllItems()
        pendingNewItems.removeAll()
        print("[MoviePlayer] remove all items")
    }
    
    override public func advanceToNextItem() {
        super.advanceToNextItem()
        print("[MoviePlayer] advance to next item")
    }
    
    // MARK: -
    // MARK: Playback control
    
    override public func play() {
        if displayLink == nil || didPlayToEnd {
            start()
        } else {
            resume()
        }
    }
    
    override public func playImmediately(atRate rate: Float) {
        playrate = rate
        start()
    }
    
    public func start() {
        if actionAtItemEnd == .advance, currentItem == nil, let playerItem = lastPlayerItem {
            insert(playerItem, after: nil)
        }
        
        guard currentItem != nil else {
            // Sometime the player.items() seems still 0 even if insert was called, but it won't result in crash, just print a error log for information.
            print("[MoviePlayer] ERROR! player currentItem is nil")
            return
        }
        isPlaying = true
        isProcessing = false
//        print("[MoviePlayer] start duration:\(String(describing: asset?.duration.seconds)) items:\(items())")
        _setupDisplayLinkIfNeeded()
        _resetTimeObservers()
        didNotifyEndedItem = nil
        if shouldUseLooper {
            if let playerItem = lastPlayerItem {
                MoviePlayer.looperDict[self]?.disableLooping()
                let looper = AVPlayerLooper(player: self, templateItem: playerItem, timeRange: CMTimeRange(start: actualStartTime, end: actualEndTime))
                MoviePlayer.looperDict[self] = looper
            }
            rate = playrate
        } else {
            if loop {
                actionAtItemEnd = .none
            }
            if currentTime() != actualStartTime {
                seekToTime(actualStartTime, shouldPlayAfterSeeking: true)
            } else {
                rate = playrate
            }
        }
    }
    
    public func resume() {
        isPlaying = true
        rate = playrate
        print("movie player resume \(String(describing: asset))")
    }
    
    override public func pause() {
        isPlaying = false
        guard rate != 0 else { return }
        print("movie player pause \(String(describing: asset))")
        super.pause()
    }
    
    public func stop() {
        pause()
        print("movie player stop \(String(describing: asset))")
        _timeObserversUpdate { [weak self] in
            self?.timeObserversQueue.removeAll()
        }
        displayLink?.invalidate()
        displayLink = nil
        isSeeking = false
        nextSeeking = nil
        dropFrameBeforeTime = nil
        MoviePlayer.looperDict[self]?.disableLooping()
        MoviePlayer.looperDict[self] = nil
    }
    
    public func seekToTime(_ time: TimeInterval, shouldPlayAfterSeeking: Bool) {
        seekToTime(CMTime(seconds: time, preferredTimescale: 48000), shouldPlayAfterSeeking: shouldPlayAfterSeeking)
    }
    
    public func seekToTime(_ targetTime: CMTime, shouldPlayAfterSeeking: Bool) {
        if shouldPlayAfterSeeking {
            // 0.1s has 3 frames tolerance for 30 FPS video, it should be enough if there is no sticky video
            let toleranceTime = CMTime(seconds: 0.1, preferredTimescale: 600)
            isPlaying = true
            nextSeeking = SeekingInfo(time: targetTime, toleranceBefore: toleranceTime, toleranceAfter: toleranceTime, shouldPlayAfterSeeking: shouldPlayAfterSeeking)
        } else {
            nextSeeking = SeekingInfo(time: targetTime, toleranceBefore: .zero, toleranceAfter: .zero, shouldPlayAfterSeeking: shouldPlayAfterSeeking)
        }
        _setupDisplayLinkIfNeeded()
        if assetDuration <= .zero {
            print("[MoviePlayer] cannot seek since assetDuration is 0. currentItem:\(String(describing: currentItem))")
        } else {
            actuallySeekToTime()
        }
    }
    
    /// Cleanup all player resource and observers. This must be called before deinit, or it might crash on iOS 10 due to observation assertion.
    public func cleanup() {
        pendingNewItems.removeAll()
        stop()
        _removePlayerObservers()
    }
    
    func actuallySeekToTime() {
        // Avoid seeking choppy when fast seeking
        // https://developer.apple.com/library/archive/qa/qa1820/_index.html#//apple_ref/doc/uid/DTS40016828    
        guard !isSeeking, let seekingInfo = nextSeeking, isReadyToPlay else { return }
        isSeeking = true
        seek(to: seekingInfo.time, toleranceBefore: seekingInfo.toleranceBefore, toleranceAfter: seekingInfo.toleranceAfter) { [weak self] _ in
//            debugPrint("movie player did seek to time:\(seekingInfo.time.seconds) success:\(success) shouldPlayAfterSeeking:\(seekingInfo.shouldPlayAfterSeeking)")
            guard let self = self else { return }
            if seekingInfo.shouldPlayAfterSeeking && self.isPlaying {
                self._resetTimeObservers()
                self.rate = self.playrate
            }
            
            self.isSeeking = false
            
            if seekingInfo != self.nextSeeking {
                self.actuallySeekToTime()
            } else {
                self.nextSeeking = nil
            }
        }
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // Not needed for movie inputs
    }
    
    public func addTimeObserver(at time: CMTime, callback: @escaping MoviePlayerTimeObserverCallback) -> MoviePlayerTimeObserver {
        let timeObserver = MoviePlayerTimeObserver(targetTime: time, callback: callback)
        _timeObserversUpdate { [weak self] in
            guard let self = self else { return }
            self.totalTimeObservers.append(timeObserver)
            self.totalTimeObservers = self.totalTimeObservers.sorted { lhs, rhs in
                return lhs.targetTime > rhs.targetTime
            }
            if self.isPlaying {
                if let lastIndex = self.timeObserversQueue.firstIndex(where: { $0.targetTime >= time }) {
                    self.timeObserversQueue.insert(timeObserver, at: lastIndex)
                } else {
                    self.timeObserversQueue.append(timeObserver)
                }
            }
        }
        return timeObserver
    }
    
    public func removeTimeObserver(timeObserver: MoviePlayerTimeObserver) {
        _timeObserversUpdate { [weak self] in
            self?.totalTimeObservers.removeAll { $0.observerID == timeObserver.observerID }
            self?.timeObserversQueue.removeAll { $0.observerID == timeObserver.observerID }
        }
    }
    
    public func removeAllTimeObservers() {
        _timeObserversUpdate { [weak self] in
            self?.timeObserversQueue.removeAll()
            self?.totalTimeObservers.removeAll()
        }
    }
    
    public func setLoopEnabled(_ enabled: Bool, timeRange: CMTimeRange) {
        print("MoviePlayer set loop enable: \(enabled) time range: \(timeRange)")
        if enabled {
            if previousPlayerActionAtItemEnd == nil {
                previousPlayerActionAtItemEnd = actionAtItemEnd
            }
            actionAtItemEnd = .none
            startTime = timeRange.start
            endTime = timeRange.end
            assert(timeRange.start >= .zero || timeRange.end > .zero && CMTimeSubtract(timeRange.end, assetDuration) < .zero, "timerange is invalid. timerange:\(timeRange) assetDuration:\(assetDuration)")
        } else {
            actionAtItemEnd = previousPlayerActionAtItemEnd ?? .advance
            startTime = nil
            endTime = nil
        }
        _resetTimeObservers()
        loop = enabled
    }
    
    public func changePlayRate(to rate: Float) {
        let ct = currentTime()
        playrate = rate
        items().forEach {
            if $0.audioTimePitchAlgorithm == .lowQualityZeroLatency {
                $0.audioTimePitchAlgorithm = _audioPitchAlgorithm()
            }
        }
        let toleranceTime = CMTime(seconds: 0.1, preferredTimescale: 600)
        nextSeeking = SeekingInfo(time: ct, toleranceBefore: toleranceTime, toleranceAfter: toleranceTime, shouldPlayAfterSeeking: true)
        resume()
    }
}

private extension MoviePlayer {
    func _setupDisplayLinkIfNeeded() {
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback))
            displayLink?.add(to: RunLoop.main, forMode: .common)
        }
    }
    
    func _stopLoopingIfNeeded() {
        if loop, let looper = MoviePlayer.looperDict[self] {
            looper.disableLooping()
            MoviePlayer.looperDict[self] = nil
            print("[MoviePlayer] stop looping item)")
        }
    }
    
    func _setupPlayerItemVideoOutput(for item: AVPlayerItem) {
        guard !item.outputs.contains(where: { $0 is AVPlayerItemVideoOutput }) else { return }
        let outputSettings = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let videoOutput = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        videoOutput.suppressesPlayerRendering = true
        item.add(videoOutput)
    }
    
    func _setupPlayerObservers(playerItem: AVPlayerItem?) {
        _removePlayerObservers(removeNotificationCenter: !didRegisterPlayerNotification)
        if !didRegisterPlayerNotification {
            NotificationCenter.default.addObserver(self, selector: #selector(playerDidPlayToEnd), name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(playerStalled), name: .AVPlayerItemPlaybackStalled, object: nil)
            didRegisterPlayerNotification = true
        }
        observations.append(observe(\.status) { [weak self] _, _ in
            self?.playerStatusDidChange()
        })
        observations.append(observe(\.rate) { [weak self] _, _ in
            self?.playerRateDidChange()
        })
        if let item = playerItem {
            observations.append(item.observe(\AVPlayerItem.status) { [weak self] _, _ in
                self?.playerItemStatusDidChange(item)
            })
        }
    }
    
    func _removePlayerObservers(removeNotificationCenter: Bool = true) {
        if removeNotificationCenter {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)
            didRegisterPlayerNotification = false
        }
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
    
    /// NOTE: all time observer operations will be executed in main queue
    func _timeObserversUpdate(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async {
                block()
            }
        }
    }
    
    func _resetTimeObservers() {
        didTriggerEndTimeObserver = false
        _timeObserversUpdate { [weak self] in
            guard let self = self else { return }
            self.timeObserversQueue.removeAll()
            for observer in self.totalTimeObservers {
                guard observer.targetTime >= self.actualStartTime && observer.targetTime <= self.actualEndTime else {
                    continue
                }
                self.timeObserversQueue.append(observer)
            }
        }
    }
    
    // Both algorithm has the highest quality
    // Except .spectral has pitch correction, which is suitable for fast/slow play rate
    func _audioPitchAlgorithm() -> AVAudioTimePitchAlgorithm {
        return abs(playrate - 1.0) < .ulpOfOne ? .varispeed : .spectral
    }
    
    func onCurrentItemPlayToEnd() {
        if loop && isPlaying {
            start()
        }
    }
    
    func playerRateDidChange() {
//        debugPrint("rate change to:\(player.rate) asset:\(asset) status:\(player.status.rawValue)")
        resumeIfNeeded()
    }
    
    func playerStatusDidChange() {
        debugPrint("[MoviePlayer] Player status change to:\(status.rawValue) asset:\(String(describing: asset))")
        resumeIfNeeded()
    }
    
    func playerItemStatusDidChange(_ playerItem: AVPlayerItem) {
        debugPrint("[MoviePlayer] PlayerItem status change to:\(playerItem.status.rawValue) asset:\(playerItem.asset), error: \(playerItem.error)")
        if playerItem == currentItem && playerItem.status == .readyToPlay {
            resumeIfNeeded()
        }
    }
    
    func resumeIfNeeded() {
        guard isReadyToPlay && isPlaying == true else { return }
        if nextSeeking != nil {
            actuallySeekToTime()
        } else if rate != playrate {
            rate = playrate
        }
    }
    
    // MARK: -
    // MARK: Internal processing functions
    
    func _process(_ pixelBuffer: CVPixelBuffer, at timeForDisplay: CMTime) {
        // Out of range when looping, skip process. So that it won't show unexpected frames.
        if loop && isPlaying && (timeForDisplay < actualStartTime || timeForDisplay >= actualEndTime) {
            print("[MoviePlayer] Skipped frame at time:\(timeForDisplay.seconds) is larger than range: [\(actualStartTime.seconds), \(actualEndTime.seconds)]")
            return
        }
        
        // There are still some previous frames coming after seeking. So we drop these frames
        if isPlaying, let dropFrameBeforeTime = dropFrameBeforeTime, CMTimeCompare(timeForDisplay, dropFrameBeforeTime) <= 0 {
            print("[MoviePlayer] drop frame at time:\(timeForDisplay.seconds), dropFrameBeforeTime:\(dropFrameBeforeTime.seconds)")
            return
        }
        dropFrameBeforeTime = nil
        
//        print("[MoviePlayer] read frame at time:\(timeForDisplay.seconds)")
        
        delegate?.moviePlayerDidReadPixelBuffer(pixelBuffer, time: timeForDisplay)
        
        let startTime = CACurrentMediaTime()
        if runBenchmark || logEnabled {
            totalFramesSent += 1
        }
        defer {
            if runBenchmark {
                let currentFrameTime = (CACurrentMediaTime() - startTime)
                totalFrameTime += currentFrameTime
                print("[MoviePlayer] Average frame time :\(1000.0 * totalFrameTime / Double(totalFramesSent)) ms")
                print("[MoviePlayer] Current frame time :\(1000.0 * currentFrameTime) ms")
            }
        }
        
        guard hasTarget, let framebuffer = framebufferGenerator.generateFromYUVBuffer(pixelBuffer, frameTime: timeForDisplay, videoOrientation: videoOrientation) else { return }
        framebuffer.userInfo = framebufferUserInfo
        
        #if DEBUG
        debugRenderInfo = """
{
    MoviePlayer: {
        input: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)), input_type: CVPixelBuffer,
        output: \(framebuffer.debugRenderInfo),
        time: \((CACurrentMediaTime() - startTime) * 1000.0)ms
    }
},
"""
        #endif
        
        updateTargetsWithFramebuffer(framebuffer)
    }
    
    @objc func displayLinkCallback(displayLink: CADisplayLink) {
        if !items().isEmpty {
            if retryPlaying {
                retryPlaying = false
                print("[MoviePlayer] Resume playing succeed")
            }
        }
        guard currentItem?.status == .readyToPlay else { return }
        let playTime = currentTime()
        guard playTime.seconds > 0 else { return }
        
        guard let videoOutput = videoOutput else {
            _notifyTimeObserver(with: playTime)
            return
        }
        guard !isProcessing, videoOutput.hasNewPixelBuffer(forItemTime: playTime) == true else { return }
        isProcessing = true
        var timeForDisplay: CMTime = .zero
        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: playTime, itemTimeForDisplay: &timeForDisplay) else {
            print("[MoviePlayer] Failed to copy pixel buffer at time:\(playTime)")
            isProcessing = false
            return
        }
        sharedImageProcessingContext.runOperationAsynchronously { [weak self] in
            defer {
                self?.isProcessing = false
            }
            self?._process(pixelBuffer, at: playTime)
            self?._notifyTimeObserver(with: playTime)
        }
    }
    
    var videoOutput: AVPlayerItemVideoOutput? {
        return currentItem?.outputs.first(where: { $0 is AVPlayerItemVideoOutput }) as? AVPlayerItemVideoOutput
    }
    
    /// Wait for didPlayToEnd notification and add a new playerItem.
    var shouldDelayAddPlayerItem: Bool {
        // NOTE: AVQueuePlayer will remove new added item immediately after inserting if last item has already played to end.
        // The workaround solution is to add new item after playerDidPlayToEnd notification.
        return didPlayToEnd && items().count == 1 && !shouldUseLooper
    }
    
    @objc func playerDidPlayToEnd(notification: Notification) {
        print("[MoviePlayer] did play to end. currentTime:\(currentTime().seconds) notification:\(notification) items:\(items())")
        guard (notification.object as? AVPlayerItem) == currentItem else { return }
        didNotifyEndedItem = currentItem
        if needAddItemAfterDidEndNotify {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.needAddItemAfterDidEndNotify = false
                self.pendingNewItems.forEach { self.insert($0, after: nil) }
                self.pendingNewItems.removeAll()
                if self.isPlaying {
                    self.play()
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onCurrentItemPlayToEnd()
            }
        }
    }
    
    @objc func playerStalled(notification: Notification) {
        print("[MoviePlayer] player was stalled. currentTime:\(currentTime().seconds) notification:\(notification)")
        guard (notification.object as? AVPlayerItem) == currentItem else { return }
    }
    
    func _notifyTimeObserver(with sampleTime: CMTime) {
        // Directly callback time play to end observer since it needs to be callbacked more timely, ex. seeking to start
        if sampleTime > actualEndTime && !shouldUseLooper && endTime != nil && !didTriggerEndTimeObserver {
            didTriggerEndTimeObserver = true
            onCurrentItemPlayToEnd()
        }
        
        // Other observers might has delay since it needs to wait for main thread
        _timeObserversUpdate { [weak self] in
            while let lastObserver = self?.timeObserversQueue.last, lastObserver.targetTime <= sampleTime {
                self?.timeObserversQueue.removeLast()
                lastObserver.callback(sampleTime)
            }
        }
    }
}

public extension AVAsset {
    var imageOrientation: ImageOrientation? {
        guard let videoTrack = tracks(withMediaType: AVMediaType.video).first else {
            return nil
        }
        let trackTransform = videoTrack.preferredTransform
        switch (trackTransform.a, trackTransform.b, trackTransform.c, trackTransform.d) {
        case (1, 0, 0, 1): return .portrait
        case (1, 0, 0, -1), (-1, 0, 0, -1): return .portraitUpsideDown
        case (0, 1, -1, 0): return .landscapeLeft
        case (0, -1, 1, 0): return .landscapeRight
        default:
            print("ERROR: unsupport transform!\(trackTransform)")
            return .portrait
        }
    }
    
    // For original orientation is different with preferred image orientation when it is landscape
    var originalOrientation: ImageOrientation? {
        guard let videoTrack = tracks(withMediaType: AVMediaType.video).first else {
            return nil
        }
        let trackTransform = videoTrack.preferredTransform
        switch (trackTransform.a, trackTransform.b, trackTransform.c, trackTransform.d) {
        case (1, 0, 0, 1): return .portrait
        case (1, 0, 0, -1), (-1, 0, 0, -1): return .portraitUpsideDown
        case (0, 1, -1, 0): return .landscapeRight
        case (0, -1, 1, 0): return .landscapeLeft
        default:
            print("ERROR: unsupport transform!\(trackTransform)")
            return .portrait
        }
    }
}
