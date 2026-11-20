import Foundation

nonisolated protocol AppAttestHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// A body longer than `maximumBodyBytes` fails with ``AppAttestHTTPError/responseTooLarge``.
    func data(for request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, URLResponse)
}

nonisolated extension AppAttestHTTPTransport {
    /// A transport that only reads whole bodies checks the cap after the read.
    func data(for request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        guard data.count <= maximumBodyBytes else {
            throw AppAttestHTTPError.responseTooLarge
        }
        return (data, response)
    }
}

nonisolated extension URLSession: AppAttestHTTPTransport {
    /// Stops reading at the cap, so no more than `maximumBodyBytes` is ever held. Never follows
    /// a redirect: the envelope must reach only its own URL.
    func data(for request: URLRequest, maximumBodyBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await bytes(for: request, delegate: AppAttestRedirectRefusal())
        if response.expectedContentLength > Int64(maximumBodyBytes) {
            throw AppAttestHTTPError.responseTooLarge
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else {
                throw AppAttestHTTPError.responseTooLarge
            }
            body.append(byte)
        }
        return (body, response)
    }
}
