import CoreAudio
import Testing

@Suite("HALError permission classification")
struct HALErrorTests {
    @Test("device permission status is classified for calls and properties")
    func permissionStatus() {
        let operation = HALError.operation(kAudioDevicePermissionsError, "start aggregate")
        let property = HALError.osStatus(kAudioDevicePermissionsError, kAudioDevicePropertyMute)

        #expect(operation.isPermissionDenied)
        #expect(property.isPermissionDenied)
    }

    @Test("transient HAL failures do not show the permission banner")
    func transientFailures() {
        let deadDevice = HALError.operation(kAudioHardwareBadDeviceError, "start aggregate")
        let churn = HALError.operation(kAudioHardwareIllegalOperationError, "create aggregate")

        #expect(!deadDevice.isPermissionDenied)
        #expect(!churn.isPermissionDenied)
    }
}
