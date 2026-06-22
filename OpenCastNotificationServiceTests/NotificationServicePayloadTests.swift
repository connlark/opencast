import Foundation
import Testing

@Suite("Notification service payload helpers")
struct NotificationServicePayloadTests {
    @Test("Artwork URL accepts only episode HTTPS URLs")
    func artworkURLAcceptsOnlyEpisodeHTTPSURLs() throws {
        #expect(NotificationPayload.artworkURL(from: [
            "opencast": [
                "kind": "episode",
                "artwork_url": "https://example.com/art.jpg",
            ],
        ]) == URL(string: "https://example.com/art.jpg"))

        #expect(NotificationPayload.artworkURL(from: [
            "opencast": [
                "kind": "episode",
                "artwork_url": "http://example.com/art.jpg",
            ],
        ]) == nil)
        #expect(NotificationPayload.artworkURL(from: [
            "opencast": [
                "kind": "diagnostic",
                "artwork_url": "https://example.com/art.jpg",
            ],
        ]) == nil)
        #expect(NotificationPayload.artworkURL(from: [
            "opencast": [
                "kind": "episode",
                "artwork_url": "   ",
            ],
        ]) == nil)
        #expect(NotificationPayload.artworkURL(from: [:]) == nil)
    }

    @Test("Image format prefers MIME type and falls back to extension")
    func imageFormatPrefersMIMETypeAndFallsBackToExtension() throws {
        let jpegURL = try #require(URL(string: "https://example.com/art.png"))
        let response = try #require(HTTPURLResponse(
            url: jpegURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        ))

        #expect(ImageFormat.resolve(response: response, sourceURL: jpegURL)?.fileExtension == "jpg")

        let heicURL = try #require(URL(string: "https://example.com/art.heic"))
        let fallback = URLResponse(
            url: heicURL,
            mimeType: nil,
            expectedContentLength: 10,
            textEncodingName: nil
        )
        #expect(ImageFormat.resolve(response: fallback, sourceURL: heicURL)?.fileExtension == "heic")
        #expect(ImageFormat(fileExtension: "jpeg")?.fileExtension == "jpg")
        #expect(ImageFormat(fileExtension: "png")?.fileExtension == "png")
        #expect(ImageFormat(fileExtension: "gif")?.fileExtension == "gif")
        #expect(ImageFormat(fileExtension: "heif")?.fileExtension == "heif")
        #expect(ImageFormat(fileExtension: "txt") == nil)
    }

    @Test("Invalid attachment inputs do not create attachments")
    func invalidAttachmentInputsDoNotCreateAttachments() throws {
        let sourceURL = try #require(URL(string: "https://example.com/art.jpg"))
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        ))

        let zeroByteURL = try temporaryFile(bytes: [])
        #expect(NotificationAttachmentFactory.attachment(
            from: zeroByteURL,
            response: response,
            sourceURL: sourceURL,
            maxArtworkBytes: 10
        ) == nil)

        let oversizedURL = try temporaryFile(bytes: [0, 1, 2, 3])
        #expect(NotificationAttachmentFactory.attachment(
            from: oversizedURL,
            response: response,
            sourceURL: sourceURL,
            maxArtworkBytes: 3
        ) == nil)

        let unknownURL = try temporaryFile(bytes: [0, 1, 2])
        let unknownSourceURL = try #require(URL(string: "https://example.com/art.txt"))
        let unknownResponse = URLResponse(
            url: unknownSourceURL,
            mimeType: nil,
            expectedContentLength: 3,
            textEncodingName: nil
        )
        #expect(NotificationAttachmentFactory.attachment(
            from: unknownURL,
            response: unknownResponse,
            sourceURL: unknownSourceURL,
            maxArtworkBytes: 10
        ) == nil)
    }

    private func temporaryFile(bytes: [UInt8]) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(bytes).write(to: url)
        return url
    }
}
