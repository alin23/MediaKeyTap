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

    /// The tap thread reads this for every event while a restart on the main thread sets it to nil
    /// and then to a new block. Unguarded, the read could copy a block that the write had just
    /// released, and the app crashed in `_Block_copy` or `swift_release`. Under the lock, the tap
    /// thread holds its own reference to the block while it runs it.
    var callback: EventTapCallback? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return storedCallback
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            storedCallback = newValue
        }
    }

    private var storedCallback: EventTapCallback?
    private let callbackLock = NSLock()

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
        EventTapGuard.whileLive(tap) { CGEvent.tapEnable(tap: tap, enable: onOff) }
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
            if let port = self.keyEventPort {
                // Still running. One that the event tap guard invalidated is cleared and
                // created again.
                guard !CFMachPortIsValid(port) else { return }
                self.stopWatchingMediaKeys()
            }

            let eventTapCallback: EventTapCallback = { [weak self] type, event in
                guard let self = self else { return event }
                if type == .tapDisabledByTimeout {
                    // Not one the event tap guard took down. `tapBox` and not `keyEventPort`, which
                    // the main thread writes without a lock.
                    if let tap = self.tapBox.tap {
                        EventTapGuard.enable(tap)
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

                // Same for NX_SYSDEFINED: the hardware sends one with every mouse button press and
                // release (subtype 7), and WindowServer holds that click until this callback answers.
                // The main queue runs one block at a time, so while it runs a modal alert from a
                // block (Sparkle's "You're up to date") `mainThread` waited until the alert closed:
                // the first click on the alert never arrived, and was delivered after it closed to
                // whatever window was under the pointer, as a press with no release. Only media key
                // events need the handler, so every other system-defined event returns here.
                // The check reads the event's fields: an NSEvent made on this thread from a Caps Lock
                // release crashes (see `isMediaKeySystemEvent`). When the fields read empty, the event
                // goes to the handler on main, as every system-defined event did before.
                if type.rawValue == UInt32(NX_SYSDEFINED), event.isMediaKeySystemEvent == false {
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
            guard let keyEventPort else { return }

            // Disabled and invalidated. A tap that was only disabled stayed in the WindowServer's
            // list until the app quit, one more for every restart, and with thousands of them
            // the WindowServer lagged behind the pointer. The invalidation also ends the tap's
            // thread.
            EventTapGuard.stop(keyEventPort)
            self.keyEventPort = nil
            self.tapBox.tap = nil
            self.callback = nil
        }
    }

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

        guard let port = keyCaptureEventTapPort(callback: callback) else { throw EventTapError.eventTapCreationFailure }
        keyEventPort = port
        tapBox.tap = port
        // On a thread of its own, which ends when `stopWatchingMediaKeys` or the event tap guard
        // invalidates the tap.
        EventTapGuard.run(port, name: "MediaKeyTap")
    }

    private func keyCaptureEventTapPort(callback _: @escaping EventTapCallback) -> CFMachPort? {
        let cCallback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let tap = CUtil.bridge(ptr: refcon) as MediaKeyTapInternals
            // Stopped between the event and this call: pass the event on rather than drop the key.
            guard let callback = tap.callback else { return Unmanaged.passUnretained(event) }
            return callback(type, event).map(Unmanaged.passUnretained)
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
