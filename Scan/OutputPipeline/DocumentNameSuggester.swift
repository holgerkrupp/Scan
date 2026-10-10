import Foundation
import FoundationModels

/// Proposes a file name for a scanned document from its recognized text;
/// fills the `{name}` token of the filename template.
protocol DocumentNameSuggesting: Sendable {
    /// Returns nil when no name can be proposed; the export then falls back
    /// to `DocumentName.fallback`.
    func suggestName(forText text: String) async -> String?
}

/// Asks the on-device Apple Intelligence model (FoundationModels) for a
/// name. Nothing leaves the Mac. A model that is unavailable, declines or
/// fails only costs the name, never the export.
struct FoundationModelNameSuggester: DocumentNameSuggesting {
    static let instructions = """
        You create file names for scanned letters and documents. A good name has three parts in this order: \
        1. the short name of the sender (company or authority, without legal form such as GmbH or AG), \
        2. the kind of document (for example Rechnung, Mahnung, Vertrag, Versicherungsschein, Bescheid), \
        3. the subject in a few words. \
        Use the language of the document. Reply with the name only: 3 to 7 words separated by spaces, no date, \
        no numbers such as customer or invoice numbers, no file extension, no quotation marks.

        Examples:
        ERGO Versicherungsschein Wohngebäudeversicherung
        Finanzamt Mahnung Umsatzsteuer Säumniszuschlag
        Stadtwerke Jahresabrechnung Strom und Gas
        """

    /// Why `{name}` cannot be filled on this Mac, or nil when the model is ready.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off in System Settings."
        case .unavailable(.modelNotReady): "The Apple Intelligence model is still downloading."
        case .unavailable: "The Apple Intelligence model is not available."
        }
    }

    func suggestName(forText text: String) async -> String? {
        let excerpt = DocumentName.excerpt(text)
        guard !excerpt.isEmpty, Self.unavailableReason == nil else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: 40)
        guard let response = try? await session.respond(to: "Text of the scanned document:\n\(excerpt)", options: options) else { return nil }
        return DocumentName.sanitize(response.content)
    }
}

/// Turns recognized text into a prompt-sized excerpt and a model reply into
/// something safe to use as part of a file name.
enum DocumentName {
    /// Stands in for `{name}` when no name could be proposed.
    static let fallback = "Scan"
    static let maximumLength = 80

    /// The start of the document, where sender and subject usually are; the
    /// on-device model's context is small, so the rest is cut off.
    static func excerpt(_ text: String, limit: Int = 2000) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    static func sanitize(_ reply: String) -> String? {
        guard var name = reply.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        for label in ["Dateiname:", "Filename:", "File name:", "Title:", "Titel:"] where name.lowercased().hasPrefix(label.lowercased()) { name = String(name.dropFirst(label.count)) }
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>_`#„“”«»")).joined(separator: " ")
        name = name.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .-,;'"))
        for ext in [".pdf", ".jpg", ".jpeg", ".png", ".tiff"] where name.lowercased().hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        if name.count > maximumLength {
            let cut = name.prefix(maximumLength)
            name = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: " .-,;'"))
        }
        return name.isEmpty ? nil : name
    }
}
