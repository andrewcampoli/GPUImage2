//
//  PictureProcessor.swift
//  GPUImage2
//
//  Created by 陈品霖 on 2021/5/8.
//

import Foundation

extension CIImage {
    /// Shared CIContext to improve performance
    static var glBackedContext = CIContext(eaglContext: sharedImageProcessingContext.context)
    
    func processed(with processSteps: [PictureInputProcessStep]?) -> CIImage {
        guard let processSteps = processSteps, !processSteps.isEmpty else { return self }
        var newImage = self
        for step in processSteps {
            switch step {
            case let .scale(x, y, anchorPoint):
                newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                    let transform = CGAffineTransform(scaleX: x, y: y)
                    return $0.accurateTransformed(by: transform)
                }
            case let .crop(rect, isViewCoordinate):
                // rasterized: [0, 1] -> [0, width/height]
                let adjustedY: CGFloat = isViewCoordinate ? (1.0 - rect.maxY) : rect.origin.y
                let rasterizedRect = CGRect(x: rect.origin.x * newImage.accurateExtent.size.width + newImage.accurateExtent.origin.x,
                                            y: adjustedY * newImage.accurateExtent.size.height + newImage.accurateExtent.origin.y,
                                            width: rect.size.width * newImage.accurateExtent.size.width,
                                            height: rect.size.height * newImage.accurateExtent.size.height).rounded()
                newImage = newImage.accurateCropped(to: rasterizedRect)
            case let .rotation(angle, anchorPoint):
                newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                    let transform = CGAffineTransform(rotationAngle: angle)
                    return $0.accurateTransformed(by: transform)
                }
            case let .rotateScaleAndKeepRect(angle, scale, anchorPoint):
                let originExtent = newImage.accurateExtent
                newImage = newImage.processedWithAnchorPoint(anchorPoint) {
                    let transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
                    return $0.accurateTransformed(by: transform)
                }
                newImage = newImage.accurateCropped(to: originExtent)
            case let .resizeAspectRatio(size, isFill, allowUpScale):
                let roundedCroppedUnscaleFrame: CGRect
                if isFill {
                    roundedCroppedUnscaleFrame = CGRect(x: 0, y: 0, width: size.width, height: size.height).fitRect(inside: newImage.accurateExtent).rounded()
                } else {
                    roundedCroppedUnscaleFrame = CGRect(x: 0, y: 0, width: size.width, height: size.height).aspectToFill(insideRect: newImage.accurateExtent).rounded()
                }
                newImage = newImage.accurateCropped(to: roundedCroppedUnscaleFrame)
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
            let positionRoundedTransform = sizeRoundedTransform.translatedBy(x: positionRoundedRect.origin.x - sizeRoundedRect.origin.x,
                                                                             y: positionRoundedRect.origin.y - sizeRoundedRect.origin.y)
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
    
    func renderToCGImage() -> CGImage? {
        return Self.glBackedContext.createCGImage(self, from: accurateExtent.rounded(.towardZero))
    }
    
    private static var _accurateExtentKey = 0
    
    // NOTE: CIImage.extend will always return an integral rect, so if we want the accurate rect after transforming, we need to apply transform on the original rect
    var accurateExtent: CGRect {
        get { (objc_getAssociatedObject(self, &Self._accurateExtentKey) as? NSValue)?.cgRectValue ?? extent }
        set { objc_setAssociatedObject(self, &Self._accurateExtentKey, NSValue(cgRect: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    // Return the original rect if every number is integral, or it will thrink by 1 point in border
    var trimmedExtent: CGRect {
        let accurateExtent = accurateExtent
        if accurateExtent.integral != accurateExtent {
            return CGRect(x: accurateExtent.origin.x + 1, y: accurateExtent.origin.y + 1, width: accurateExtent.size.width - 2, height: accurateExtent.size.height - 2)
        } else {
            return accurateExtent
        }
    }
}

extension CGRect {
    func fitRect(inside rect: CGRect) -> CGRect {
        let scale = min(rect.width / width, rect.height / height)
        let scaledSize = size.applying(CGAffineTransform(scaleX: scale, y: scale))
        let fitX = (rect.width - scaledSize.width) / 2 + rect.origin.x
        let fitY = (rect.height - scaledSize.height) / 2 + rect.origin.y
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
        return CGRect(x: origin.x.rounded(rule), y: origin.y.rounded(rule), width: size.width.rounded(rule), height: size.height.rounded(rule))
    }
}

fileprivate extension CGAffineTransform {
    func roundedXYTransform(for rect: CGRect) -> CGAffineTransform {
        let transformedRect = rect.applying(self)
        return translatedBy(x: transformedRect.origin.x.rounded(.towardZero) - transformedRect.origin.x, y: transformedRect.origin.y.rounded(.towardZero) - transformedRect.origin.y)
    }
}
