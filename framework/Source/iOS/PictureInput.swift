import OpenGLES
import UIKit

/// Operation on input image, which will be translated into CIImage opereation
public enum PictureInputProcessStep {
    public enum AnchorPoint {
        // Default anchor point for CIImage
        case originPoint
        // CIImage.extent.center as anchor point
        case extentCenter
        // Custom anchor point
        case custom(point: CGPoint)
    }
    /// Scale
    case scale(x: CGFloat, y: CGFloat, anchorPoint: AnchorPoint)
    /// Crop to rect. Rect values are from [0, 1] and its base is the lates extend rect of the image after previous steps.
    /// **isViewCoordinate** is true indicates zero point is Left-Top corner, false indicates zero point is Left-Bottom corner.
    case crop(rect: CGRect, isViewCoordinate: Bool)
    /// Rotate image by angle (unit: radian)
    case rotation(angle: CGFloat, anchorPoint: AnchorPoint)
    /// Remember the original extent rect, rotate image by angle (unit: radian), scale by ratio, then crop to original extent rect
    case rotateScaleAndKeepRect(angle: CGFloat, scale: CGFloat, anchorPoint: AnchorPoint)
    /// Resize apsect ratio
    case resizeAspectRatio(size: CGSize, isFill: Bool)
}

public enum PictureInputError: Error, CustomStringConvertible {
    case zeroSizedImageError
    case dataProviderNilError
    case noSuchImageError(imageName: String)
    case createImageError
    
    public var errorDescription: String {
        switch self {
        case .zeroSizedImageError:
            return "Tried to pass in a zero-sized image"
        case .dataProviderNilError:
            return "Unable to retrieve image dataProvider"
        case .noSuchImageError(let imageName):
            return "No such image named: \(imageName) in your application bundle"
        case .createImageError:
            return "Fail to create image"
        }
    }
    
    public var description: String {
        return "<\(type(of: self)): errorDescription = \(self.errorDescription)>"
    }
}

public class PictureInput: ImageSource {
    public let targets = TargetContainer()
    public private(set) var imageFramebuffer: Framebuffer?
    public var framebufferUserInfo: [AnyHashable: Any]?
    public let imageName: String
    var hasProcessedImage: Bool = false
    private static var ciContext = CIContext(options: nil)
    #if DEBUG
    public var printDebugRenderInfos = true
    public var debugRenderInfo: String = ""
    #endif
    
    public init(
        image: CGImage,
        imageName: String? = nil,
        smoothlyScaleOutput: Bool = false,
        orientation: ImageOrientation = .portrait,
        preprocessRenderInfo: String = "") throws {
        #if DEBUG
        let startTime = CACurrentMediaTime()
        defer {
            debugRenderInfo = """
\(preprocessRenderInfo)
{
    PictureInput: {
        input: \(image.width)x\(image.height), input_type: CGImage,
        output: { size: \(imageFramebuffer?.debugRenderInfo ?? "") },
        time: \((CACurrentMediaTime() - startTime) * 1000.0)ms
    }
},
"""
        }
        #endif
        
        self.imageName = imageName ?? "CGImage"
        
        let widthOfImage = GLint(image.width)
        let heightOfImage = GLint(image.height)
        
        // If passed an empty image reference, CGContextDrawImage will fail in future versions of the SDK.
        guard (widthOfImage > 0) && (heightOfImage > 0) else { throw PictureInputError.zeroSizedImageError }
        
        var widthToUseForTexture = widthOfImage
        var heightToUseForTexture = heightOfImage
        var shouldRedrawUsingCoreGraphics = false
        
        // For now, deal with images larger than the maximum texture size by resizing to be within that limit
        let scaledImageSizeToFitOnGPU = GLSize(sharedImageProcessingContext.sizeThatFitsWithinATextureForSize(Size(width: Float(widthOfImage), height: Float(heightOfImage))))
        if (scaledImageSizeToFitOnGPU.width != widthOfImage) && (scaledImageSizeToFitOnGPU.height != heightOfImage) {
            widthToUseForTexture = scaledImageSizeToFitOnGPU.width
            heightToUseForTexture = scaledImageSizeToFitOnGPU.height
            shouldRedrawUsingCoreGraphics = true
        }
        
        if smoothlyScaleOutput {
            // In order to use mipmaps, you need to provide power-of-two textures, so convert to the next largest power of two and stretch to fill
            let powerClosestToWidth = ceil(log2(Float(widthToUseForTexture)))
            let powerClosestToHeight = ceil(log2(Float(heightToUseForTexture)))
            
            widthToUseForTexture = GLint(round(pow(2.0, powerClosestToWidth)))
            heightToUseForTexture = GLint(round(pow(2.0, powerClosestToHeight)))
            shouldRedrawUsingCoreGraphics = true
        }
        
        var imageData: UnsafeMutablePointer<GLubyte>!
        var dataFromImageDataProvider: CFData!
        var format = GL_BGRA
        
        if !shouldRedrawUsingCoreGraphics {
            /* Check that the memory layout is compatible with GL, as we cannot use glPixelStore to
             * tell GL about the memory layout with GLES.
             */
            if (image.bytesPerRow != image.width * 4) || (image.bitsPerPixel != 32) || (image.bitsPerComponent != 8) {
                shouldRedrawUsingCoreGraphics = true
            } else {
                /* Check that the bitmap pixel format is compatible with GL */
                let bitmapInfo = image.bitmapInfo
                if bitmapInfo.contains(.floatComponents) {
                    /* We don't support float components for use directly in GL */
                    shouldRedrawUsingCoreGraphics = true
                } else {
                    let alphaInfo = CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
                    if bitmapInfo.contains(.byteOrder32Little) {
                        /* Little endian, for alpha-first we can use this bitmap directly in GL */
                        if (alphaInfo != CGImageAlphaInfo.premultipliedFirst) && (alphaInfo != CGImageAlphaInfo.first) && (alphaInfo != CGImageAlphaInfo.noneSkipFirst) {
                            shouldRedrawUsingCoreGraphics = true
                        }
                    } else if (bitmapInfo.contains(CGBitmapInfo())) || (bitmapInfo.contains(.byteOrder32Big)) {
                        /* Big endian, for alpha-last we can use this bitmap directly in GL */
                        if (alphaInfo != CGImageAlphaInfo.premultipliedLast) && (alphaInfo != CGImageAlphaInfo.last) && (alphaInfo != CGImageAlphaInfo.noneSkipLast) {
                            shouldRedrawUsingCoreGraphics = true
                        } else {
                            /* Can access directly using GL_RGBA pixel format */
                            format = GL_RGBA
                        }
                    }
                }
            }
        }
        
        try sharedImageProcessingContext.runOperationSynchronously {
            if shouldRedrawUsingCoreGraphics {
                // For resized or incompatible image: redraw
                imageData = UnsafeMutablePointer<GLubyte>.allocate(capacity: Int(widthToUseForTexture * heightToUseForTexture) * 4)
                
                let genericRGBColorspace = CGColorSpaceCreateDeviceRGB()
                
                let imageContext = CGContext(data: imageData, width: Int(widthToUseForTexture), height: Int(heightToUseForTexture), bitsPerComponent: 8, bytesPerRow: Int(widthToUseForTexture) * 4, space: genericRGBColorspace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                //        CGContextSetBlendMode(imageContext, kCGBlendModeCopy); // From Technical Q&A QA1708: http://developer.apple.com/library/ios/#qa/qa1708/_index.html
                imageContext?.draw(image, in: CGRect(x: 0.0, y: 0.0, width: CGFloat(widthToUseForTexture), height: CGFloat(heightToUseForTexture)))
            } else {
                // Access the raw image bytes directly
                guard let data = image.dataProvider?.data else { throw PictureInputError.dataProviderNilError }
                dataFromImageDataProvider = data
                imageData = UnsafeMutablePointer<GLubyte>(mutating: CFDataGetBytePtr(dataFromImageDataProvider))
            }
            
            // TODO: Alter orientation based on metadata from photo
            self.imageFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: orientation, size: GLSize(width: widthToUseForTexture, height: heightToUseForTexture), textureOnly: true)
            self.imageFramebuffer!.lock()
            
            glBindTexture(GLenum(GL_TEXTURE_2D), self.imageFramebuffer!.texture)
            if smoothlyScaleOutput {
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR_MIPMAP_LINEAR)
            }
            
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, widthToUseForTexture, heightToUseForTexture, 0, GLenum(format), GLenum(GL_UNSIGNED_BYTE), imageData)
            
            if smoothlyScaleOutput {
                glGenerateMipmap(GLenum(GL_TEXTURE_2D))
            }
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        }
        
        if shouldRedrawUsingCoreGraphics {
            imageData.deallocate()
        }
        
    }
    
    public convenience init(image: UIImage, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil) throws {
        try self.init(image: image.cgImage!, imageName: "UIImage", smoothlyScaleOutput: smoothlyScaleOutput, orientation: orientation ?? image.imageOrientation.gpuOrientation)
    }
    
    public convenience init(imageName: String, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil) throws {
        guard let image = UIImage(named: imageName) else { throw PictureInputError.noSuchImageError(imageName: imageName) }
        try self.init(image: image.cgImage!, imageName: imageName, smoothlyScaleOutput: smoothlyScaleOutput, orientation: orientation ?? image.imageOrientation.gpuOrientation)
    }
    
    public convenience init(image: UIImage, imageSize: CGSize, renderTargetSize: CGSize, renderTargetOffset: CGPoint, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil) throws {
        #if DEBUG
        let startTime = CACurrentMediaTime()
        #endif
        
        var targetOrientation = orientation ?? image.imageOrientation.gpuOrientation
        var cgImage: CGImage = image.cgImage!
        try autoreleasepool {
            let options: [CIImageOption: Any] = [.applyOrientationProperty: true,
                                                  .properties: [kCGImagePropertyOrientation: image.imageOrientation.cgImageOrientation.rawValue]]
            var newImage = CIImage(cgImage: cgImage, options: options)
            // scale to image size
            let ratioW = imageSize.width / image.size.width
            let ratioH = imageSize.height / image.size.height
            let fillRatio = max(ratioW, ratioH)
            newImage = newImage.scaled(fillRatio, yScale: fillRatio, roundRect: true)
            let displayFrame = CGRect(origin: CGPoint(x: renderTargetOffset.x * imageSize.width, y: renderTargetOffset.y * imageSize.height), size: renderTargetSize)
            // crop image to target display frame
            newImage = newImage.cropped(to: displayFrame)
            guard let newCgImage = PictureInput.ciContext.createCGImage(newImage, from: newImage.extent) else {
                throw PictureInputError.createImageError
            }
            cgImage = newCgImage
            targetOrientation = orientation ?? .portrait
        }
        
        let preprocessRenderInfo: String
        #if DEBUG
        preprocessRenderInfo = """
{
    PictureInput_pre_process : {
        input: {
            size: \(image.size.debugRenderInfo), type: UIImage, imageSize:\(imageSize.debugRenderInfo), renderTargetSize: \(renderTargetSize.debugRenderInfo), renderTargetOffset: \(renderTargetOffset.debugDescription)
        },
        output: { size: \(cgImage.width)x\(cgImage.height), type: CGImage },
        time: \((CACurrentMediaTime() - startTime) * 1000.0)ms
},
"""
        #else
        preprocessRenderInfo = ""
        #endif
        
        try self.init(image: cgImage, imageName: "UIImage", smoothlyScaleOutput: smoothlyScaleOutput, orientation: targetOrientation, preprocessRenderInfo: preprocessRenderInfo)
    }
    
    public convenience init(image: UIImage, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil, processSteps: [PictureInputProcessStep]? = nil) throws {
        #if DEBUG
        let startTime = CACurrentMediaTime()
        #endif
        var targetOrientation = orientation ?? image.imageOrientation.gpuOrientation
        var croppedCGImage: CGImage?
        if let processSteps = processSteps, !processSteps.isEmpty {
            try autoreleasepool {
                // Get CIImage with orientation
                let ciImage: CIImage?
                if let associatedCIImage = image.ciImage {
                    ciImage = associatedCIImage
                } else {
                    ciImage = CIImage(image: image, options: [
                        .applyOrientationProperty: true,
                        .properties: [
                            kCGImagePropertyOrientation: image.imageOrientation.cgImageOrientation.rawValue
                        ]
                    ])
                }
                guard var newImage = ciImage else {
                    throw PictureInputError.createImageError
                }
                
                for step in processSteps {
                    switch step {
                    case let .scale(x, y, anchorPoint):
                        newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                            $0.transformed(by: .init(scaleX: x, y: y))
                        }
                    case let .crop(rect, isViewCoordinate):
                        // rasterized: [0, 1] -> [0, width/height]
                        let adjustedY: CGFloat = isViewCoordinate ? (1.0 - rect.maxY) : rect.origin.y
                        let rasterizedRect = CGRect(x: rect.origin.x * newImage.extent.size.width + newImage.extent.origin.x,
                                                    y: adjustedY * newImage.extent.size.height + newImage.extent.origin.y,
                                                    width: rect.size.width * newImage.extent.size.width,
                                                    height: rect.size.height * newImage.extent.size.height)
                        newImage = newImage.cropped(to: rasterizedRect)
                    case let .rotation(angle, anchorPoint):
                        newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                            $0.transformed(by: .init(rotationAngle: angle))
                        }
                    case let .rotateScaleAndKeepRect(angle, scale, anchorPoint):
                        let originExtent = newImage.extent
                        newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                            $0.transformed(by: .init(rotationAngle: angle))
                                .transformed(by: .init(scaleX: scale, y: scale))
                        }
                        newImage = newImage.cropped(to: originExtent)
                    case let .resizeAspectRatio(size, isFill):
                        let croppedUnscaleFrame: CGRect
                        if isFill {
                            croppedUnscaleFrame = CGRect(x: 0, y: 0, width: size.width, height: size.height).fitRect(inside: newImage.extent)
                        } else {
                            croppedUnscaleFrame = CGRect(x: 0, y: 0, width: size.width, height: size.height).aspectToFill(insideRect: newImage.extent)
                        }
                        let roundedCroppedUnscaleFrame = CGRect(x: croppedUnscaleFrame.origin.x.rounded(.towardZero),
                                                                y: croppedUnscaleFrame.origin.y.rounded(.towardZero),
                                                                width: croppedUnscaleFrame.width.rounded(.towardZero),
                                                                height: croppedUnscaleFrame.height.rounded(.towardZero))
                        newImage = newImage.cropped(to: roundedCroppedUnscaleFrame)
                        let scaleRatio = size.width / roundedCroppedUnscaleFrame.width
                        newImage = newImage.scaled(scaleRatio, yScale: scaleRatio, roundRect: true)
                    }
                }
                
                guard let newCgImage = PictureInput.ciContext.createCGImage(newImage, from: newImage.extent) else {
                    throw PictureInputError.createImageError
                }
                croppedCGImage = newCgImage
                targetOrientation = orientation ?? .portrait
            }
        } else if image.imageOrientation != .up,
                  let ciImage = CIImage(image: image,
                                        options: [.applyOrientationProperty: true,
                                                  .properties: [ kCGImagePropertyOrientation: image.imageOrientation.cgImageOrientation.rawValue ]]),
                  let rotatedImage = PictureInput.ciContext.createCGImage(ciImage, from: ciImage.extent) {
            // Rotated correct orientation
            croppedCGImage = rotatedImage
        } else {
            croppedCGImage = image.cgImage!
        }
        guard let cgImage = croppedCGImage else {
            throw PictureInputError.createImageError
        }
        
        let preprocessRenderInfo: String
        #if DEBUG
        preprocessRenderInfo = """
{
    PictureInput_pre_process : {
        input: {
            size: \(image.size.debugRenderInfo), type: UIImage, processSteps: \(String(describing: processSteps))
        },
        output: { size: \(cgImage.width)x\(cgImage.height), type: CGImage },
        time: \((CACurrentMediaTime() - startTime) * 1000.0)ms
},
"""
        #else
        preprocessRenderInfo = ""
        #endif
        
        try self.init(image: cgImage, imageName: "UIImage", smoothlyScaleOutput: smoothlyScaleOutput, orientation: targetOrientation, preprocessRenderInfo: preprocessRenderInfo)
    }
    
    deinit {
        // debugPrint("Deallocating operation: \(self)")
        
        self.imageFramebuffer?.unlock()
    }
    
    public func processImage(synchronously: Bool = false) {
        self.imageFramebuffer?.userInfo = self.framebufferUserInfo
        
        if synchronously {
            sharedImageProcessingContext.runOperationSynchronously {
                if let framebuffer = self.imageFramebuffer {
                    self.updateTargetsWithFramebuffer(framebuffer)
                    self.hasProcessedImage = true
                }
                #if DEBUG
                if self.printDebugRenderInfos {
                    debugPrint(self.debugGetOnePassRenderInfos())
                }
                #endif
            }
        } else {
            sharedImageProcessingContext.runOperationAsynchronously {
                if let framebuffer = self.imageFramebuffer {
                    self.updateTargetsWithFramebuffer(framebuffer)
                    self.hasProcessedImage = true
                }
                #if DEBUG
                if self.printDebugRenderInfos {
                    debugPrint(self.debugGetOnePassRenderInfos())
                }
                #endif
            }
        }
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // This gets called after the pipline gets adjusted and needs an image it
        // Disabled so we can adjust/prepare the pipline freely without worrying an old framebuffer will get pushed through it
        // If after changing the pipline you need the prior frame buffer to be reprocessed, call processImage() again.
        /*if hasProcessedImage {
            imageFramebuffer.lock()
            target.newFramebufferAvailable(imageFramebuffer, fromSourceIndex:atIndex)
        }*/
    }
}

public extension CGSize {
    func rotatedByOrientation(_ imageOrientation: ImageOrientation) -> CGSize {
        switch imageOrientation {
        case .portrait, .portraitUpsideDown:
            return self
        case .landscapeLeft, .landscapeRight:
            return CGSize(width: height, height: width)
        }
    }
    
    #if DEBUG
    var debugRenderInfo: String { "\(width)x\(height)" }
    #endif
}

extension CGRect {
    fileprivate func fitRect(inside rect: CGRect) -> CGRect {
        let scale = min(rect.width / width, rect.height / height)
        let scaledSize = size.applying(CGAffineTransform(scaleX: scale, y: scale))
        let fitX = (rect.width - scaledSize.width) / 2 + rect.origin.x
        let fitY = (rect.height - scaledSize.height) / 2 + rect.origin.y
        return CGRect(origin: CGPoint(x: fitX, y: fitY), size: scaledSize)
    }

    fileprivate func aspectToFill(insideRect boundingRect: CGRect) -> CGRect {
        let widthScale = boundingRect.width / width
        let heightScale = boundingRect.height / height
        let scale = max(widthScale, heightScale)
        var newRect = applying(CGAffineTransform(scaleX: scale, y: scale))
        newRect.origin = CGPoint(x: boundingRect.midX - newRect.size.width / 2, y: boundingRect.midY - newRect.size.height / 2)
        return newRect
    }
}

private extension CIImage {
    func processedWithAnchorPoint(_ anchorPoint: PictureInputProcessStep.AnchorPoint, processes: (CIImage) -> CIImage) -> CIImage {
        switch anchorPoint {
        case .originPoint:
            // Do nothing since it is how CIImage works
            return self
        case .extentCenter:
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let anchoredImage = transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y))
            let processedImage = processes(anchoredImage)
            let anchoreResetImage = processedImage.transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            return anchoreResetImage
        case let .custom(point):
            let anchoredImage = transformed(by: CGAffineTransform(translationX: -point.x, y: -point.y))
            let processedImage = processes(anchoredImage)
            let anchoreResetImage = processedImage.transformed(by: CGAffineTransform(translationX: point.x, y: point.y))
            return anchoreResetImage
        }
    }
    func scaled(_ xScale: CGFloat, yScale: CGFloat, roundRect: Bool) -> CIImage {
        let scaleTransform = CGAffineTransform(scaleX: xScale, y: yScale)
        // NOTE: CIImage.extend will always return an integral rect, so if we want the accurate rect after transforming, we need to apply transform on the original rect
        let transformedRect = extent.applying(scaleTransform)
        let scaledImage = transformed(by: scaleTransform)
        if roundRect {
            let originRoundedImage = scaledImage.transformed(by: CGAffineTransform(translationX: transformedRect.origin.x.rounded(.towardZero) - transformedRect.origin.x, y: transformedRect.origin.y.rounded(.towardZero) - transformedRect.origin.y))
            return originRoundedImage
        } else {
            return scaledImage
        }
    }
}
