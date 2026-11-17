import AppKit
import Foundation
import ObjectiveC.runtime

/// Self-check-only instrumentation. It counts NSTextView instances passing
/// through AppKit's standard initializers, and attaches a sentinel to each one so
/// destruction is counted when the actual view is released. The probe is
/// installed only while an offline check runs, then restores both methods.
/// An override that bypasses these initializers is outside this boundary; the
/// positive control exercises both stock and app subclasses.
final class TextViewLifecycleProbe {
    struct Counts {
        let created: Int
        let destroyed: Int
        let byClass: [String: Int]
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var created = 0
        private var destroyed = 0
        private var byClass: [String: Int] = [:]

        func made(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            created += 1
            byClass[name, default: 0] += 1
        }
        func freed() {
            lock.lock(); defer { lock.unlock() }
            destroyed += 1
        }
        func snapshot() -> Counts {
            lock.lock(); defer { lock.unlock() }
            return Counts(created: created, destroyed: destroyed, byClass: byClass)
        }
    }

    private final class Sentinel {
        let counter: Counter
        init(_ counter: Counter) { self.counter = counter }
        deinit { counter.freed() }
    }

    private nonisolated(unsafe) static var associationKey: UInt8 = 0
    private let counter = Counter()
    private var originals: [(Method, IMP)] = []
    private var replacements: [IMP] = []

    func snapshot() -> Counts { counter.snapshot() }

    private static func track(_ pointer: UnsafeMutableRawPointer?, counter: Counter) {
        guard let pointer else { return }
        let view = Unmanaged<NSTextView>.fromOpaque(pointer).takeUnretainedValue()
        guard objc_getAssociatedObject(view, &associationKey) == nil else { return }
        counter.made(NSStringFromClass(type(of: view)))
        objc_setAssociatedObject(view, &associationKey, Sentinel(counter), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Returns false when AppKit does not expose the expected methods, rather
    /// than reporting a misleading zero. Run only on the main thread.
    @MainActor func install() -> Bool {
        guard originals.isEmpty else { return false }
        typealias InitImp = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias CoderImp = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        typealias FrameImp = @convention(c) (UnsafeMutableRawPointer, Selector, NSRect) -> UnsafeMutableRawPointer?
        typealias ContainerImp = @convention(c) (UnsafeMutableRawPointer, Selector, NSRect, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        let klass: AnyClass = NSTextView.self
        let initSel = NSSelectorFromString("init")
        let coderSel = NSSelectorFromString("initWithCoder:")
        let frameSel = NSSelectorFromString("initWithFrame:")
        let containerSel = NSSelectorFromString("initWithFrame:textContainer:")
        guard let initMethod = class_getInstanceMethod(klass, initSel),
              let coderMethod = class_getInstanceMethod(klass, coderSel),
              let initTypes = method_getTypeEncoding(initMethod),
              let coderTypes = method_getTypeEncoding(coderMethod),
              let frameMethod = class_getInstanceMethod(klass, frameSel),
              let containerMethod = class_getInstanceMethod(klass, containerSel),
              let frameTypes = method_getTypeEncoding(frameMethod),
              let containerTypes = method_getTypeEncoding(containerMethod) else { return false }
        let initOriginal = method_getImplementation(initMethod)
        let coderOriginal = method_getImplementation(coderMethod)
        let frameOriginal = method_getImplementation(frameMethod)
        let containerOriginal = method_getImplementation(containerMethod)
        let originalInit = unsafeBitCast(initOriginal, to: InitImp.self)
        let originalCoder = unsafeBitCast(coderOriginal, to: CoderImp.self)
        let originalFrame = unsafeBitCast(frameOriginal, to: FrameImp.self)
        let originalContainer = unsafeBitCast(containerOriginal, to: ContainerImp.self)
        let counter = self.counter
        let initBlock: @convention(block) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { receiver in
            let result = originalInit(receiver, initSel)
            Self.track(result, counter: counter)
            return result
        }
        let coderBlock: @convention(block) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { receiver, coder in
            let result = originalCoder(receiver, coderSel, coder)
            Self.track(result, counter: counter)
            return result
        }
        let frameBlock: @convention(block) (UnsafeMutableRawPointer, NSRect) -> UnsafeMutableRawPointer? = { receiver, rect in
            let result = originalFrame(receiver, frameSel, rect)
            Self.track(result, counter: counter)
            return result
        }
        let containerBlock: @convention(block) (UnsafeMutableRawPointer, NSRect, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { receiver, rect, container in
            let result = originalContainer(receiver, containerSel, rect, container)
            Self.track(result, counter: counter)
            return result
        }
        let initReplacement = imp_implementationWithBlock(initBlock)
        let coderReplacement = imp_implementationWithBlock(coderBlock)
        let frameReplacement = imp_implementationWithBlock(frameBlock)
        let containerReplacement = imp_implementationWithBlock(containerBlock)
        // An inherited selector must be overridden on NSTextView, not replaced
        // on NSView where it would intercept every view in the check.
        if !class_addMethod(klass, initSel, initReplacement, initTypes) {
            _ = method_setImplementation(initMethod, initReplacement)
        }
        if !class_addMethod(klass, coderSel, coderReplacement, coderTypes) {
            _ = method_setImplementation(coderMethod, coderReplacement)
        }
        if !class_addMethod(klass, frameSel, frameReplacement, frameTypes) {
            _ = method_setImplementation(frameMethod, frameReplacement)
        }
        if !class_addMethod(klass, containerSel, containerReplacement, containerTypes) {
            _ = method_setImplementation(containerMethod, containerReplacement)
        }
        guard let installedInit = class_getInstanceMethod(klass, initSel),
              let installedCoder = class_getInstanceMethod(klass, coderSel),
              let installedFrame = class_getInstanceMethod(klass, frameSel),
              let installedContainer = class_getInstanceMethod(klass, containerSel) else { return false }
        originals = [(installedInit, initOriginal), (installedCoder, coderOriginal),
                     (installedFrame, frameOriginal), (installedContainer, containerOriginal)]
        replacements = [initReplacement, coderReplacement, frameReplacement, containerReplacement]
        return true
    }

    @MainActor func uninstall() {
        for (method, original) in originals { _ = method_setImplementation(method, original) }
        originals.removeAll()
        for replacement in replacements { _ = imp_removeBlock(replacement) }
        replacements.removeAll()
    }
}
