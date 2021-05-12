//
//  PictureProcessor.swift
//  GPUImage2
//
//  Created by 陈品霖 on 2021/5/8.
//

import Foundation

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
    /// Crop to rect. Rect values are from [0, 1] and base on the latest extend rect of the image after previous steps.
    /// **isViewCoordinate** is true indicates zero point is Left-Top corner, false indicates zero point is Left-Bottom corner.
    case crop(rect: CGRect, isViewCoordinate: Bool)
    /// Rotate image by angle (unit: radian)
    case rotation(angle: CGFloat, anchorPoint: AnchorPoint)
    /// Remember the original extent rect, rotate image by angle (unit: radian), scale by ratio, then crop to original extent rect
    case rotateScaleAndKeepRect(angle: CGFloat, scale: CGFloat, anchorPoint: AnchorPoint)
    /// Scale and crop to match target size ratio
    case resizeAspectRatio(size: CGSize, isFill: Bool, allowUpScale: Bool)
}

extension CIImage {
    /// Shared CIContext to improve performance
    static var ciGPUContext = CIContext(eaglContext: sharedImageProcessingContext.context)
    static var ciCPUContext = CIContext()
    
    func processed(with processSteps: [PictureInputProcessStep]?) -> CIImage {
        guard let processSteps = processSteps, !processSteps.isEmpty else { return self }
        var newImage = self
        for step in processSteps {
            switch step {
            case let .scale(x, y, anchorPoint):
                guard x != 1.0 || y != 1.0 else { continue }
                newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                    let transform = CGAffineTransform(scaleX: x, y: y)
                    return $0.accurateTransformed(by: transform)
                }
            case let .crop(rect, isViewCoordinate):
                guard rect.origin != .zero || rect.size != CGSize(width: 1.0, height: 1.0) else { continue }
                // rasterized: [0, 1] -> [0, width/height]
                let adjustedY: CGFloat = isViewCoordinate ? (1.0 - rect.maxY) : rect.minY
                let rasterizedRect = CGRect(x: rect.minX * newImage.accurateExtent.size.width + newImage.accurateExtent.minX,
                                            y: adjustedY * newImage.accurateExtent.size.height + newImage.accurateExtent.minY,
                                            width: rect.size.width * newImage.accurateExtent.size.width,
                                            height: rect.size.height * newImage.accurateExtent.size.height).rounded()
                newImage = newImage.accurateCropped(to: rasterizedRect)
            case let .rotation(angle, anchorPoint):
                guard angle != 0 else { continue }
                newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                    let transform = CGAffineTransform(rotationAngle: angle)
                    return $0.accurateTransformed(by: transform)
                }
            case let .rotateScaleAndKeepRect(angle, scale, anchorPoint):
                guard angle != 0 || scale != 0 else { continue }
                let originExtent = newImage.accurateExtent
                newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                    let transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
                    return $0.accurateTransformed(by: transform)
                }
                newImage = newImage.accurateCropped(to: originExtent)
            case let .resizeAspectRatio(size, isFill, allowUpScale):
                guard size != newImage.accurateExtent.size && size != .zero else { continue }
                // Crop to target size ratio, always use center point as anchor point when cropping
                let targetRect = CGRect(x: newImage.accurateExtent.midX - size.width / 2, y: newImage.accurateExtent.midY - size.height / 2, width: size.width, height: size.height)
                var roundedCroppedUnscaleFrame: CGRect
                // NOTE: this operation needs reverse thinking. Fill: target rect fits original rect. Fit: target rect fill original rect.
                if isFill {
                    roundedCroppedUnscaleFrame = targetRect.fitRect(inside: newImage.accurateExtent).rounded()
                } else {
                    roundedCroppedUnscaleFrame = targetRect.aspectToFill(insideRect: newImage.accurateExtent).rounded()
                }
                newImage = newImage.accurateCropped(to: roundedCroppedUnscaleFrame)
                // Scale to target size if needed
                let scaleRatio = size.width / roundedCroppedUnscaleFrame.width
                if scaleRatio < 1 || allowUpScale {
                    newImage = newImage.accurateTransformed(by: .init(scaleX: scaleRatio, y: scaleRatio))
                }
            }
        }
        return newImage
    }

    func processedWithAnchorPoint(_ anchorPoint: PictureInputProcessStep.AnchorPoint, processes: (CIImage) -> CIImage) -> CIImage {
        switch anchorPoint {
        case .originPoint:
            // Do nothing since it is how CIImage works
            return self
        case .extentCenter:
            let center = CGPoint(x: accurateExtent.midX, y: accurateExtent.midY)
            let anchoredImage = accurateTransformed(by: CGAffineTransform(translationX: -center.x, y: -center.y))
            let processedImage = processes(anchoredImage)
            let anchoreResetImage = processedImage.accurateTransformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            return anchoreResetImage
        case let .custom(point):
            let anchoredImage = accurateTransformed(by: CGAffineTransform(translationX: -point.x, y: -point.y))
            let processedImage = processes(anchoredImage)
            let anchoreResetImage = processedImage.accurateTransformed(by: CGAffineTransform(translationX: point.x, y: point.y))
            return anchoreResetImage
        }
    }
    
    func accurateTransformed(by transform: CGAffineTransform, rounded: Bool = true) -> CIImage {
        let transformedRect = accurateExtent.applying(transform)
        let transformedImage: CIImage
        if rounded && transformedRect.rounded() != transformedRect {
            let sizeRoundedTransform = transform.scaledBy(x: transformedRect.rounded().width / transformedRect.width, y: transformedRect.rounded().height / transformedRect.height)
            let sizeRoundedRect = accurateExtent.applying(sizeRoundedTransform)
            let positionRoundedRect = sizeRoundedRect.rounded(.towardZero)
            let positionRoundedTransform = sizeRoundedTransform.translatedBy(x: positionRoundedRect.minX - sizeRoundedRect.minX,
                                                                             y: positionRoundedRect.minY - sizeRoundedRect.minY)
            transformedImage = transformed(by: positionRoundedTransform)
            transformedImage.accurateExtent = accurateExtent.applying(positionRoundedTransform)
        } else {
            transformedImage = transformed(by: transform)
            transformedImage.accurateExtent = transformedRect
        }
        return transformedImage
    }
    
    func accurateCropped(to rect: CGRect) -> CIImage {
        let croppedImage = cropped(to: rect)
        croppedImage.accurateExtent = croppedImage.extent
        return croppedImage
    }
    
    func renderToCGImage(onGPU: Bool) -> CGImage? {
        return (onGPU ? Self.ciGPUContext : Self.ciCPUContext).createCGImage(self, from: accurateExtent.rounded(.towardZero))
    }
    
    private static var _accurateExtentKey = 0
    
    // NOTE: CIImage.extend will sometimes return an integral rect, so if we want the accurate rect after transforming, we need to apply transform on the original rect
    var accurateExtent: CGRect {
        get { (objc_getAssociatedObject(self, &Self._accurateExtentKey) as? NSValue)?.cgRectValue ?? extent }
        set { objc_setAssociatedObject(self, &Self._accurateExtentKey, NSValue(cgRect: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    // Return the original rect if every number is integral, or it will thrink by 1 point in border
    var trimmedExtent: CGRect {
        let accurateExtent = accurateExtent
        if accurateExtent.integral != accurateExtent {
            return accurateExtent.rounded(.up).insetBy(dx: 1, dy: 1)
        } else {
            return accurateExtent
        }
    }
}

extension CGRect {
    func fitRect(inside rect: CGRect) -> CGRect {
        let scale = min(rect.width / width, rect.height / height)
        let scaledSize = size.applying(CGAffineTransform(scaleX: scale, y: scale))
        let fitX = (rect.width - scaledSize.width) / 2 + rect.minX
        let fitY = (rect.height - scaledSize.height) / 2 + rect.minY
        return CGRect(origin: CGPoint(x: fitX, y: fitY), size: scaledSize)
    }

    func aspectToFill(insideRect boundingRect: CGRect) -> CGRect {
        let widthScale = boundingRect.width / width
        let heightScale = boundingRect.height / height
        let scale = max(widthScale, heightScale)
        var newRect = applying(CGAffineTransform(scaleX: scale, y: scale))
        newRect.origin = CGPoint(x: boundingRect.midX - newRect.size.width / 2, y: boundingRect.midY - newRect.size.height / 2)
        return newRect
    }
    
    func rounded(_ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGRect {
        return CGRect(x: minX.rounded(rule), y: minY.rounded(rule), width: size.width.rounded(rule), height: size.height.rounded(rule))
    }
}
