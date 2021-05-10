import Foundation
import AVFoundation

#if os(Linux)
// For now, disable GCD on Linux and run everything on the main thread

protocol SerialDispatch {
}
    
extension SerialDispatch {
    func runOperationAsynchronously(operation:() -> Void) {
        operation()
    }
    
    func runOperationSynchronously<T>(operation:() throws -> T) rethrows -> T {
        return try operation()
    }
}

#else

public var standardProcessingQueue: DispatchQueue {
    if #available(iOS 10, OSX 10.10, *) {
        return DispatchQueue.global(qos: .default)
    } else {
        return DispatchQueue.global(priority: .default)
    }
}

public var lowProcessingQueue: DispatchQueue {
    if #available(iOS 10, OSX 10.10, *) {
        return DispatchQueue.global(qos: .background)
    } else {
        return DispatchQueue.global(priority: .low)
    }
}

func runAsynchronouslyOnMainQueue(_ mainThreadOperation:@escaping () -> Void) {
    if Thread.isMainThread {
        mainThreadOperation()
    } else {
        DispatchQueue.main.async(execute: mainThreadOperation)
    }
}

func runOnMainQueue(_ mainThreadOperation:() -> Void) {
    if Thread.isMainThread {
        mainThreadOperation()
    } else {
        DispatchQueue.main.sync(execute: mainThreadOperation)
    }
}

func runOnMainQueue<T>(_ mainThreadOperation:() -> T) -> T {
    var returnedValue: T!
    runOnMainQueue {
        returnedValue = mainThreadOperation()
    }
    return returnedValue
}

// MARK: -
// MARK: SerialDispatch extension

public protocol SerialDispatch: class {
    var executeStartTime: TimeInterval? { get set }
    var serialDispatchQueue: DispatchQueue { get }
    var dispatchQueueKey: DispatchSpecificKey<Int> { get }
    var dispatchQueueKeyValue: Int { get }
    func makeCurrentContext()
}

public extension SerialDispatch {
    var alreadyExecuteTime: TimeInterval {
        if let executeStartTime = executeStartTime {
            return CACurrentMediaTime() - executeStartTime
        } else {
            return 0.0
        }
    }
    
    func runOperation(sync: Bool, _ operation:@escaping () -> Void) {
        if sync {
            runOperationSynchronously(operation)
        } else {
            runOperationAsynchronously(operation)
        }
    }
    
    func runOperationAsynchronously(_ operation:@escaping () -> Void) {
        self.serialDispatchQueue.async {
            self.executeStartTime = CACurrentMediaTime()
            self.makeCurrentContext()
            operation()
            self.executeStartTime = nil
        }
    }
    
    func runOperationSynchronously(_ operation:() -> Void) {
        // TODO: Verify this works as intended
        if DispatchQueue.getSpecific(key: self.dispatchQueueKey) == self.dispatchQueueKeyValue {
            operation()
        } else {
            self.serialDispatchQueue.sync {
                self.executeStartTime = CACurrentMediaTime()
                self.makeCurrentContext()
                operation()
                self.executeStartTime = nil
            }
        }
    }
    
    func runOperationSynchronously(_ operation:() throws -> Void) throws {
        var caughtError: Error?
        runOperationSynchronously {
            do {
                try operation()
            } catch {
                caughtError = error
            }
        }
        if caughtError != nil { throw caughtError! }
    }
    
    func runOperationSynchronously<T>(_ operation:() throws -> T) throws -> T {
        var returnedValue: T!
        try runOperationSynchronously {
            returnedValue = try operation()
        }
        return returnedValue
    }

    func runOperationSynchronously<T>(_ operation:() -> T) -> T {
        var returnedValue: T!
        runOperationSynchronously {
            returnedValue = operation()
        }
        return returnedValue
    }
}
#endif
