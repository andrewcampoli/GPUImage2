// PictureInput isn't defined yet on Linux, so  this operation is inoperable there
#if !os(Linux)
public class LookupFilter: BasicOperation {
    public var intensity: Float = 1.0 {
        didSet {
            if intensity < 0 || intensity > 1.0 {
                assertionFailure("LookupFilter intensity:\(intensity) is out of valid range [0, 1.0]")
                intensity = min(max(intensity, 0), 1.0)
                return
            }
            uniformSettings["intensity"] = intensity
        }
    }
    public var lookupImage: PictureInput? { // TODO: Check for retain cycles in all cases here
        didSet {
            lookupImage?.addTarget(self, atTargetIndex: 1)
            #if DEBUG
            lookupImage?.printDebugRenderInfos = true
            #endif
            lookupImage?.processImage()
        }
    }
    
    public init() {
        super.init(fragmentShader: LookupFragmentShader, numberOfInputs: 2)
        
        ({ intensity = 1.0 })()
    }
}

extension LookupFilter: DebugPipelineNameable {
    public var debugNameForPipeline: String {
        "LookupFilter(\(lookupImage?.imageName ?? "null")/\(intensity))"
    }
}
#endif
