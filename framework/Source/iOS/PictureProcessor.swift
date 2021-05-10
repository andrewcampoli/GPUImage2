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
            case let .resizeAspectRatio(size, isFill, allowUpScale):
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
                if scaleRatio < 1 || allowUpScale {
                    newImage = newImage.scaled(scaleRatio, yScale: scaleRatio, roundRect: true)
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
    
    func renderToCGImage() -> CGImage? {
        return Self.glBackedContext.createCGImage(self, from: extent)
    }
}

fileprivate extension CGRect {
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
}
