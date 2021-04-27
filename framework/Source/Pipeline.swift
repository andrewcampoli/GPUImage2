// MARK: -
// MARK: Basic types
import Foundation

public var _needCheckFilterContainerThread: Bool?

public protocol ImageSource: AnyObject {
    var _needCheckSourceThread: Bool { get }
    #if DEBUG
    var debugRenderInfo: String { get }
    func debugGetOnePassRenderInfos() -> String
    #endif
    var targets: TargetContainer { get }
    func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt)
}

public protocol ImageConsumer: AnyObject {
    var _needCheckConsumerThread: Bool { get }
    #if DEBUG
    var debugRenderInfo: String { get }
    #endif
    var maximumInputs: UInt { get }
    var sources: SourceContainer { get }
    
    func newFramebufferAvailable(_ framebuffer: Framebuffer, fromSourceIndex: UInt)
}

public protocol ImageProcessingOperation: ImageConsumer, ImageSource {
}

infix operator --> : AdditionPrecedence
// precedencegroup ProcessingOperationPrecedence {
//    associativity: left
////    higherThan: Multiplicative
// }
@discardableResult public func --><T: ImageConsumer>(source: ImageSource, destination: T) -> T {
    source.addTarget(destination)
    return destination
}

// MARK: -
// MARK: Extensions and supporting types

public extension ImageSource {
    var _needCheckSourceThread: Bool {
        return _needCheckFilterContainerThread ?? true
    }
    
    func addTarget(_ target: ImageConsumer, atTargetIndex: UInt? = nil) {
        if _needCheckSourceThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        if let targetIndex = atTargetIndex {
            target.setSource(self, atIndex: targetIndex)
            targets.append(target, indexAtTarget: targetIndex)
            sharedImageProcessingContext.runOperationAsynchronously {
                self.transmitPreviousImage(to: target, atIndex: targetIndex)
            }
        } else if let indexAtTarget = target.addSource(self) {
            targets.append(target, indexAtTarget: indexAtTarget)
            sharedImageProcessingContext.runOperationAsynchronously {
                self.transmitPreviousImage(to: target, atIndex: indexAtTarget)
            }
        } else {
            debugPrint("Warning: tried to add target beyond target's input capacity")
        }
    }

    func removeAllTargets() {
        if _needCheckSourceThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        for (target, index) in targets {
            target.removeSourceAtIndex(index)
        }
        targets.removeAll()
    }
    
    func remove(_ target: ImageConsumer) {
        if _needCheckSourceThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        for (testTarget, index) in targets {
            if target === testTarget {
                target.removeSourceAtIndex(index)
                targets.remove(target)
            }
        }
    }
    
    func updateTargetsWithFramebuffer(_ framebuffer: Framebuffer) {
        var foundTargets = [(ImageConsumer, UInt)]()
        for target in targets {
            foundTargets.append(target)
        }
        
        if foundTargets.count == 0 { // Deal with the case where no targets are attached by immediately returning framebuffer to cache
            framebuffer.lock()
            framebuffer.unlock()
        } else {
            // Lock first for each output, to guarantee proper ordering on multi-output operations
            for _ in foundTargets {
                framebuffer.lock()
            }
        }
        for (target, index) in foundTargets {
            target.newFramebufferAvailable(framebuffer, fromSourceIndex: index)
        }
    }
    
    #if DEBUG
    func debugGetOnePassRenderInfos() -> String {
        var renderInfos = ""
        renderInfos.append(debugRenderInfo)
        for target in targets {
            if let source = target.0 as? ImageSource {
                renderInfos.append(source.debugGetOnePassRenderInfos())
            } else {
                renderInfos.append(target.0.debugRenderInfo)
            }
        }
        return renderInfos
    }
    #endif
}

public extension ImageConsumer {
    var _needCheckConsumerThread: Bool {
        return _needCheckFilterContainerThread ?? true
    }
    
    func addSource(_ source: ImageSource) -> UInt? {
        if _needCheckConsumerThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        return sources.append(source, maximumInputs: maximumInputs)
    }
    
    func setSource(_ source: ImageSource, atIndex: UInt) {
        if _needCheckConsumerThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        _ = sources.insert(source, atIndex: atIndex, maximumInputs: maximumInputs)
    }

    func removeSourceAtIndex(_ index: UInt) {
        if _needCheckConsumerThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        sources.removeAtIndex(index)
    }
    
    func removeAllSources() {
        if _needCheckConsumerThread {
            __dispatch_assert_queue(sharedImageProcessingContext.serialDispatchQueue)
        }
        sources.sources.removeAll()
    }
    
    func flushWithTinyBuffer(in context: OpenGLContext = sharedImageProcessingContext) {
        context.runOperationSynchronously {
            do {
                for index in 0..<maximumInputs {
                    let framebuffer = try Framebuffer(context: context, orientation: .portrait, size: GLSize(width: 1, height: 1))
                    newFramebufferAvailable(framebuffer, fromSourceIndex: index)
                }
            } catch {
                print("Failed to flush 1x1 framebuffer with error:\(error)")
            }
            context.framebufferCache.purgeAllUnassignedFramebuffers(sync: true)
        }
    }
}

class WeakImageConsumer {
    weak var value: ImageConsumer?
    let indexAtTarget: UInt
    init (value: ImageConsumer, indexAtTarget: UInt) {
        self.indexAtTarget = indexAtTarget
        self.value = value
    }
}

public class TargetContainer: Sequence {
    private var targets = [WeakImageConsumer]()
    
    public var count: Int { get { return targets.count } }

#if !os(Linux)
    let dispatchQueue = DispatchQueue(label: "com.sunsetlakesoftware.GPUImage.targetContainerQueue", attributes: [])
#endif

    public init() {
    }
    
    public func append(_ target: ImageConsumer, indexAtTarget: UInt) {
        // TODO: Don't allow the addition of a target more than once
#if os(Linux)
            self.targets.append(WeakImageConsumer(value: target, indexAtTarget: indexAtTarget))
#else
        dispatchQueue.async {
            self.targets.append(WeakImageConsumer(value: target, indexAtTarget: indexAtTarget))
        }
#endif
    }
    
    public func makeIterator() -> AnyIterator<(ImageConsumer, UInt)> {
        var index = 0
        
        return AnyIterator { () -> (ImageConsumer, UInt)? in
#if os(Linux)
                if index >= self.targets.count {
                    return nil
                }
                
                // NOTE: strong retain value, in case the value is released on another thread
                var retainedValue = self.targets[index].value
                while retainedValue == nil {
                    self.targets.remove(at: index)
                    if index >= self.targets.count {
                        return nil
                    }
                    retainedValue = self.targets[index].value
                }
                
                index += 1
                return (retainedValue!, self.targets[index - 1].indexAtTarget)
#else
            return self.dispatchQueue.sync {
                if index >= self.targets.count {
                    return nil
                }
                
                // NOTE: strong retain value, in case the value is released on another thread
                var retainedValue = self.targets[index].value
                while retainedValue == nil {
                    self.targets.remove(at: index)
                    if index >= self.targets.count {
                        return nil
                    }
                    retainedValue = self.targets[index].value
                }
                
                index += 1
                return (retainedValue!, self.targets[index - 1].indexAtTarget)
            }
#endif
        }
    }
    
    public func removeAll() {
#if os(Linux)
            self.targets.removeAll()
#else
        dispatchQueue.async {
            self.targets.removeAll()
        }
#endif
    }
    
    public func remove(_ target: ImageConsumer) {
        #if os(Linux)
            self.targets = self.targets.filter { $0.value !== target }
        #else
            dispatchQueue.async {
                self.targets = self.targets.filter { $0.value !== target }
            }
        #endif
    }
}

public class SourceContainer {
    public var sources: [UInt: ImageSource] = [:]
    
    public init() {
    }
    
    public func append(_ source: ImageSource, maximumInputs: UInt) -> UInt? {
        var currentIndex: UInt = 0
        while currentIndex < maximumInputs {
            if sources[currentIndex] == nil {
                sources[currentIndex] = source
                return currentIndex
            }
            currentIndex += 1
        }
        
        return nil
    }
    
    public func insert(_ source: ImageSource, atIndex: UInt, maximumInputs: UInt) -> UInt {
        guard atIndex < maximumInputs else { fatalError("ERROR: Attempted to set a source beyond the maximum number of inputs on this operation") }
        sources[atIndex] = source
        return atIndex
    }
    
    public func removeAtIndex(_ index: UInt) {
        sources[index] = nil
    }
}

public class ImageRelay: ImageProcessingOperation {
    public var newImageCallback: ((Framebuffer) -> Void)?
    
    public let sources = SourceContainer()
    public let targets = TargetContainer()
    public let maximumInputs: UInt = 1
    public var preventRelay: Bool = false
    
    public init() {
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        guard sources.sources.count > 0 else { return }
        sources.sources[0]?.transmitPreviousImage(to: self, atIndex: 0)
    }

    public func newFramebufferAvailable(_ framebuffer: Framebuffer, fromSourceIndex: UInt) {
        if let newImageCallback = newImageCallback {
            newImageCallback(framebuffer)
        }
        if !preventRelay {
            relayFramebufferOnward(framebuffer)
        }
    }
    
    public func relayFramebufferOnward(_ framebuffer: Framebuffer) {
        // Need to override to guarantee a removal of the previously applied lock
        for _ in targets {
            framebuffer.lock()
        }
        framebuffer.unlock()
        for (target, index) in targets {
            target.newFramebufferAvailable(framebuffer, fromSourceIndex: index)
        }
    }
    
    #if DEBUG
    public var debugRenderInfo: String = ""
    #endif
}

public protocol DebugPipelineNameable {
    var debugNameForPipeline: String { get }
}

private func simpleName<T>(_ obj: T) -> String {
    if let obj = obj as? DebugPipelineNameable {
        return obj.debugNameForPipeline
    }

    let origin = String(describing: obj)
    return origin.split(separator: ".").last.map { String($0) } ?? origin
}

extension OperationGroup {
    public var debugPipelineDescription: String {
        // if group have custom name, do not use relay.description
        if let obj = self as? DebugPipelineNameable {
            return obj.debugNameForPipeline
        }

        return "[\(simpleName(self))(\(inputImageRelay.debugPipelineDescription))]"
    }
}

public extension ImageSource {
    var debugPipelineDescription: String {
        let nextInfos: [String] = targets.map { consumer, _ in
            if let c = consumer as? OperationGroup {
                return c.debugPipelineDescription
            }

            if let c = consumer as? ImageRelay {
                return c.debugPipelineDescription
            }

            if let c = consumer as? ImageSource {
                return c.debugPipelineDescription
            }

            return simpleName(consumer)
        }
        let nextInfosText = nextInfos.joined(separator: " -> ")

        if self is ImageRelay {
            return nextInfosText
        }

        return "\(simpleName(self)) -> \(nextInfosText)"
    }
}

#if DEBUG
public extension ImageSource {
    var debugPipelineNext: String {
        let nextInfos: [String] = targets.map {
            if let operationGroup = $0.0 as? OperationGroup {
                return operationGroup.inputImageRelay.debugPipelineNext
            } else if let operation = $0.0 as? ImageProcessingOperation {
                return operation.debugPipelineNext
            } else {
                return $0.0.debugPipelineEnd
            }
        }
        return "{'\(self)':[\(nextInfos.joined(separator: ","))]}"
    }
}

public extension ImageConsumer {
    var debugPipelineEnd: String {
        return "'\(self)'"
    }
}
#endif
