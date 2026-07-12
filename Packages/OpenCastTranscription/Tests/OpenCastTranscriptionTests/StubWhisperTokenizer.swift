@preconcurrency import WhisperKit

struct StubWhisperTokenizer: WhisperTokenizer {
    let specialTokens = SpecialTokens(
        endToken: 50256,
        englishToken: 50258,
        noSpeechToken: 50361,
        noTimestampsToken: 50362,
        specialTokenBegin: 50257,
        startOfPreviousToken: 50360,
        startOfTranscriptToken: 50257,
        timeTokenBegin: 50363,
        transcribeToken: 50358,
        translateToken: 50359,
        whitespaceToken: 220
    )
    let allLanguageTokens: Set<Int> = []

    func encode(text: String) -> [Int] { [] }
    func decode(tokens: [Int]) -> String { " stub" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}
