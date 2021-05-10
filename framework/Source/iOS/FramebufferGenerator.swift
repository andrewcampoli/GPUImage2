//
//  FramebufferGenerator.swift
//  GPUImage2
//
//  Created by 陈品霖 on 2019/8/22.
//

import CoreMedia

public class FramebufferGenerator {
    lazy var yuvConversionShader = _setupShader()
    private(set) var outputSize: GLSize?
    private(set) var pixelBufferPool: CVPixelBufferPool?
    private var renderFramebuffer: Framebuffer?
    
    public init() {
    }
    
    public func generateFromYUVBuffer(_ yuvPixelBuffer: CVPixelBuffer, frameTime: CMTime, videoOrientation: ImageOrientation) -> Framebuffer? {
        var framebuffer: Framebuffer?
        sharedImageProcessingContext.runOperationSynchronously {
            framebuffer = _generateFromYUVBuffer(yuvPixelBuffer, frameTime: frameTime, videoOrientation: videoOrientation)
        }
        return framebuffer
    }
    
    public func convertToPixelBuffer(_ framebuffer: Framebuffer) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        sharedImageProcessingContext.runOperationSynchronously {
            pixelBuffer = _convertToPixelBuffer(framebuffer)
        }
        return pixelBuffer
    }
    
    public func processAndGenerateFromBuffer(_ pixelBuffer: CVPixelBuffer, frameTime: CMTime, processSteps: [PictureInputProcessStep], videoOrientation: ImageOrientation) -> Framebuffer? {
        var framebuffer: Framebuffer?
        sharedImageProcessingContext.runOperationSynchronously {
            framebuffer = _processAndGenerateFromBuffer(pixelBuffer, frameTime: frameTime, processSteps: processSteps, videoOrientation: videoOrientation)
        }
        return framebuffer
    }
}

private extension FramebufferGenerator {
    func _setupShader() -> ShaderProgram? {
        var yuvConversionShader: ShaderProgram?
        sharedImageProcessingContext.runOperationSynchronously {
            yuvConversionShader = crashOnShaderCompileFailure("MoviePlayer") {
                try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2),
                                                                        fragmentShader: YUVConversionFullRangeFragmentShader)
            }
        }
        return yuvConversionShader
    }
    
    func _generateFromYUVBuffer(_ yuvPixelBuffer: CVPixelBuffer, frameTime: CMTime, videoOrientation: ImageOrientation) -> Framebuffer? {
//        let startTime = CACurrentMediaTime()
        guard let yuvConversionShader = yuvConversionShader else {
            debugPrint("ERROR! yuvConversionShader hasn't been setup before starting")
            return nil
        }
        let originalOrientation = videoOrientation.originalOrientation
        let bufferHeight = CVPixelBufferGetHeight(yuvPixelBuffer)
        let bufferWidth = CVPixelBufferGetWidth(yuvPixelBuffer)
        let conversionMatrix = colorConversionMatrix601FullRangeDefault
        CVPixelBufferLockBaseAddress(yuvPixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        defer {
            CVPixelBufferUnlockBaseAddress(yuvPixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
            CVOpenGLESTextureCacheFlush(sharedImageProcessingContext.coreVideoTextureCache, 0)
        }
        
        glActiveTexture(GLenum(GL_TEXTURE0))
        var luminanceGLTexture: CVOpenGLESTexture?
        let luminanceGLTextureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, yuvPixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), 0, &luminanceGLTexture)
        if luminanceGLTextureResult != kCVReturnSuccess || luminanceGLTexture == nil {
            print("Could not create LuminanceGLTexture")
            return nil
        }
        
        let luminanceTexture = CVOpenGLESTextureGetName(luminanceGLTexture!)
        
        glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        let luminanceFramebuffer: Framebuffer
        do {
            luminanceFramebuffer = try Framebuffer(context: sharedImageProcessingContext,
                                                   orientation: originalOrientation,
                                                   size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)),
                                                   textureOnly: true,
                                                   overriddenTexture: luminanceTexture)
        } catch {
            print("Could not create a framebuffer of the size (\(bufferWidth), \(bufferHeight)), error: \(error)")
            return nil
        }
        
        glActiveTexture(GLenum(GL_TEXTURE1))
        var chrominanceGLTexture: CVOpenGLESTexture?
        let chrominanceGLTextureResult = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, yuvPixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), 1, &chrominanceGLTexture)
        
        if chrominanceGLTextureResult != kCVReturnSuccess || chrominanceGLTexture == nil {
            print("Could not create ChrominanceGLTexture")
            return nil
        }
        
        let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceGLTexture!)
        
        glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        let chrominanceFramebuffer: Framebuffer
        do {
            chrominanceFramebuffer = try Framebuffer(context: sharedImageProcessingContext,
                                                     orientation: originalOrientation,
                                                     size: GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight)),
                                                     textureOnly: true,
                                                     overriddenTexture: chrominanceTexture)
        } catch {
            print("Could not create a framebuffer of the size (\(bufferWidth), \(bufferHeight)), error: \(error)")
            return nil
        }
        
        let portraitSize: GLSize
        switch videoOrientation.rotationNeededForOrientation(.portrait) {
        case .noRotation, .rotate180, .flipHorizontally, .flipVertically:
            portraitSize = GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight))
        case .rotateCounterclockwise, .rotateClockwise, .rotateClockwiseAndFlipVertically, .rotateClockwiseAndFlipHorizontally:
            portraitSize = GLSize(width: GLint(bufferHeight), height: GLint(bufferWidth))
        }
        
        let framebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: .portrait, size: portraitSize, textureOnly: false)
        
        convertYUVToRGB(shader: yuvConversionShader,
                        luminanceFramebuffer: luminanceFramebuffer,
                        chrominanceFramebuffer: chrominanceFramebuffer,
                        resultFramebuffer: framebuffer,
                        colorConversionMatrix: conversionMatrix)
        framebuffer.timingStyle = .videoFrame(timestamp: Timestamp(frameTime))
        
//        debugPrint("Generated framebuffer from CVPixelBuffer. time: \(CACurrentMediaTime() - startTime)")
        
        return framebuffer
    }
    
    func _convertToPixelBuffer(_ framebuffer: Framebuffer) -> CVPixelBuffer? {
        if pixelBufferPool == nil || outputSize?.width != framebuffer.size.width || outputSize?.height != framebuffer.size.height {
            outputSize = framebuffer.size
            pixelBufferPool = _createPixelBufferPool(framebuffer.size.width, framebuffer.size.height, FourCharCode(kCVPixelFormatType_32BGRA), 3)
        }
        guard let pixelBufferPool = pixelBufferPool else { return nil }
        var outPixelBuffer: CVPixelBuffer?
        let pixelBufferStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &outPixelBuffer)
        guard let pixelBuffer = outPixelBuffer, pixelBufferStatus == kCVReturnSuccess else {
            print("WARNING: Unable to create pixel buffer, dropping frame")
            return nil
        }
        
        do {
            if renderFramebuffer == nil {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            }
            
            let bufferSize = framebuffer.size
            var cachedTextureRef: CVOpenGLESTexture?
            _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, sharedImageProcessingContext.coreVideoTextureCache, pixelBuffer, nil, GLenum(GL_TEXTURE_2D), GL_RGBA, bufferSize.width, bufferSize.height, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), 0, &cachedTextureRef)
            let cachedTexture = CVOpenGLESTextureGetName(cachedTextureRef!)
            
            renderFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: .portrait, size: bufferSize, textureOnly: false, overriddenTexture: cachedTexture)
            
            renderFramebuffer?.activateFramebufferForRendering()
            clearFramebufferWithColor(Color.black)
            CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
            renderQuadWithShader(sharedImageProcessingContext.passthroughShader, uniformSettings: ShaderUniformSettings(), vertexBufferObject: sharedImageProcessingContext.standardImageVBO, inputTextures: [framebuffer.texturePropertiesForOutputRotation(.noRotation)], context: sharedImageProcessingContext)
            
            glFinish()
        } catch {
            print("WARNING: Trouble appending pixel buffer at time: \(framebuffer.timingStyle.timestamp?.seconds() ?? 0) \(error)")
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        return pixelBuffer
    }
    
    func _processAndGenerateFromBuffer(_ yuvPixelBuffer: CVPixelBuffer, frameTime: CMTime, processSteps: [PictureInputProcessStep], videoOrientation: ImageOrientation) -> Framebuffer? {
//        let startTime = CACurrentMediaTime()
        CVPixelBufferLockBaseAddress(yuvPixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        defer {
            CVPixelBufferUnlockBaseAddress(yuvPixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
            CVOpenGLESTextureCacheFlush(sharedImageProcessingContext.coreVideoTextureCache, 0)
        }
        
        let ciImage = CIImage(cvPixelBuffer: yuvPixelBuffer,
                              options: [.applyOrientationProperty: true,
                                        .properties: [ kCGImagePropertyOrientation: videoOrientation.cgImageOrientation.rawValue ]])
        var processStepsWithCoordinateCorrection = processSteps
        // NOTE: CIImage coordinate is mirrored compared with OpenGLES when calling draw(_:in:size:from:), so it needs to be mirrored before render to OpenGL
        processStepsWithCoordinateCorrection.append(.scale(x: 1, y: -1, anchorPoint: .extentCenter))
        let processedImage = ciImage.processed(with: processStepsWithCoordinateCorrection)
        
//        debugPrint("Process CIImage. time: \(CACurrentMediaTime() - startTime)")
        
        let bufferHeight = Int32(processedImage.extent.height)
        let bufferWidth = Int32(processedImage.extent.width)
        
        let portraitSize: GLSize
        switch videoOrientation.rotationNeededForOrientation(.portrait) {
        case .noRotation, .rotate180, .flipHorizontally, .flipVertically:
            portraitSize = GLSize(width: GLint(bufferWidth), height: GLint(bufferHeight))
        case .rotateCounterclockwise, .rotateClockwise, .rotateClockwiseAndFlipVertically, .rotateClockwiseAndFlipHorizontally:
            portraitSize = GLSize(width: GLint(bufferHeight), height: GLint(bufferWidth))
        }
        
        let framebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation: .portrait, size: portraitSize, textureOnly: false)
        framebuffer.timingStyle = .videoFrame(timestamp: Timestamp(frameTime))
        
        // Bind texture
        framebuffer.activateFramebufferForRendering()
        clearFramebufferWithColor(Color.black)
        glBindTexture(GLenum(GL_TEXTURE_2D), framebuffer.texture)
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLfloat(GL_CLAMP_TO_EDGE))
        glTexParameterf(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLfloat(GL_CLAMP_TO_EDGE))
        
        // TODO: this API performance is slower than Crop filter, improve this later
        CIImage.glBackedContext.draw(processedImage, in: CGRect(origin: .zero, size: processedImage.accurateExtent.rounded(.towardZero).size), from: processedImage.accurateExtent.rounded(.towardZero))
         
//        debugPrint("Reneder CIImage to OpenGL texture. time: \(CACurrentMediaTime() - startTime)")
        
        return framebuffer
    }
    
    func _createPixelBufferPool(_ width: Int32, _ height: Int32, _ pixelFormat: FourCharCode, _ maxBufferCount: Int32) -> CVPixelBufferPool? {
        var outputPool: CVPixelBufferPool?
        
        let sourcePixelBufferOptions: NSDictionary = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                                                      kCVPixelBufferWidthKey: width,
                                                      kCVPixelBufferHeightKey: height,
                                                      kCVPixelFormatOpenGLESCompatibility: true,
                                                      kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true,
                                                      kCVPixelBufferIOSurfaceOpenGLESFBOCompatibilityKey: true,
                                                      kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]
        
        let pixelBufferPoolOptions: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: maxBufferCount]
        
        CVPixelBufferPoolCreate(kCFAllocatorDefault, pixelBufferPoolOptions, sourcePixelBufferOptions, &outputPool)
        
        return outputPool
    }
}

public extension ImageOrientation {
    var originalOrientation: ImageOrientation {
        switch self {
        case .portrait, .portraitUpsideDown:
            return self
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        }
    }
}
