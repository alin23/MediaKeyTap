//
//  NSEventExtensions.swift
//  MediaKeyTap
//
//  Created by Nicholas Hurden on 28/09/2016.
//  Copyright © 2016 Nicholas Hurden. All rights reserved.
//

import AppKit

extension NSEvent {
    var isKeyEvent: Bool {
        subtype.rawValue == 8
    }

    var keycode: Keycode {
        Keycode((data1 & 0xFFFF_0000) >> 16)
    }

    var keyEvent: KeyEvent {
        let keyFlags = KeyFlags(data1 & 0x0000_FFFF)
        let keyPressed = ((keyFlags & 0xFF00) >> 8) == 0xA
        let keyRepeat = (keyFlags & 0x1) == 0x1

        return KeyEvent(keycode: keycode, keyFlags: keyFlags, keyPressed: keyPressed, keyRepeat: keyRepeat)
    }

    var isMediaKeyEvent: Bool {
        isKeyEvent && mediaKeycodes.contains(keycode)
    }
}

let mediaKeycodes: Set<Keycode> = [
    NX_KEYTYPE_PLAY,
    NX_KEYTYPE_PREVIOUS,
    NX_KEYTYPE_NEXT,
    NX_KEYTYPE_FAST,
    NX_KEYTYPE_REWIND,
    NX_KEYTYPE_BRIGHTNESS_UP,
    NX_KEYTYPE_BRIGHTNESS_DOWN,
    NX_KEYTYPE_SOUND_UP,
    NX_KEYTYPE_SOUND_DOWN,
    NX_KEYTYPE_MUTE,
]

extension CGEvent {
    /// `NSEvent.subtype` and `NSEvent.data1` of a system-defined event, read from the CGEvent fields
    /// that hold them. The fields are undocumented: 99 holds the subtype and 149 the first data word,
    /// the same values `NSEvent(cgEvent:)` gives for an event delivered to a session tap (macOS 27.2).
    ///
    /// The tap thread must not make an NSEvent to get them: for a Caps Lock release, AppKit's
    /// conversion runs the "switch to and from ABC" step of the text input manager, which asserts
    /// that it runs on the main queue and stops the app with EXC_BREAKPOINT.
    var systemDefinedSubtype: Int64 {
        getIntegerValueField(CGEventField(rawValue: 99)!)
    }

    var systemDefinedData1: Int64 {
        getIntegerValueField(CGEventField(rawValue: 149)!)
    }

    /// Whether a system-defined event is a media key, or nil when both fields read 0 and only an
    /// NSEvent made on the main thread can tell.
    var isMediaKeySystemEvent: Bool? {
        let subtype = systemDefinedSubtype
        let data1 = systemDefinedData1
        guard subtype != 0 || data1 != 0 else { return nil }

        return subtype == 8 && mediaKeycodes.contains(Keycode(truncatingIfNeeded: (data1 & 0xFFFF_0000) >> 16))
    }
}
