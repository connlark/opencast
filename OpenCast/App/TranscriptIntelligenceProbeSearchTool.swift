#if DEBUG
import FoundationModels
import Synchronization

/// Stage-0 probe tool: lexical search over a built-in twelve-line transcript.
/// Its `Output` is `String`, the tool result type the 27 SDK accepts, and it
/// logs every query so the report can prove PCC drove the call.
nonisolated final class TranscriptIntelligenceProbeSearchTool: Tool {
    typealias Arguments = TranscriptIntelligenceProbeSearchArguments

    struct Line: Sendable {
        var id: Int
        var start: String
        var end: String
        var text: String
    }

    static let lines: [Line] = [
        Line(id: 1, start: "0:00", end: "0:14", text: "Welcome back to Crumb Notes, the show about home baking. I'm Dana and today we're talking sourdough."),
        Line(id: 2, start: "0:14", end: "0:31", text: "Before we start, a quick note: this episode is sponsored by nobody, we're just here for the bread."),
        Line(id: 3, start: "0:31", end: "0:55", text: "So my starter, which I've named Gladys, is about four years old now and lives in the fridge between bakes."),
        Line(id: 4, start: "0:55", end: "1:20", text: "The biggest mistake I see is people feeding the starter once a week and expecting it to be lively on bake day."),
        Line(id: 5, start: "1:20", end: "1:48", text: "Feed it twice, twelve hours apart, the day before you mix, and it'll double in about five hours at room temperature."),
        Line(id: 6, start: "1:48", end: "2:10", text: "Let's talk hydration. I bake at 78 percent, which is wetter than most beginner recipes."),
        Line(id: 7, start: "2:10", end: "2:35", text: "Higher hydration gives you the open crumb, but the dough is harder to shape, so start at 70 if you're new."),
        Line(id: 8, start: "2:35", end: "3:02", text: "For the bake itself I preheat the Dutch oven to 250 Celsius for a full hour before the loaf goes in."),
        Line(id: 9, start: "3:02", end: "3:26", text: "Lid on for twenty minutes, then lid off and drop to 230 for another twenty-five until the crust is deep brown."),
        Line(id: 10, start: "3:26", end: "3:48", text: "A listener wrote in asking about rye. I do a 20 percent rye loaf on Sundays and it's my favorite crumb."),
        Line(id: 11, start: "3:48", end: "4:10", text: "Next week we've got a guest who bakes in a wood-fired oven, so bring your questions."),
        Line(id: 12, start: "4:10", end: "4:20", text: "Thanks for listening to Crumb Notes. Feed your starter."),
    ]

    static var fixtureText: String {
        lines.map(format).joined(separator: "\n")
    }

    let name = "searchTranscript"
    let description = "Finds transcript passages that mention the given words. Returns up to three lines as [#segmentID start–end] text."
    private let queries = Mutex<[String]>([])

    /// Queries received since the last drain, in call order.
    func drainQueries() -> [String] {
        queries.withLock { queries in
            defer { queries.removeAll() }
            return queries
        }
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        queries.withLock { $0.append(arguments.query) }
        let words = arguments.query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }
        let scored = Self.lines.compactMap { line -> (score: Int, line: Line)? in
            let folded = line.text.lowercased()
            let score = words.count { folded.contains($0) }
            return score > 0 ? (score, line) : nil
        }
        .sorted { $0.score > $1.score || ($0.score == $1.score && $0.line.id < $1.line.id) }
        .prefix(3)
        guard !scored.isEmpty else {
            return "No passages matched."
        }
        return scored.map { Self.format($0.line) }.joined(separator: "\n")
    }

    private static func format(_ line: Line) -> String {
        "[#\(line.id) \(line.start)–\(line.end)] \(line.text)"
    }
}
#endif
