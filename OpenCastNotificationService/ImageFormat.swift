import UniformTypeIdentifiers

struct ImageFormat {
    let fileExtension: String
    let typeIdentifier: String

    static func resolve(response: URLResponse, sourceURL: URL) -> ImageFormat? {
        if let mimeType = response.mimeType?.lowercased(),
           let format = ImageFormat(mimeType: mimeType) {
            return format
        }

        return ImageFormat(fileExtension: sourceURL.pathExtension.lowercased())
    }

    init?(mimeType: String) {
        switch mimeType {
        case "image/jpeg", "image/jpg":
            self.init(fileExtension: "jpg")
        case "image/png":
            self.init(fileExtension: "png")
        case "image/gif":
            self.init(fileExtension: "gif")
        case "image/heic":
            self.init(fileExtension: "heic")
        case "image/heif":
            self.init(fileExtension: "heif")
        default:
            return nil
        }
    }

    init?(fileExtension: String) {
        switch fileExtension {
        case "jpg", "jpeg":
            self.fileExtension = "jpg"
            typeIdentifier = UTType.jpeg.identifier
        case "png":
            self.fileExtension = "png"
            typeIdentifier = UTType.png.identifier
        case "gif":
            self.fileExtension = "gif"
            typeIdentifier = UTType.gif.identifier
        case "heic":
            self.fileExtension = "heic"
            typeIdentifier = UTType.heic.identifier
        case "heif":
            self.fileExtension = "heif"
            typeIdentifier = UTType.heif.identifier
        default:
            return nil
        }
    }
}
