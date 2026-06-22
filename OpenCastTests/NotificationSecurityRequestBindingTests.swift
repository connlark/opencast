#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import DeviceCheck
import Foundation
import Testing
@testable import OpenCast

struct NotificationSecurityRequestBindingTests {
    @Test("Secure hello client data hash matches Worker binding fixture")
    func secureHelloClientDataHashMatchesWorkerBindingFixture() {
        let hash = NotificationSecurityRequestBinding.clientDataHash(
            method: "POST",
            path: "/v1/secure/hello",
            payload: "hello world"
        )

        let expectedHash = "ccb815d6ea147edd6476b79589162789924e74220cfe95c0adadf89ac4a45d7b"
        let payloadHash = NotificationSecurityRequestBinding.sha256Hex(Data("hello world".utf8))
        let binding = "POST\n/v1/secure/hello\n\(payloadHash)"

        #expect(NotificationSecurityRequestBinding.sha256Hex(Data(binding.utf8)) == expectedHash)
        #expect(
            hash == Data([
                0xcc, 0xb8, 0x15, 0xd6, 0xea, 0x14, 0x7e, 0xdd,
                0x64, 0x76, 0xb7, 0x95, 0x89, 0x16, 0x27, 0x89,
                0x92, 0x4e, 0x74, 0x22, 0x0c, 0xfe, 0x95, 0xc0,
                0xad, 0xad, 0xf8, 0x9a, 0xc4, 0xa4, 0x5d, 0x7b,
            ])
        )
    }

    @Test("Authenticated JSON payloads are sorted before App Attest binding")
    func authenticatedJSONPayloadsAreSortedBeforeAppAttestBinding() throws {
        let payload = NotificationDeviceRegistrationPayload(
            deviceToken: "0123456789abcdef",
            apnsEnvironment: "development",
            appVersion: "1.2.3",
            appBuild: "45"
        )

        let payloadString = try NotificationSecureAPIClient.encodedPayloadString(payload)

        #expect(
            payloadString ==
                #"{"apns_environment":"development","app_build":"45","app_version":"1.2.3","device_token":"0123456789abcdef"}"#
        )
    }

    @Test("Empty test-push payload encodes as an empty object")
    func emptyTestPushPayloadEncodesAsEmptyObject() throws {
        let payloadString = try NotificationSecureAPIClient.encodedPayloadString(
            NotificationTestPushPayload()
        )

        #expect(payloadString == "{}")
    }

    @Test("APNs device token data formats as lowercase hex")
    func apnsDeviceTokenDataFormatsAsLowercaseHex() {
        let token = NotificationDeviceTokenStore.hexString(
            for: Data([0x00, 0x0f, 0x10, 0xff])
        )

        #expect(token == "000f10ff")
    }

    @Test("DeviceCheck stale-key errors are recoverable credential failures")
    func deviceCheckStaleKeyErrorsAreRecoverableCredentialFailures() {
        #expect(NotificationSecurityCredentialService.isRecoverableLocalCredentialFailure(
            NSError(
                domain: DCError.errorDomain,
                code: DCError.Code.invalidInput.rawValue
            )
        ))
        #expect(NotificationSecurityCredentialService.isRecoverableLocalCredentialFailure(
            NSError(
                domain: DCError.errorDomain,
                code: DCError.Code.invalidKey.rawValue
            )
        ))
        #expect(!NotificationSecurityCredentialService.isRecoverableLocalCredentialFailure(
            NSError(
                domain: DCError.errorDomain,
                code: DCError.Code.serverUnavailable.rawValue
            )
        ))
        #expect(!NotificationSecurityCredentialService.isRecoverableLocalCredentialFailure(
            NSError(
                domain: NSURLErrorDomain,
                code: URLError.notConnectedToInternet.rawValue
            )
        ))
    }
}
#endif
