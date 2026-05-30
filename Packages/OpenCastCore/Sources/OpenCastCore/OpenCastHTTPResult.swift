import Foundation

public struct OpenCastHTTPResult: Sendable {
    public var data: Data
    public var response: OpenCastHTTPResponse

    public init(data: Data, response: OpenCastHTTPResponse) {
        self.data = data
        self.response = response
    }
}
