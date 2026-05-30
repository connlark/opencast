import AVFoundation
import Foundation

// AVFoundation owns the loading request lifecycle; this wrapper only carries it back to the resource-loader queue.
nonisolated final class StreamingAudioLoadingRequestBox: @unchecked Sendable {
    private let request: AVAssetResourceLoadingRequest
    private let queue: DispatchQueue

    init(request: AVAssetResourceLoadingRequest, queue: DispatchQueue) {
        self.request = request
        self.queue = queue
    }

    func finish(with result: Result<StreamingAudioLoadingResponse, Error>) {
        queue.async { [request] in
            switch result {
            case .success(let response):
                if let contentInformationRequest = request.contentInformationRequest {
                    contentInformationRequest.contentLength = response.contentLength ?? 0
                    contentInformationRequest.contentType = response.mimeType
                    contentInformationRequest.isByteRangeAccessSupported = true
                }
                request.dataRequest?.respond(with: response.data)
                request.finishLoading()
            case .failure(let error):
                request.finishLoading(with: error)
            }
        }
    }
}
