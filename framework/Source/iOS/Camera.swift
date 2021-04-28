import Foundation
import AVFoundation

public protocol CameraDelegate: class {
    /// Output original unprocessed sample buffer on AVCaptureDataOutput queue WITHOUT frame drops.
    ///
    /// - Parameters:
    ///   - sampleBuffer: original sample buffer
    /// It should be very lightweight and delay less than 1/FPS secons.
    func didCaptureBufferOnOutputQueue(_ sampleBuffer: CMSampleBuffer)

    /// Output original unprocessed sample buffer on sharedImageProcessing queue WITH frame drops if needed.
    ///
    /// - Parameter sampleBuffer: original sample buffer
    func didCaptureBuffer(_ sampleBuffer: CMSampleBuffer)
}
public enum PhysicalCameraLocation {
    case backFacing
    case frontFacing
    case frontFacingMirrored
    
    // Documentation: "The front-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeLeft and the back-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeRight."
    func imageOrientation() -> ImageOrientation {
        switch self {
            case .backFacing: return .portrait
            case .frontFacing: return .portrait
            case .frontFacingMirrored: return .portrait
        }
    }
    
    public func captureDevicePosition() -> AVCaptureDevice.Position {
        switch self {
            case .backFacing: return .back
            case .frontFacing: return .front
            case .frontFacingMirrored: return .front
        }
    }
    
    public func device(_ type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
        if let matchedDevice = AVCaptureDevice.DiscoverySession(
            deviceTypes: [type],
            mediaType: .video,
            position: captureDevicePosition()).devices.first {
            return matchedDevice
        }

        // Or use default wideAngleCamera
        if let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: captureDevicePosition()).devices.first {
            return device
        }

        // or fallback to old logic
        return AVCaptureDevice.default(for: .video)
    }
}

struct CameraError: Error {
}

let initialBenchmarkFramesToIgnore = 5

public class Camera: NSObject, ImageSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var location: PhysicalCameraLocation {
        didSet {
            if oldValue == location { return }
            configureDeviceInput(location: location, deviceType: deviceType)
        }
    }
    public var runBenchmark: Bool = false
    public var logFPS: Bool = false
    public var audioEncodingTarget: AudioEncodingTarget? {
        didSet {
            guard let audioEncodingTarget = audioEncodingTarget else {
                return
            }
            do {
                try self.addAudioInputsAndOutputs()
                try audioEncodingTarget.activateAudioTrack()
            } catch {
                print("ERROR: Could not connect audio target with error: \(error)")
            }
        }
    }
    
    public private(set) var photoOutput: AVCapturePhotoOutput?
    
    public let targets = TargetContainer()
    public weak var delegate: CameraDelegate?
    public let captureSession: AVCaptureSession
    public var outputBufferSize: GLSize?
    public var inputCamera: AVCaptureDevice!
    public private(set) var videoInput: AVCaptureDeviceInput!
    public let videoOutput: AVCaptureVideoDataOutput!
    public var microphone: AVCaptureDevice?
    public var audioInput: AVCaptureDeviceInput?
    public var audioOutput: AVCaptureAudioDataOutput?
    public var dontDropFrames: Bool = false
    public var deviceType: AVCaptureDevice.DeviceType {
        return inputCamera.deviceType
    }
    public var backCameraStableMode: AVCaptureVideoStabilizationMode? {
        didSet {
            if location == .backFacing {
                configureStabilization()
            }
        }
    }
    public var frontCameraStableMode: AVCaptureVideoStabilizationMode? {
        didSet {
            if location != .backFacing {
                configureStabilization()
            }
        }
    }

    var supportsFullYUVRange: Bool = false
    let captureAsYUV: Bool
    let yuvConversionShader: ShaderProgram?
    let frameRenderingSemaphore = DispatchSemaphore(value: 1)
    let cameraProcessingQueue = DispatchQueue(label: "com.sunsetlakesoftware.GPUImage.cameraProcessingQueue", qos: .default)
    let audioProcessingQueue = DispatchQueue(label: "com.sunsetlakesoftware.GPUImage.audioProcessingQueue", qos: .default)

    let framesToIgnore = 5
    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture: Double = 0.0
    var framesSinceLastCheck = 0
    var lastCheckTime = CACurrentMediaTime()
    
    var captureSessionRestartAttempts = 0
    
    #if DEBUG
    public var debugRenderInfo: String = ""
    #endif

    public init(sessionPreset: AVCaptureSession.Preset, cameraDevice: AVCaptureDevice? = nil, location: PhysicalCameraLocation = .backFacing, captureAsYUV: Bool = true, photoOutput: AVCapturePhotoOutput? = nil, metadataDelegate: AVCaptureMetadataOutputObjectsDelegate? = nil, metadataObjectTypes: [AVMetadataObject.ObjectType]? = nil, deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera) throws {
        debugPrint("camera init")
        
        self.location = location
        self.captureAsYUV = captureAsYUV

        self.captureSession = AVCaptureSession()
        self.captureSession.beginConfiguration()
        captureSession.sessionPreset = sessionPreset

        if let cameraDevice = cameraDevice {
            self.inputCamera = cameraDevice
        } else {
            if let device = location.device(deviceType) {
                self.inputCamera = device
            } else {
                self.videoInput = nil
                self.videoOutput = nil
                self.yuvConversionShader = nil
                self.inputCamera = nil
                super.init()
                throw CameraError()
            }
        }
        
        captureSession.automaticallyConfiguresCaptureDeviceForWideColor = false
        do {
            self.videoInput = try AVCaptureDeviceInput(device: inputCamera)
        } catch {
            self.videoInput = nil
            self.videoOutput = nil
            self.yuvConversionShader = nil
            super.init()
            throw error
        }
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
        
        // Add the video frame output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false

        if captureAsYUV {
            supportsFullYUVRange = false
            #if !targetEnvironment(simulator)
            let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
            for currentPixelFormat in supportedPixelFormats {
                if currentPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                    supportsFullYUVRange = true
                }
            }
            #endif
            
            if supportsFullYUVRange {
                yuvConversionShader = crashOnShaderCompileFailure("Camera") { try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader: YUVConversionFullRangeFragmentShader) }
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            } else {
                yuvConversionShader = crashOnShaderCompileFailure("Camera") { try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader: YUVConversionVideoRangeFragmentShader) }
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            }
        } else {
            yuvConversionShader = nil
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        }

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        if let photoOutput = photoOutput {
            self.photoOutput = photoOutput
            if captureSession.canAddOutput(photoOutput) {
                captureSession.addOutput(photoOutput)
            }
        }
        
        if let metadataDelegate = metadataDelegate, let metadataObjectTypes = metadataObjectTypes, !metadataObjectTypes.isEmpty {
            let captureMetadataOutput = AVCaptureMetadataOutput()
            if captureSession.canAddOutput(captureMetadataOutput) {
                captureSession.addOutput(captureMetadataOutput)
                
                captureMetadataOutput.setMetadataObjectsDelegate(metadataDelegate, queue: cameraProcessingQueue)
                captureMetadataOutput.metadataObjectTypes = metadataObjectTypes
            }
        }
        
        captureSession.sessionPreset = sessionPreset
        
        Camera.updateVideoOutput(location: location, videoOutput: videoOutput)

        captureSession.commitConfiguration()

        super.init()
        
        videoOutput.setSampleBufferDelegate(self, queue: cameraProcessingQueue)
        
        NotificationCenter.default.addObserver(self, selector: #selector(Camera.captureSessionRuntimeError(note:)), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(Camera.captureSessionDidStartRunning(note:)), name: NSNotification.Name.AVCaptureSessionDidStartRunning, object: nil)
    }
    
    public func captureStillImage(delegate: AVCapturePhotoCaptureDelegate, settings: AVCapturePhotoSettings? = nil) {
        guard let photoOutput = photoOutput else {
            fatalError("didn't setup photo output")
        }
        
        let photoSettings = settings ?? AVCapturePhotoSettings()
        
//        photoSettings.isAutoStillImageStabilizationEnabled = photoOutput.isStillImageStabilizationSupported
        
        print("isStillImageStabilizationSupported: \(photoOutput.isStillImageStabilizationSupported), isStillImageStabilizationScene: \(photoOutput.isStillImageStabilizationScene)")
        photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
    }
    
    func configureStabilization() {
        let stableMode = (location == .backFacing ? backCameraStableMode : frontCameraStableMode)
        Camera.updateVideoOutput(location: location, videoOutput: videoOutput, stableMode: stableMode)
    }
    
    public func configureDeviceInput(location: PhysicalCameraLocation, deviceType: AVCaptureDevice.DeviceType, skipConfiguration: Bool = false) {
        guard let device = location.device(deviceType) else {
            fatalError("ERROR: Can't find video devices for \(location)")
        }
        
        do {
            let newVideoInput = try AVCaptureDeviceInput(device: device)
            if !skipConfiguration {
                captureSession.beginConfiguration()
            }
            
            captureSession.removeInput(videoInput)
            if captureSession.canAddInput(newVideoInput) {
                inputCamera = device
                captureSession.addInput(newVideoInput)
                videoInput = newVideoInput
                self.location = location
                configureStabilization()
            } else {
                print("Can't add video input")
                captureSession.addInput(videoInput)
            }
            
            if !skipConfiguration {
                captureSession.commitConfiguration()
            }
        } catch let error {
            fatalError("ERROR: Could not init device: \(error)")
        }
    }
    
    deinit {
        debugPrint("camera deinit")

        let captureSession = self.captureSession
        DispatchQueue.global().async {
            if captureSession.isRunning {
                // Don't call this on the sharedImageProcessingContext otherwise you may get a deadlock
                // since this waits for the captureOutput() delegate call to finish.
                captureSession.stopRunning()
            }
        }
        
        sharedImageProcessingContext.runOperationSynchronously {
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
    }
    
    @objc func captureSessionRuntimeError(note: NSNotification) {
        print("ERROR: Capture session runtime error: \(String(describing: note.userInfo))")
        if self.captureSessionRestartAttempts < 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startCapture()
            }
            self.captureSessionRestartAttempts += 1
        }
    }
    
    @objc func captureSessionDidStartRunning(note: NSNotification) {
        self.captureSessionRestartAttempts = 0
    }
    
    public func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard captureOutput != audioOutput else {
            self.processAudioSampleBuffer(sampleBuffer)
            return
        }
        
        delegate?.didCaptureBufferOnOutputQueue(sampleBuffer)

        let notFrameDrop = dontDropFrames
        
        guard notFrameDrop || (frameRenderingSemaphore.wait(timeout: DispatchTime.now()) == DispatchTimeoutResult.success) else { return }
        
        sharedImageProcessingContext.runOperationAsynchronously {
            defer {
                if !notFrameDrop {
                    self.frameRenderingSemaphore.signal()
                }
            }
            let startTime = CACurrentMediaTime()
            guard let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("Warning: cannot get imageBuffer")
                return
            }
            let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
            let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
            let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            CVPixelBufferLockBaseAddress(cameraFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
            let cameraFramebuffer: Framebuffer
            
            self.delegate?.didCaptureBuffer(sampleBuffer)
            if self.captureAsYUV {
                let luminanceFramebuffer: Framebuffer
                let chrominanceFramebuffer: Framebuffer
                if sharedImageProcessingContext.supportsTextureCaches() {
                    var luminanceTextureRef: CVOpenGLESTexture?
                    _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, cameraFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), 0, &luminanceTextureRef)
                    let luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef!)
                    glActiveTexture(GLenum(GL_TEXTURE4))
                    glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                    luminanceFramebuffer = try! Framebuffer(context: sharedImageProcessingContext, orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)), textureOnly: true, overriddenTexture: luminanceTexture)
                    
                    var chrominanceTextureRef: CVOpenGLESTexture?
                    _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, cameraFrame, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), 1, &chrominanceTextureRef)
                    let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef!)
                    glActiveTexture(GLenum(GL_TEXTURE5))
                    glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
                    chrominanceFramebuffer = try! Framebuffer(context: sharedImageProcessingContext, orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth / 2), height: GLint(bufferHeight / 2)), textureOnly: true, overriddenTexture: chrominanceTexture)
                } else {
                    glActiveTexture(GLenum(GL_TEXTURE4))
                    luminanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)), textureOnly: true)
                    luminanceFramebuffer.lock()
                    
                    glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 0))
                    
                    glActiveTexture(GLenum(GL_TEXTURE5))
                    chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth / 2), height: GLint(bufferHeight / 2)), textureOnly: true)
                    chrominanceFramebuffer.lock()
                    glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 1))
                }
                
                let inputSize = luminanceFramebuffer.sizeForTargetOrientation(.portrait).gpuSize
                let outputSize = self.outputBufferSize ?? luminanceFramebuffer.sizeForTargetOrientation(.portrait)
                let resizeOutput = limitedSizeAndRatio(of: inputSize, to: outputSize.gpuSize)
                cameraFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: .portrait, size: GLSize(resizeOutput.finalCropSize), textureOnly: false)
                
                let conversionMatrix: Matrix3x3
                if self.supportsFullYUVRange {
                    conversionMatrix = colorConversionMatrix601FullRangeDefault
                } else {
                    conversionMatrix = colorConversionMatrix601Default
                }
                convertYUVToRGB(shader: self.yuvConversionShader!, luminanceFramebuffer: luminanceFramebuffer, chrominanceFramebuffer: chrominanceFramebuffer, resizeOutput: resizeOutput, resultFramebuffer: cameraFramebuffer, colorConversionMatrix: conversionMatrix)
            } else {
                cameraFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: self.location.imageOrientation(), size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)), textureOnly: true)
                glBindTexture(GLenum(GL_TEXTURE_2D), cameraFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(cameraFrame))
            }
            CVPixelBufferUnlockBaseAddress(cameraFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
            
            #if DEBUG
            self.debugRenderInfo = """
{
    Camera: {
        input: \(bufferWidth)x\(bufferHeight), input_type: CMSampleBuffer,
        output: { size: \(cameraFramebuffer.debugRenderInfo) },
        time: \((CACurrentMediaTime() - startTime) * 1000.0)ms
    }
},
"""
            #endif
            
            cameraFramebuffer.timingStyle = .videoFrame(timestamp: Timestamp(currentTime))
            self.updateTargetsWithFramebuffer(cameraFramebuffer)
            
            // Clean up after all done
            if self.captureAsYUV && sharedImageProcessingContext.supportsTextureCaches() {
                CVOpenGLESTextureCacheFlush(sharedImageProcessingContext.coreVideoTextureCache, 0)
            }
            
            if self.runBenchmark {
                self.numberOfFramesCaptured += 1
                if self.numberOfFramesCaptured > initialBenchmarkFramesToIgnore {
                    let currentFrameTime = (CACurrentMediaTime() - startTime)
                    self.totalFrameTimeDuringCapture += currentFrameTime
                    print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured - initialBenchmarkFramesToIgnore)) ms")
                    print("Current frame time : \(1000.0 * currentFrameTime) ms")
                }
            }
            
            if self.logFPS {
                if (CACurrentMediaTime() - self.lastCheckTime) > 1.0 {
                    self.lastCheckTime = CACurrentMediaTime()
                    print("FPS: \(self.framesSinceLastCheck)")
                    self.framesSinceLastCheck = 0
                }
                
                self.framesSinceLastCheck += 1
            }
        }
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        debugPrint("dropped a video frame from camera")
    }

    public func startCapture() {
        self.numberOfFramesCaptured = 0
        self.totalFrameTimeDuringCapture = 0
        
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }
    
    public func stopCapture(force: Bool = false) {
        // NOTE: Sometime camera is actually running, but isRunning is false. When it happens, set force to true.
        if captureSession.isRunning || force {
            captureSession.stopRunning()
        }
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // Not needed for camera inputs
    }
    
    // MARK: -
    // MARK: Audio processing
    
    public func addAudioInputsAndOutputs() throws {
        guard audioOutput == nil else { return }
        
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }
        microphone = AVCaptureDevice.default(for: .audio)
        guard let microphone = microphone else { return }
        audioInput = try AVCaptureDeviceInput(device: microphone)
        guard let audioInput = audioInput else { return }
        if captureSession.canAddInput(audioInput) {
           captureSession.addInput(audioInput)
        }
        let output = AVCaptureAudioDataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }
        output.setSampleBufferDelegate(self, queue: audioProcessingQueue)
        audioOutput = output
    }
    
    public func removeAudioInputsAndOutputs() {
        guard audioOutput != nil else { return }
        
        captureSession.beginConfiguration()
        captureSession.removeInput(audioInput!)
        captureSession.removeOutput(audioOutput!)
        audioInput = nil
        audioOutput = nil
        microphone = nil
        captureSession.commitConfiguration()
    }
    
    func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        self.audioEncodingTarget?.processAudioBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: false)
    }
}

private extension Camera {
    static func updateVideoOutput(location: PhysicalCameraLocation, videoOutput: AVCaptureOutput, stableMode: AVCaptureVideoStabilizationMode? = nil) {
        for connection in videoOutput.connections {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = (location == .frontFacingMirrored)
            }
            
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            
            if let stableMode = stableMode, connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stableMode
            }
            
            print("isVideoStabilizationSupported: \(connection.isVideoStabilizationSupported), activeVideoStabilizationMode: \(connection.activeVideoStabilizationMode.rawValue)")
        }
    }
}
