import ContinuumRevivedCore
import Foundation

/// Deterministic witnesses for dictation's technical-speech support: vocabulary
/// assembly (bounded, deduplicated, live terms first) and the conservative
/// normaliser. The phrases are what the real recogniser produced for `say`
/// fixtures of the sentences in the matching comments (probe, 2026-11-18), so
/// the rules are checked against real recogniser output, not invented text.
func runDictationVocabularyChecks() throws {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "DictationVocabularyChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    // Assembly.
    let live = ["DictationSession", "agent/voice-accuracy", "dictationsession", "x"]
    let terms = DictationVocabulary.assemble(dynamic: live)
    try require(terms.first == "DictationSession", "live terms must lead")
    try require(terms.filter { $0.lowercased() == "dictationsession" }.count == 1, "case-insensitive dedupe")
    try require(!terms.contains("x"), "one-character junk dropped")
    try require(terms.contains("Claude Code") && terms.contains("SwiftPM"), "base jargon present")
    let flood = (0..<2000).map { "Name\($0)Thing" }
    try require(DictationVocabulary.assemble(dynamic: flood).count == DictationVocabulary.termLimit, "bounded at termLimit")
    try require(DictationVocabulary.assemble(dynamic: [String(repeating: "a", count: 200)]).allSatisfy { $0.count <= DictationVocabulary.maxTermLength }, "over-long terms dropped")
    let stems = DictationVocabulary.identifierStems(fromFileNames: ["DictationSession.swift", "main.swift", "run-matrix.sh", "README.md"])
    try require(stems == ["DictationSession", "run-matrix", "README"], "identifier-like stems only: \(stems)")

    // Normalisation, using real recogniser output (see header).
    let n = DictationNormalizer(terms: DictationVocabulary.assemble(dynamic: ["DictationSession", "AVAudioEngine", "ContinuumRevivedCore"]))
    let cases: [(String, String)] = [
        // "Edit DictationSession dot swift and check the AVAudioEngine tap"
        ("Add dictation session dot swift and check the AV audio engine tab",
         "Add DictationSession.swift and check the AVAudioEngine tab"),
        ("Add DictationSession dot.swift and check", "Add DictationSession.swift and check"),
        // "Open ContinuumRevivedCore and run SwiftPM build in Xcode"
        ("Open continuum revived core and runs swift p m building x code",
         "Open ContinuumRevivedCore and runs SwiftPM building Xcode"),
        // Must NOT touch ordinary prose.
        ("connect the dots with swift", "connect the dots with swift"),
        ("a dot in the middle", "a dot in the middle"),
        ("the audio engine is loud", "the audio engine is loud"),
    ]
    for (input, expected) in cases {
        let got = n.normalize(input)
        try require(got == expected, "normalize(\"\(input)\") = \"\(got)\", expected \"\(expected)\"")
    }
    print("DictationVocabularyChecks passed: \(terms.count) terms, \(cases.count) normaliser cases")
}
