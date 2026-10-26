import OpenCastAnalysis

/// UI tests: the Gemini body the fixture transport answers a Chapters &
/// Summary request with. The answer is synthetic: it reads only the segment
/// ids from the request's prompt and splits them into at most two chapters
/// with fixed titles, a fixed summary and one claim; no transcript text is
/// echoed. `nil` (no segment ids found) fails the send.
nonisolated enum ChaptersSummaryFixtureAnswer {
    static let chapterTitles = ["Part One", "Part Two"]
    static let summary = "A fixture summary written for interface tests."
    static let oneLineDescription = "A fixture episode"

    static func geminiBody(for request: AnalysisProviderRequest) -> String? {
        guard let prompt = request.payload["contents"]?.arrayValue?.first?["parts"]?.arrayValue?.first?["text"]?.stringValue else {
            return nil
        }
        let ids = segmentIDs(in: prompt)
        guard let first = ids.first, let last = ids.last else {
            return nil
        }
        let split = ids.count / 2
        let ranges: [(Int64, Int64)] = ids.count > 1
            ? [(first, ids[split - 1]), (ids[split], last)]
            : [(first, last)]
        let chapters = zip(chapterTitles, ranges).map { title, range in
            JSONValue.object([
                JSONMember("confidence", .number(.double(0.9))),
                JSONMember("end_segment_id", .number(.integer(range.1))),
                JSONMember("start_segment_id", .number(.integer(range.0))),
                JSONMember("title", .string(title)),
            ])
        }
        let answer = JSONWriter.string(.object([
            JSONMember("chapters", .array(chapters)),
            JSONMember("summary", .object([
                JSONMember("claims", .array([.object([
                    JSONMember("evidence_segment_id", .number(.integer(first))),
                    JSONMember("text", .string("The fixture names its first segment.")),
                ])])),
                JSONMember("one_line_description", .string(oneLineDescription)),
                JSONMember("summary", .string(summary)),
            ])),
        ]))
        return JSONWriter.string(.object([
            JSONMember("candidates", .array([.object([
                JSONMember("content", .object([
                    JSONMember("parts", .array([.object([JSONMember("text", .string(answer))])])),
                    JSONMember("role", .string("model")),
                ])),
                JSONMember("finishReason", .string("STOP")),
            ])])),
            JSONMember("usageMetadata", .object([
                JSONMember("candidatesTokenCount", .integer(36)),
                JSONMember("promptTokenCount", .integer(420)),
                JSONMember("totalTokenCount", .integer(456)),
            ])),
        ]))
    }

    /// The ids of the prompt's `[<id> | <start>-<end>] text` lines.
    static func segmentIDs(in prompt: String) -> [Int64] {
        guard let segments = prompt.range(of: "\nSegments:\n") else {
            return []
        }
        return prompt[segments.upperBound...].split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let bar = line.firstIndex(of: "|") else {
                return nil
            }
            return Int64(line[line.index(after: line.startIndex)..<bar].trimmingCharacters(in: .whitespaces))
        }
    }
}
