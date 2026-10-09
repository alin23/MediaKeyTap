//
//  MediaKeyTapInternals.swift
//  Castle
//
//  A wrapper around the C APIs required for a CGEventTap
//
//  Created by Nicholas Hurden on 18/02/2016.
//  Copyright © 2016 Nicholas Hurden. All rights reserved.
//

import Cocoa
import CoreGraphics

class RunLoopThread: Thread {
    init(mode: RunLoop.Mode, qualityOfService: QualityOfService? = nil, machPort: CFMachPort) {
        self.mode = mode
        super.init()

        if let qualityOfService {
            self.qualityOfService = qualityOfService
        }
        self.machPort = machPort
        start()
    }

    let serialQueue = DispatchQueue(label: "MediaKeyTapRunLoopQueue")
    private(set) var runLoop: RunLoop!
    @Atomic private(set) var stopped = true

    func stop() {
        stopped = true
        // Ends the current run now instead of at its 1s limit: a restart
        // creates the new tap enabled, and until this thread adds it to its
        // run loop nothing answers the tap and every key waits on it.
        CFRunLoopStop(runLoop.getCFRunLoop())
    }

    func restart(machPort: CFMachPort) {
        serialQueue.async { [self] in
            stopSemaphore.wait()
            machPortLock.withLock {
                assert(self.machPort == nil, "Restarting thread with existing mach port")
                self.machPort = machPort
            }
            stopped = false
            restartSemaphore.signal()
        }
    }

    override func start() {
        stopped = false
        super.start()
        startSemaphore.wait()
    }

    override func main() {
        runLoop = RunLoop.current
        runLoop.add(machPort!, forMode: mode)

        startSemaphore.signal()
        while !isCancelled {
            guard !stopped else {
                machPortLock.withLock {
                    runLoop.remove(machPort!, forMode: self.mode)
                    self.machPort = nil
                }

                stopSemaphore.signal()
                restartSemaphore.wait()

                machPortLock.withLock {
                    runLoop.add(machPort!, forMode: self.mode)
                }
                continue
            }
            if !runLoop.run(mode: mode, before: Date().addingTimeInterval(1)) {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private var machPort: CFMachPort?
    private var machPortLock = NSRecursiveLock()

    private let startSemaphore = DispatchSemaphore(value: 0)
    private let restartSemaphore = DispatchSemaphore(value: 0)
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private let mode: RunLoop.Mode
}

enum EventTapError: Error {
    case eventTapCreationFailure
    case runLoopSourceCreationFailure
}

extension EventTapError: CustomStringConvertible {
    var description: String {
        switch self {
        case .eventTapCreationFailure: return "Event tap creation failed: is your application sandboxed?"
        case .runLoopSourceCreationFailure: return "Runloop source creation failed"
        }
    }
}

func mainScreen() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    let screens = NSScreen.screens
    let screenWithMouse = (screens.first { NSMouseInRect(mouseLocation, $0.frame, false) })

    return screenWithMouse
}

protocol MediaKeyTapInternalsDelegate: AnyObject {
    var keysToWatch: [MediaKey] { get set }
    var observeBuiltIn: Bool { get set }
    func updateInterceptMediaKeys(_ intercept: Bool)
    func handle(keyEvent: KeyEvent, isFunctionKey: Bool, modifiers: NSEvent.ModifierFlags?, event: CGEvent) -> CGEvent?
    func isInterceptingMediaKeys() -> Bool
}

@discardableResult
@inline(__always) func mainThread<T>(_ action: () -> T) -> T {
    guard !Thread.isMainThread else {
        return action()
    }
    return DispatchQueue.main.sync { action() }
}

@discardableResult
@inline(__always) func mainThreadThrows<T>(_ action: () throws -> T) throws -> T {
    guard !Thread.isMainThread else {
        return try action()
    }
    return try DispatchQueue.main.sync { try action() }
}

class MediaKeyTapInternals {
    deinit {
        stopWatchingMediaKeys()
    }

    typealias EventTapCallback = @convention(block) (CGEventType, CGEvent) -> CGEvent?

    weak var delegate: MediaKeyTapInternalsDelegate?
    var keyEventPort: CFMachPort?
    /// `keyEventPort`, readable from the event tap guard's queue.
    let tapBox = EventTapBox()
    var callback: EventTapCallback?

    var id: String {
        guard let delegate else { return "" }
        let keyStr = delegate.keysToWatch.map { String(describing: $0) }.joined(separator: "-")

        return "\(keyStr)-\(delegate.observeBuiltIn)"
    }

    /**
     Enable/Disable the underlying tap
     */
    func enableTap(_ onOff: Bool) {
        guard let tap = keyEventPort else { return }
        CGEvent.tapEnable(tap: tap, enable: onOff)
    }

    /**
     Restart the tap, placing it in front of existing taps
     */
    func restartTap() throws {
        stopWatchingMediaKeys()
        try startWatchingMediaKeys(restart: true)
    }

    func startWatchingMediaKeys(restart: Bool = false) throws {
        try mainThreadThrows {
            guard self.thread?.stopped ?? true else { return }

            let eventTapCallback: EventTapCallback = { [weak self] type, event in
                guard let self = self else { return event }
                if type == .tapDisabledByTimeout {
                    // Not one the event tap guard took down.
                    if let tap = self.keyEventPort, CFMachPortIsValid(tap) {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return event
                } else if type == .tapDisabledByUserInput {
                    return event
                }

                // Fast path: this is a filtering `.defaultTap` over NX_KEYDOWN, so WindowServer waits
                // on the callback's verdict for EVERY keystroke. Hopping to main (`mainThread` is
                // `DispatchQueue.main.sync` when off-main) means any main-thread stall (e.g. a slow
                // synchronous DDC write to an unresponsive display) blocks the callback and freezes
                // all keyboard input system-wide. Only brightness media keys arrive as keyDown
                // (`functionKeyCodeToMediaKey`), so bail immediately for every other key, never
                // touching main. NX_SYSDEFINED (media) events still go through the handler.
                if type == .keyDown,
                   MediaKeyTap.functionKeyCodeToMediaKey(Int32(event.getIntegerValueField(.keyboardEventKeycode))) == nil {
                    return event
                }

                return mainThread {
                    self.handle(event: event, ofType: type)
                }
            }

            self.callback = eventTapCallback
            try self.startKeyEventTap(callback: eventTapCallback, restart: restart)
        }
    }

    func stopWatchingMediaKeys() {
        mainThread {
            guard let thread, let keyEventPort else { return }

            thread.stop()
            CGEvent.tapEnable(tap: keyEventPort, enable: false)
            // CG keeps its own references to the port, so dropping ours never frees it:
            // without this the disabled tap stays in the WindowServer tap table until the process exits
            CFMachPortInvalidate(keyEventPort)
            self.keyEventPort = nil
            self.tapBox.tap = nil
            self.callback = nil
        }
    }

    private var thread: RunLoopThread?

    private func handle(event: CGEvent, ofType type: CGEventType) -> CGEvent? {
        if type == .keyDown {
            let keycode: Int64 = event.getIntegerValueField(.keyboardEventKeycode)
            guard let mediaKey = MediaKeyTap.functionKeyCodeToMediaKey(Int32(keycode)) else { return event }
            if delegate?.keysToWatch.contains(mediaKey) ?? false {
                if !(delegate?.observeBuiltIn ?? true) {
                    if let id = mainScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                        if CGDisplayIsBuiltin(id) != 0 {
                            return event
                        }
                    }
                }

                return delegate?.handle(
                    keyEvent: KeyEvent(keycode: Int32(keycode), keyFlags: 0, keyPressed: true, keyRepeat: false),
                    isFunctionKey: true,
                    modifiers: NSEvent(cgEvent: event)?.modifierFlags,
                    event: event
                )
            } else {
                return event
            }
        }

        if let nsEvent = NSEvent(cgEvent: event) {
            guard let mediaKey = MediaKeyTap.keycodeToMediaKey(nsEvent.keyEvent.keycode) else { return event }
            guard type.rawValue == UInt32(NX_SYSDEFINED),
                  nsEvent.isMediaKeyEvent,
                  delegate?.keysToWatch.contains(mediaKey) ?? false,
                  delegate?.isInterceptingMediaKeys() ?? false
            else { return event }

            if delegate?.observeBuiltIn ?? true == false {
                if let id = mainScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    if CGDisplayIsBuiltin(id) != 0 {
                        return event
                    }
                }
            }
            return delegate?.handle(keyEvent: nsEvent.keyEvent, isFunctionKey: false, modifiers: nsEvent.modifierFlags, event: event)
        }

        return event
    }

    private func startKeyEventTap(callback: @escaping EventTapCallback, restart: Bool) throws {
        // On a restart we don't want to interfere with the application watcher
        if !restart {
            delegate?.updateInterceptMediaKeys(true)
        }

        keyEventPort = keyCaptureEventTapPort(callback: callback)
        guard let port = keyEventPort else { throw EventTapError.eventTapCreationFailure }
        tapBox.tap = port
        if let thread {
            thread.restart(machPort: port)
        } else {
            thread = RunLoopThread(mode: .default, qualityOfService: .userInteractive, machPort: port)
        }
    }

    private func keyCaptureEventTapPort(callback _: @escaping EventTapCallback) -> CFMachPort? {
        let cCallback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let tap = CUtil.bridge(ptr: refcon) as MediaKeyTapInternals
            return tap.callback?(type, event).map(Unmanaged.passUnretained)
        }

        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NX_KEYDOWN) | CGEventMask(1 << NX_SYSDEFINED),
            callback: cCallback,
            userInfo: CUtil.bridge(obj: self)
        )
    }
}

enum CUtil {
    static func bridge<T: AnyObject>(obj: T) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passUnretained(obj).toOpaque())
    }

    static func bridge<T: AnyObject>(ptr: UnsafeMutableRawPointer) -> T {
        Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
    }
}
