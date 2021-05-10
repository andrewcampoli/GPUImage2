public enum ImageOrientation {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    
    public func rotationNeededForOrientation(_ targetOrientation: ImageOrientation) -> Rotation {
        switch (self, targetOrientation) {
            case (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown), (.landscapeLeft, .landscapeLeft), (.landscapeRight, .landscapeRight): return .noRotation
            case (.portrait, .portraitUpsideDown): return .rotate180
            case (.portraitUpsideDown, .portrait): return .rotate180
            case (.portrait, .landscapeLeft): return .rotateCounterclockwise
            case (.landscapeLeft, .portrait): return .rotateClockwise
            case (.portrait, .landscapeRight): return .rotateClockwise
            case (.landscapeRight, .portrait): return .rotateCounterclockwise
            case (.landscapeLeft, .landscapeRight): return .rotate180
            case (.landscapeRight, .landscapeLeft): return .rotate180
            case (.portraitUpsideDown, .landscapeLeft): return .rotateClockwise
            case (.landscapeLeft, .portraitUpsideDown): return .rotateCounterclockwise
            case (.portraitUpsideDown, .landscapeRight): return .rotateCounterclockwise
            case (.landscapeRight, .portraitUpsideDown): return .rotateClockwise
        }
    }
    
    var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .up
        case .portraitUpsideDown: return .down
        case .landscapeLeft: return .left
        case .landscapeRight: return .right
        }
    }
}

public enum Rotation {
    case noRotation
    case rotateCounterclockwise
    case rotateClockwise
    case rotate180
    case flipHorizontally
    case flipVertically
    case rotateClockwiseAndFlipVertically
    case rotateClockwiseAndFlipHorizontally
    
    public func flipsDimensions() -> Bool {
        switch self {
            case .noRotation, .rotate180, .flipHorizontally, .flipVertically: return false
            case .rotateCounterclockwise, .rotateClockwise, .rotateClockwiseAndFlipVertically, .rotateClockwiseAndFlipHorizontally: return true
        }
    }
}

public extension UIImage.Orientation {
    var gpuOrientation: ImageOrientation {
        switch self {
        case .up, .upMirrored:
            return .portrait
        case .down, .downMirrored:
            return .portraitUpsideDown
        case .left, .leftMirrored:
            return .landscapeLeft
        case .right, .rightMirrored:
            return .landscapeRight
        @unknown default:
            return .portrait
        }
    }
    
    var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
