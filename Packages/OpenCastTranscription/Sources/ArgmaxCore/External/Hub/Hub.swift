// Originally from: https://github.com/huggingface/swift-transformers
// Version: 1.1.6 (commit: 573e5c9036c2f136b3a8a071da8e8907322403d0)
// License: Apache 2.0 (https://github.com/huggingface/swift-transformers/blob/main/LICENSE)
// Copyright 2022 Hugging Face SAS
// Modified by Argmax, Inc. and OpenCast.

import Foundation

enum Hub {}

extension Hub {
    enum HubClientError: LocalizedError {
        case authorizationRequired
        case httpStatusCode(Int)
        case parse
        case jsonSerialization(fileURL: URL, message: String)
        case unexpectedError
        case downloadError(String)
        case fileNotFound(String)
        case networkError(URLError)
        case resourceNotFound(String)
        case configurationMissing(String)
        case fileSystemError(Error)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .authorizationRequired:
                String(localized: "Authentication required.")
            case let .httpStatusCode(code):
                String(localized: "HTTP error with status code: \(code)")
            case .parse:
                String(localized: "Failed to parse response.")
            case .jsonSerialization(_, let message):
                message
            case .unexpectedError:
                String(localized: "An unexpected error occurred.")
            case let .downloadError(message):
                String(localized: "Download failed: \(message)")
            case let .fileNotFound(filename):
                String(localized: "File not found: \(filename)")
            case let .networkError(error):
                String(localized: "Network error: \(error.localizedDescription)")
            case let .resourceNotFound(resource):
                String(localized: "Resource not found: \(resource)")
            case let .configurationMissing(file):
                String(localized: "Required configuration file missing: \(file)")
            case let .fileSystemError(error):
                String(localized: "File system error: \(error.localizedDescription)")
            case let .parseError(message):
                String(localized: "Parse error: \(message)")
            }
        }
    }
}

final class LanguageModelConfigurationFromHub: Sendable {
    struct Configurations {
        var modelConfig: Config?
        var tokenizerConfig: Config?
        var tokenizerData: Config
    }

    private let configPromise: Task<Configurations, Error>

    @available(*, unavailable, message: "OpenCast bundles tokenizer files locally and disables remote tokenizer resolution.")
    init(
        modelName: String,
        revision: String = "main",
        hubApi: HubApiWrapper = .shared
    ) {
        configPromise = Task {
            throw Hub.HubClientError.downloadError("Remote tokenizer resolution is disabled in OpenCast.")
        }
    }

    init(
        modelFolder: URL,
        hubApi: HubApiWrapper = .shared
    ) {
        configPromise = Task {
            try await Self.loadConfig(modelFolder: modelFolder, hubApi: hubApi.hubApi)
        }
    }

    var modelConfig: Config? {
        get async throws {
            try await configPromise.value.modelConfig
        }
    }

    var tokenizerConfig: Config? {
        get async throws {
            if let hubConfig = try await configPromise.value.tokenizerConfig {
                if hubConfig.tokenizerClass.string() != nil { return hubConfig }
                guard let modelType = try await modelType else { return hubConfig }

                var configuration = hubConfig.dictionary(or: [:])
                configuration["tokenizer_class"] = .init("\(modelType.capitalized)Tokenizer")
                return Config(configuration)
            }

            return nil
        }
    }

    var tokenizerData: Config {
        get async throws {
            try await configPromise.value.tokenizerData
        }
    }

    var modelType: String? {
        get async throws {
            try await modelConfig?.modelType.string()
        }
    }

    static func loadConfig(
        modelFolder: URL,
        hubApi: HubApi = .shared
    ) async throws -> Configurations {
        do {
            let modelConfigURL = modelFolder.appending(path: "config.json")

            var modelConfig: Config?
            if FileManager.default.fileExists(atPath: modelConfigURL.path) {
                modelConfig = try hubApi.configuration(fileURL: modelConfigURL)
            }

            let tokenizerDataURL = modelFolder.appending(path: "tokenizer.json")
            guard FileManager.default.fileExists(atPath: tokenizerDataURL.path) else {
                throw Hub.HubClientError.configurationMissing("tokenizer.json")
            }

            let tokenizerData = try hubApi.configuration(fileURL: tokenizerDataURL)

            var tokenizerConfig: Config?
            let tokenizerConfigURL = modelFolder.appending(path: "tokenizer_config.json")
            if FileManager.default.fileExists(atPath: tokenizerConfigURL.path) {
                tokenizerConfig = try hubApi.configuration(fileURL: tokenizerConfigURL)
            }

            let chatTemplateJinjaURL = modelFolder.appending(path: "chat_template.jinja")
            let chatTemplateJsonURL = modelFolder.appending(path: "chat_template.json")

            let chatTemplate: String? = if FileManager.default.fileExists(atPath: chatTemplateJinjaURL.path) {
                try? String(contentsOf: chatTemplateJinjaURL, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: chatTemplateJsonURL.path),
                      let chatTemplateConfig = try? hubApi.configuration(fileURL: chatTemplateJsonURL) {
                chatTemplateConfig.chatTemplate.string()
            } else {
                nil
            }

            if let chatTemplate {
                if var configDict = tokenizerConfig?.dictionary() {
                    configDict["chat_template"] = .init(chatTemplate)
                    tokenizerConfig = Config(configDict)
                } else {
                    tokenizerConfig = Config(["chat_template": chatTemplate])
                }
            }

            return Configurations(
                modelConfig: modelConfig,
                tokenizerConfig: tokenizerConfig,
                tokenizerData: tokenizerData
            )
        } catch let error as Hub.HubClientError {
            throw error
        } catch {
            if let nsError = error as NSError? {
                if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                    throw Hub.HubClientError.fileSystemError(error)
                } else if nsError.domain == "NSJSONSerialization" {
                    throw Hub.HubClientError.parseError("Invalid JSON format: \(nsError.localizedDescription)")
                }
            }
            throw Hub.HubClientError.fileSystemError(error)
        }
    }
}
