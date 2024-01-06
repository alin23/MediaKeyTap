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
    init(mode: RunLoop.Mode, qualityOfService: QualityOfService? = nil, start: Bool = false) {
        self.mode = mode
        super.init()
        if let qualityOfService = qualityOfService { self.qualityOfService = qualityOfService }
        if start { self.start() }
    }

    private(set) var runLoop: RunLoop?

    override func start() {
        super.start()
        startSemaphore.wait()
    }

    override func main() {
        runLoop = RunLoop.current
        startSemaphore.signal()
        while !isCancelled {
            if !runLoop!.run(mode: mode, before: .distantFuture) {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private let startSemaphore = DispatchSemaphore(value: 0)
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
            guard self.thread == nil else { return }

            let eventTapCallback: EventTapCallback = { [weak self] type, event in
                guard let self = self else { return event }
                if type == .tapDisabledByTimeout {
                    if let tap = self.keyEventPort {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return event
                } else if type == .tapDisabledByUserInput {
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

            thread.runLoop?.remove(keyEventPort, forMode: .default)
            thread.cancel()
            self.thread = nil

            CGEvent.tapEnable(tap: keyEventPort, enable: false)
            self.keyEventPort = nil
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
        thread = RunLoopThread(mode: .default, qualityOfService: .userInteractive, start: true)
        thread!.runLoop!.add(port, forMode: .default)
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
