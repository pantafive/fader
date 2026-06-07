import CoreAudio
import Foundation

/// Thin throwing wrappers over the Core Audio HAL property API.
enum HALError: Error {
    case osStatus(OSStatus, AudioObjectPropertySelector)
    /// A non-property HAL call (tap, aggregate, IO-proc setup) failed.
    case operation(OSStatus, String)
}

extension HALError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .osStatus(status, selector):
            "HAL property \(selector) failed: OSStatus \(status)"
        case let .operation(status, what):
            "Failed to \(what): OSStatus \(status)"
        }
    }
}

/// Output vs. input side of the audio system. Everything device-related —
/// default-device selector, channel/volume scope — hangs off this.
enum AudioDirection {
    case output
    case input

    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }

    var scope: AudioObjectPropertyScope {
        switch self {
        case .output: kAudioDevicePropertyScopeOutput
        case .input: kAudioDevicePropertyScopeInput
        }
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != Self.unknown }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value.
    ///
    /// `T` must be a trivial C-layout value type (numbers, structs of them,
    /// CoreAudio descriptors): the HAL blits raw bytes over it, which would
    /// corrupt ARC-managed references. Strings go through `readString`.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 into value: inout T) throws {
        var address = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
    }

    /// Reads a variable-length array property.
    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of type: T.Type) throws -> [T] {
        var address = Self.address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else { throw HALError.osStatus(status, selector) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
        return values
    }

    /// Reads a CFString property as a Swift String.
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var value: CFString = "" as CFString
        try read(selector, into: &value)
        return value as String
    }

    /// Writes a fixed-size property value. Same `T` contract as `read`:
    /// trivial C-layout value types only.
    func write<T>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  value: T) throws {
        var address = Self.address(selector, scope: scope)
        let status = withUnsafePointer(to: value) { ptr in
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        guard status == noErr else { throw HALError.osStatus(status, selector) }
    }

    /// True when the object exposes the property at all.
    func hasProperty(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope: scope)
        return AudioObjectHasProperty(self, &address)
    }

    /// True when the property exists and accepts writes. Input gain in
    /// particular is read-only or absent on plenty of devices.
    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = Self.address(selector, scope: scope)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Registers a main-queue listener for a property. Returns a token to remove it.
    func listen(_ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                onChange: @escaping @Sendable () -> Void) -> HALListener {
        HALListener(objectID: self, address: Self.address(selector, scope: scope), onChange: onChange)
    }

    // MARK: - Typed conveniences

    static func readDefaultDevice(_ direction: AudioDirection) throws -> AudioDeviceID {
        var device = AudioDeviceID.unknown
        try AudioObjectID.system.read(direction.defaultDeviceSelector, into: &device)
        return device
    }

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try readDefaultDevice(.output)
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    func readProcessPID() throws -> pid_t {
        var pid: pid_t = -1
        try read(kAudioProcessPropertyPID, into: &pid)
        return pid
    }

    func readProcessIsRunningOutput() -> Bool {
        var value: UInt32 = 0
        try? read(kAudioProcessPropertyIsRunningOutput, into: &value)
        return value != 0
    }

    func readProcessIsRunningInput() -> Bool {
        var value: UInt32 = 0
        try? read(kAudioProcessPropertyIsRunningInput, into: &value)
        return value != 0
    }

    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }
}

/// RAII wrapper for a HAL property listener block dispatched to the main queue.
final class HALListener: @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping @Sendable () -> Void) {
        self.objectID = objectID
        self.address = address
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(objectID, &self.address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }
}
