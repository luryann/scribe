import CoreAudio
import Foundation

/// A selectable microphone input.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

/// Thin CoreAudio wrapper for listing input devices and picking a sensible default.
/// Scribe deliberately prefers the built-in mic over Bluetooth: AirPods and the like drop to
/// a low-quality call profile the moment an app opens an input stream, which is poison for a
/// lecture transcript.
enum AudioDevices {

    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { id -> AudioInputDevice? in
            guard inputChannelCount(id) > 0 else { return nil }
            guard !isJunkDevice(id) else { return nil }
            let transport = transportType(id)
            return AudioInputDevice(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Unknown microphone",
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE
            )
        }
    }

    static func device(uid: String) -> AudioInputDevice? {
        inputs().first { $0.uid == uid }
    }

    #if DEBUG
    /// One-shot enumeration dump for diagnosing device-selection failures.
    static func debugDump() {
        let fourCC: (UInt32) -> String = { v in
            let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            let s = String(bytes: bytes, encoding: .ascii) ?? ""
            return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(s)'" : "\(v)"
        }
        print("[Scribe] --- audio input enumeration ---")
        print("[Scribe] systemDefaultInputID = \(systemDefaultInputID.map(String.init) ?? "nil")")
        for d in inputs() {
            print("[Scribe]   id=\(d.id) uid=\(d.uid) name=\(d.name) transport=\(fourCC(transportType(d.id))) builtIn=\(d.isBuiltIn) bt=\(d.isBluetooth) ch=\(inputChannelCount(d.id))")
        }
        print("[Scribe] --- end enumeration ---")
    }
    #endif

    /// The device Scribe records from when the user hasn't chosen one: built-in mic first,
    /// then any wired device, and Bluetooth only as a last resort.
    static func preferredDefault() -> AudioInputDevice? {
        let all = inputs()
        if let builtIn = all.first(where: \.isBuiltIn) { return builtIn }
        if let systemID = systemDefaultInputID,
           let system = all.first(where: { $0.id == systemID }),
           !system.isBluetooth {
            return system
        }
        return all.first(where: { !$0.isBluetooth }) ?? all.first
    }

    static var systemDefaultInputID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0
        else { return nil }
        return deviceID
    }

    // MARK: Filtering

    /// True for devices that shouldn't appear in a human mic picker: CoreAudio marks some as
    /// hidden, and it spins up a *private aggregate* ("CADefaultDeviceAggregate-<pid>-<n>")
    /// whenever a process records from the default device — that internal plumbing was leaking
    /// into the list as a garbage entry. Real aggregates (Loopback, BlackHole, user-built
    /// multi-output) are not private and stay visible.
    private static func isJunkDevice(_ id: AudioDeviceID) -> Bool {
        if uint32Property(id, kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal) != 0 {
            return true
        }
        if transportType(id) == kAudioDeviceTransportTypeAggregate {
            if isPrivateAggregate(id) { return true }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            if uid.hasPrefix("CADefaultDeviceAggregate") { return true }
        }
        return false
    }

    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let dict = value?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (dict[kAudioAggregateDeviceIsPrivateKey as String] as? Bool) == true
            || (dict[kAudioAggregateDeviceIsPrivateKey as String] as? Int) == 1
    }

    // MARK: Property helpers

    private static func uint32Property(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // These properties follow the Create Rule: the returned CFString is +1 and the caller
        // owns it. Take it as `Unmanaged` and release it via `takeRetainedValue()` so it isn't
        // leaked on every device enumeration.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue()
        else { return nil }
        let string = cf as String
        return string.isEmpty ? nil : string
    }
}
