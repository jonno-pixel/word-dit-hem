import Foundation
import NaturalLanguage

actor LocalInferenceEngine {
    func unload() {}

    func generate(
        modelURL: URL?,
        options: GenerationOptions,
        history: [EngineTurn],
        emit: @Sendable (EngineUpdate) async throws -> Void
    ) async throws -> GenerationResult {
        try await emit(.status("Verwerken op iOS hardware…"))

        guard let lastUserTurn = history.last(where: { $0.role == MessageRole.user.rawValue }) else {
            throw JJSFailure(message: "Geen invoer gevonden.")
        }

        var modelStatus = "Ingebouwde iOS Native Engine"
        if let modelURL, FileManager.default.fileExists(atPath: modelURL.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            modelStatus = "\(modelURL.deletingPathExtension().lastPathComponent) (\(sizeText))"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lastUserTurn.content)
        let detectedLang = recognizer.dominantLanguage?.rawValue ?? "nl"

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = lastUserTurn.content
        var keywords: [String] = []
        let range = lastUserTurn.content.startIndex..<lastUserTurn.content.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
            if tag == .noun || tag == .verb {
                let word = String(lastUserTurn.content[tokenRange])
                if word.count > 2 && !keywords.contains(word) {
                    keywords.append(word)
                }
            }
            return keywords.count < 10
        }

        let trimmed = lastUserTurn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyLine = keywords.isEmpty ? "geen specifieke trefwoorden" : keywords.joined(separator: ", ")

        let response = """
        **Engine:** \(modelStatus) • Taal: \(detectedLang.uppercased())
        **Kernwoorden:** \(keyLine)

        \(trimmed)
        """

        let words = response.split(separator: " ", omittingEmptySubsequences: false)
        var tokenCount = 0
        for (index, word) in words.enumerated() {
            try Task.checkCancellation()
            let chunk = index == 0 ? String(word) : " " + String(word)
            try await emit(.text(chunk))
            tokenCount += 1
            try await Task.sleep(for: .milliseconds(12))
        }

        return GenerationResult(tokenCount: tokenCount, contextShifts: 0)
    }
}
