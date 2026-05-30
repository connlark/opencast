import Foundation
import VoiceBoostLabSupport

do {
    try VoiceBoostLab.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    FileHandle.standardError.write(Data(VoiceBoostLab.usage.utf8))
    exit(1)
}
