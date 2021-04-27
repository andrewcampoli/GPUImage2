open class OperationGroup: ImageProcessingOperation {
    public let inputImageRelay = ImageRelay()
    public let outputImageRelay = ImageRelay()
    
    public var sources: SourceContainer { get { return inputImageRelay.sources } }
    public var targets: TargetContainer { get { return outputImageRelay.targets } }
    public let maximumInputs: UInt = 1
    
    #if DEBUG
    public var debugRenderInfo: String = ""
    
    public func debugGetOnePassRenderInfos() -> String {
        return """
{ OperationGroup: \(Self.self), subfilters: \(inputImageRelay.debugGetOnePassRenderInfos())
}
"""
    }
    #endif
    
    public init() {
    }
    
    open func newFramebufferAvailable(_ framebuffer: Framebuffer, fromSourceIndex: UInt) {
        inputImageRelay.newFramebufferAvailable(framebuffer, fromSourceIndex: fromSourceIndex)
    }

    public func configureGroup(_ configurationOperation:(_ input: ImageRelay, _ output: ImageRelay) -> Void) {
        configurationOperation(inputImageRelay, outputImageRelay)
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        outputImageRelay.transmitPreviousImage(to: target, atIndex: atIndex)
    }
}
