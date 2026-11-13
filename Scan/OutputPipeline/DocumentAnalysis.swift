import Foundation
import FoundationModels

/// What the `{docdate}`, `{sender}`, `{type}`, `{subject}` and `{person}`
/// tokens of the filename template are filled with. Empty strings mean unknown.
nonisolated struct DocumentMetadata: Sendable, Equatable {
    /// `yyyy-MM-dd`: the document's own date, or the scan date when none was found.
    var date = ""
    var sender = ""
    var type = ""
    var subject = ""
    var person = ""

    var isDescriptive: Bool { !(sender.isEmpty && type.isEmpty && subject.isEmpty) }
}

/// The fields the language model is asked for.
nonisolated struct DocumentModelReply: Sendable, Equatable {
    var date = ""
    var sender = ""
    var type = ""
    var subject = ""
}

nonisolated protocol DocumentModel: Sendable {
    /// nil when the model is unavailable, declines or fails; the document then
    /// keeps a name built from its date and the people found in its text.
    func reply(toPrompt prompt: String) async -> DocumentModelReply?
}

@Generable(description: "Metadata of a scanned paper document.")
nonisolated struct GeneratedDocumentFields {
    @Guide(description: "Date of the document as YYYY-MM-DD, empty string if absent.")
    var date: String
    @Guide(description: "Organisation or person who issued the document, empty string if unknown.")
    var sender: String
    @Guide(description: "What the document calls itself, in its own exact words, 1 to 4 words; empty string if it does not say.")
    var type: String
    @Guide(description: "2 to 5 words taken from the content of the document, in its language.")
    var subject: String
}

/// The on-device Apple Intelligence model. Nothing leaves the Mac.
nonisolated struct AppleIntelligenceDocumentModel: DocumentModel {
    func reply(toPrompt prompt: String) async -> DocumentModelReply? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: "You extract metadata from scanned paper documents. You only use what is written in the document and never invent anything.")
        // The reply is capped: guided generation without a limit can fill the 4096-token context.
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 200)
        guard let fields = try? await session.respond(to: prompt, generating: GeneratedDocumentFields.self, options: options).content else { return nil }
        return DocumentModelReply(date: fields.date, sender: fields.sender, type: fields.type, subject: fields.subject)
    }
}

/// Finds a document's date, kind, subject and person from its recognized text.
nonisolated enum DocumentAnalysis {
    /// The on-device model's context is 4096 tokens.
    private static let promptTextLimit = 4500

    static func analyze(text: String, scanDate: Date, people: String, model: DocumentModel) async -> DocumentMetadata {
        let candidates = DocumentDates.candidates(in: text, reference: scanDate)
        var reply: DocumentModelReply?
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reply = await model.reply(toPrompt: prompt(text: text, candidates: candidates)) }
        let flatText = DocumentDates.flattened(text).lowercased()
        let type = isWritten(cleaned(reply?.type ?? "", maximumLength: 40), in: flatText) ? cleaned(reply?.type ?? "", maximumLength: 40) : ""
        var subject = keepingWrittenWords(of: cleaned(reply?.subject ?? "", maximumLength: 60), in: flatText)
        if !type.isEmpty, DocumentDates.flattened(subject + " ").lowercased().hasPrefix(DocumentDates.flattened(type + " ").lowercased()) {
            subject = String(subject.dropFirst(type.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -:'"))
        }
        subject = isRealSubject(subject) ? subject.split(separator: " ").prefix(6).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) : ""
        return DocumentMetadata(
            date: DocumentDates.choose(candidates, modelDate: reply?.date ?? "", scanDate: scanDate),
            sender: keepingWrittenWords(of: cleaned(reply?.sender ?? "", maximumLength: 40), in: flatText),
            type: type,
            subject: subject,
            person: person(in: text, list: people)
        )
    }

    static func prompt(text: String, candidates: [DocumentDates.Candidate]) -> String {
        let dates = candidates.isEmpty ? "-" : candidates.prefix(6).map(\.date).joined(separator: ", ")
        var body = text.replacing(/[ \t]+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > promptTextLimit { body = String(body.prefix(promptTextLimit)) + "\n[…]" }
        return """
            Here is the OCR text of a scanned paper document (it may contain OCR errors).

            - "date": the date of the document as YYYY-MM-DD (issue or writing date, NOT a due date, a period or a birth date), or empty if absent.
            - "sender": the organisation or person who issued the document, short name, as written in the text. Never the recipient. Empty if the text does not identify it.
            - "type": what the document calls itself, in its own exact words, 1 to 4 words. Empty if it does not say.
            - "subject": 2 to 5 words taken from the real content of the text, in its language, without a date, an amount, the sender or the type.

            Dates found in the text (most likely first): \(dates)

            Text:
            \"\"\"
            \(body)
            \"\"\"
            """
    }

    /// Lines of the form `Shown name = text to find, other text`; the first
    /// person whose text appears in the document wins. No model involved.
    static func person(in text: String, list: String) -> String {
        let flat = DocumentDates.flattened(text).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { continue }
            let patterns = (parts.count > 1 ? parts[1] : name).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for pattern in patterns {
                // \W+ between words: "DUPONT, JEAN" and OCR slips such as "Jean>Dupont" match too.
                let words = DocumentDates.flattened(pattern).lowercased().matches(of: /\w+/).map { NSRegularExpression.escapedPattern(for: String($0.output)) }
                guard !words.isEmpty, let regex = try? NSRegularExpression(pattern: "\\b" + words.joined(separator: "\\W+") + "\\b") else { continue }
                if regex.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)) != nil { return name }
            }
        }
        return ""
    }

    static func cleaned(_ value: String, maximumLength: Int) -> String {
        var part = value.precomposedStringWithCanonicalMapping.replacing(/[\x00-\x1f\/\\:*?"<>|]+/, with: " ")
        part = part.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        let low = DocumentDates.flattened(part).lowercased()
        if ["null", "none", "n/a", "other", "autre", "keine", "keiner", "sonstiges", "otro", "altro", "overig", "outro", "inny"].contains(low) || ["aucun", "inconnu", "non specifi", "non precis", "unknown", "unbekannt", "nicht angegeben", "desconocid", "ninguno", "sconosciut", "nessuno", "onbekend", "geen", "desconhecid", "nenhum", "nieznan", "brak"].contains(where: { low.hasPrefix($0) }) { return "" }
        guard part.count > maximumLength else { return part }
        let cut = part.prefix(maximumLength + 1)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
    }

    private static func isWord(_ word: Substring) -> Bool { word.filter(\.isLetter).count >= 3 }

    private static func normalized(_ word: Substring) -> String {
        DocumentDates.flattened(String(word)).lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Whether every real word of `value` appears in the document's text.
    static func isWritten(_ value: String, in flatText: String) -> Bool {
        let words = value.split(whereSeparator: { $0.isWhitespace || $0 == "'" || $0 == "’" }).filter(isWord)
        return !words.isEmpty && words.allSatisfy { flatText.contains(normalized($0)) }
    }

    /// Drops the words the model invented; nothing that is not in the document may reach a file name.
    static func keepingWrittenWords(of value: String, in flatText: String) -> String {
        var words = value.split(separator: " ").filter { !isWord($0) || flatText.contains(normalized($0)) }
        while let last = words.last, !isWord(last) { words.removeLast() }
        while let first = words.first, !isWord(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Rejects empty model answers such as "1", "3100,00 EUR" or a copied instruction.
    static func isRealSubject(_ subject: String) -> Bool {
        subject.contains(/\p{L}{4}|[\p{Han}\p{Hiragana}\p{Katakana}]{2}/) && !DocumentDates.flattened(subject).lowercased().contains(/\b(mots|words|worter|worte|palabras|parole|woorden|palavras|slow|słow|slowa|słowa)\b/)
    }
}

/// Scores the dates written in a document to find the one it was issued on.
nonisolated enum DocumentDates {
    struct Candidate: Equatable, Sendable {
        let date: String
        let score: Double
        let position: Int
        var isCityDate = false
        var isDeadline = false
    }

    /// Month names and abbreviations without diacritics (the text is
    /// flattened first) for the OCR languages: French, English, German,
    /// Spanish, Italian, Dutch, Portuguese and Polish (nominative and
    /// genitive). Shared spellings such as "mai" or "mar" mean the same month
    /// in every language that has them.
    private static let months: [String: Int] = [
        // French
        "janvier": 1, "janv": 1, "fevrier": 2, "fevr": 2, "fev": 2, "mars": 3, "avril": 4, "avr": 4, "mai": 5, "juin": 6,
        "juillet": 7, "juil": 7, "aout": 8, "septembre": 9, "octobre": 10, "novembre": 11, "decembre": 12,
        // English
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6,
        "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9, "october": 10, "oct": 10,
        "november": 11, "nov": 11, "december": 12, "dec": 12,
        // German
        "januar": 1, "janner": 1, "februar": 2, "marz": 3, "mrz": 3, "juni": 6, "juli": 7, "oktober": 10, "okt": 10, "dezember": 12, "dez": 12,
        // Spanish
        "enero": 1, "ene": 1, "febrero": 2, "marzo": 3, "abril": 4, "abr": 4, "mayo": 5, "junio": 6, "julio": 7, "agosto": 8, "ago": 8,
        "septiembre": 9, "setiembre": 9, "octubre": 10, "noviembre": 11, "diciembre": 12, "dic": 12,
        // Italian
        "gennaio": 1, "gen": 1, "febbraio": 2, "aprile": 4, "maggio": 5, "mag": 5, "giugno": 6, "giu": 6, "luglio": 7, "lug": 7,
        "settembre": 9, "set": 9, "ottobre": 10, "ott": 10, "dicembre": 12,
        // Dutch
        "januari": 1, "februari": 2, "maart": 3, "mrt": 3, "mei": 5, "augustus": 8,
        // Portuguese
        "janeiro": 1, "fevereiro": 2, "marco": 3, "maio": 5, "junho": 6, "julho": 7, "setembro": 9, "outubro": 10, "out": 10, "novembro": 11, "dezembro": 12,
        // Polish
        "styczen": 1, "stycznia": 1, "sty": 1, "luty": 2, "lutego": 2, "lut": 2, "marzec": 3, "marca": 3, "kwiecien": 4, "kwietnia": 4, "kwi": 4,
        "maj": 5, "maja": 5, "czerwiec": 6, "czerwca": 6, "cze": 6, "lipiec": 7, "lipca": 7, "lip": 7, "sierpien": 8, "sierpnia": 8, "sie": 8,
        "wrzesien": 9, "wrzesnia": 9, "wrz": 9, "pazdziernik": 10, "pazdziernika": 10, "paz": 10, "listopad": 11, "listopada": 11, "lis": 11,
        "grudzien": 12, "grudnia": 12, "gru": 12
    ]
    private static func regex(_ pattern: String, ignoreCase: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }
    private static let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    private static let weekday = "(?i:(?:lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|monday|tuesday|wednesday|thursday|friday|saturday|sunday|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|lunes|martes|miercoles|jueves|viernes|sabado|domingo|lunedi|martedi|mercoledi|giovedi|venerdi|sabato|domenica|maandag|dinsdag|woensdag|donderdag|vrijdag|zaterdag|zondag|segunda-feira|terca-feira|quarta-feira|quinta-feira|sexta-feira|poniedzialek|wtorek|sroda|czwartek|piatek|sobota|niedziela),?\\s+)?"
    /// "12 March 2026", "12. März 2026", "1er mai 2026", "12 de marzo de 2026", "12 marca 2026 r."
    private static let textDate = regex("\\b(?<d>[0-3]?\\d)(?:er|st|nd|rd|th|\\.|º|°)?\\s*(?:de\\s+|of\\s+)?(?<m>\(monthNames))\\.?,?\\s+(?:de\\s+|del\\s+)?(?<y>(?:19|20)\\d\\d)\\b")
    /// "October 14, 2026", "March 3rd 2026"
    private static let monthFirstDate = regex("\\b(?<m>\(monthNames))\\.?\\s+(?<d>[0-3]?\\d)(?:st|nd|rd|th)?,?\\s+(?<y>(?:19|20)\\d\\d)\\b")
    /// Day first ("12.03.2026", "12/03/26"); a month above 12 means the US order.
    private static let numericDate = regex("(?<![\\d/.\\-])(?<d>[0-3]?\\d)\\s?[/.\\-]\\s?(?<m>[0-3]?\\d)\\s?[/.\\-]\\s?(?<y>(?:19|20)\\d\\d|\\d\\d)(?![\\d/\\-]|\\.\\d)")
    private static let isoDate = regex("(?<!\\d)(?<y>(?:19|20)\\d\\d)-(?<m>[01]\\d)-(?<d>[0-3]\\d)(?!\\d)")
    /// "2026年3月12日"
    private static let japaneseDate = regex("(?<y>(?:19|20)\\d\\d)\\s*年\\s*(?<m>[01]?\\d)\\s*月\\s*(?<d>[0-3]?\\d)\\s*日")
    /// "Lyon, le ", "Berlin, den ", "Madrid, a ", "Roma, li ", "Warszawa, dnia ", "Amsterdam, "
    private static let cityComma = regex("\\b(?<w>[A-Z][A-Za-z'\\-]+(?:[ \\-][A-Za-z'\\-]+){0,3})\\s*,\\s*(?:(?i:le|den|am|a|el|li|il|em|op|dnia)\\s+)?\(weekday)$", ignoreCase: false)
    private static let madeIn = regex("\\bfait\\s+a\\s+[A-Za-z'\\- ]{2,40},?\\s*le\\s+\(weekday)$")
    private static let cityLine = regex("^\\s*(?<w>[A-Z][A-Za-z'\\-]+(?:[ \\-][A-Za-z'\\-]+){0,3})\\s+(?i:le|den)\\s+\(weekday)$", ignoreCase: false)
    /// First words that announce something other than a place.
    private static let notCities: Set<String> = ["payable", "paye", "fait", "signe", "emis", "edite", "etabli", "envoye", "recu", "date", "livre", "preleve", "regle", "valable", "expire", "ne", "nee", "debite", "echu", "imprime",
                                                 "datum", "fecha", "data", "dated", "total", "betrag", "rechnung", "facture", "invoice", "factura", "fattura", "factuur", "fatura", "faktura", "importe", "importo", "bedrag", "valor", "kwota", "summe", "amount", "montant"]
    private static let wordLe = regex("\\b(?:le|den|am|on|el|il|op|em|dnia)\\s*$")
    private static let goodContext = regex("(date\\s+(de\\s+(la\\s+)?)?(facture|facturation|emission|edition|document|courrier|envoi|piece|releve|avis)|emis\\s+le|edite\\s+le|etabli\\s+le|en\\s+date\\s+du|date\\s*:|dated|(invoice|issue|letter|statement)\\s+date|date\\s+of\\s+issue|datum\\s*:|(rechnungs|ausstellungs|beleg|brief|bescheid)datum|ausgestellt\\s+am|erstellt\\s+am|fecha\\s*:|fecha\\s+de\\s+(emision|factura|expedicion)|emitid[oa]\\s+(el|em)|data\\s*:|data\\s+(di\\s+emissione|fattura|del\\s+documento|de\\s+emissao|wystawienia)|emess[oa]\\s+il|factuurdatum|datum\\s+van\\s+uitgifte|wystawiono\\s+dnia)\\s*[:\\-]?\\s*$")
    private static let badContext = regex("(echeance|a\\s+payer\\s+avant|avant\\s+le|payer\\s+le|date\\s+limite|limite|valable|validite|expir|ne\\s*\\(?e?\\)?\\s+le|naissance|periode|du\\s+\\S+\\s+au|jusqu|prelev|debit|depuis|a\\s+compter|mise\\s+en\\s+service|souscri|contrat\\s+du|prochain|rendez|rdv|\\b(?:decret|loi|arrete|circulaire)\\b[^.]{0,40}\\bdu\\s*$"
        + "|\\bdue\\b|pay(able)?\\s+by|\\bbefore\\b|\\buntil\\b|valid\\s+(until|through)|\\bborn\\b|birth|\\bperiod\\b|from\\s+\\S+\\s+to|\\bsince\\b|starting|effective"
        + "|fallig|zahlbar|zahlungsziel|\\bbis(\\s+(zum|zur|spatestens))?\\s*$|spatestens|\\bfrist|gultig|geboren|\\bgeb\\.|zeitraum|vom\\s+\\S+\\s+bis|leistungs|abbuchung|lastschrift|ab\\s+dem|vertragsbeginn|(ihr|unser|ihrem|unserem)\\s+schreiben\\s+vom"
        + "|vencimiento|antes\\s+del|\\bhasta\\b|nacimiento|periodo|\\bdesde\\b"
        + "|scadenza|\\bentro\\b|fino\\s+al|nat[oa]\\s+il|nascita|\\bdal\\s+\\S+\\s+al"
        + "|vervaldatum|uiterlijk|geldig\\s+tot|tot\\s+en\\s+met"
        + "|vencimento|\\bate\\b|nascimento"
        + "|\\btermin\\b|do\\s+dnia|wazn|urodzeni|\\bokres)")

    static func flattened(_ text: String) -> String { text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")) }

    private static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }()
    static func iso(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Every plausible date in `text`, best first. Pages are separated by form feeds.
    static func candidates(in text: String, reference: Date) -> [Candidate] {
        let flat = flattened(text) as NSString
        let firstPageLength = { let r = flat.range(of: "\u{c}"); return r.location == NSNotFound || r.location == 0 ? flat.length : r.location }()
        let latest = iso(calendar.date(byAdding: .day, value: 2, to: reference) ?? reference)
        let referenceYear = calendar.component(.year, from: reference)
        var found: [String: Candidate] = [:]

        func add(_ match: NSTextCheckingResult, kind: String) {
            func group(_ name: String) -> String { flat.substring(with: match.range(withName: name)) }
            let dayText = group("d").lowercased()
            let yearText = group("y")
            guard let parsedYear = Int(yearText) else { return }
            var day: Int?, month: Int?
            if kind == "text" { day = Int(dayText); month = months[group("m").lowercased()] }
            else { day = Int(dayText); month = Int(group("m")) }
            // 10/14/2025: no 14th month, so the US order.
            if kind == "numeric", let d = day, let m = month, m > 12, d <= 12 { day = m; month = d }
            guard let day, let month else { return }
            var year = parsedYear
            if year < 100 { year += year <= (referenceYear % 100) + 1 ? 2000 : 1900 }
            let components = DateComponents(year: year, month: month, day: day)
            guard components.isValidDate(in: calendar), year >= 1980 else { return }
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            guard date <= latest else { return }

            var score = 1.0
            if kind == "text" { score += 1 }
            if kind == "numeric" && yearText.count == 2 { score -= 0.5 }
            let start = max(0, match.range.location - 70)
            let before = flat.substring(with: NSRange(location: start, length: match.range.location - start))
            let lineBefore = before.components(separatedBy: .newlines).last ?? before
            let lineRange = NSRange(lineBefore.startIndex..., in: lineBefore)
            func isPlace(_ found: NSTextCheckingResult?) -> Bool {
                guard let found, let wordRange = Range(found.range(withName: "w"), in: lineBefore) else { return false }
                return !notCities.contains(String(lineBefore[wordRange].split(separator: " ")[0]).lowercased())
            }
            var isCity = isPlace(cityComma.firstMatch(in: lineBefore, range: lineRange)) || madeIn.firstMatch(in: lineBefore, range: lineRange) != nil
            if !isCity { isCity = isPlace(cityLine.firstMatch(in: lineBefore, range: lineRange)) }
            if isCity { score += 10 } else if wordLe.firstMatch(in: lineBefore, range: lineRange) != nil { score += 2 }
            if goodContext.firstMatch(in: lineBefore, range: lineRange) != nil { score += 6 }
            let isDeadline = badContext.firstMatch(in: lineBefore, range: lineRange) != nil
            if isDeadline { score -= 6 }
            if match.range.location < firstPageLength {
                score += 1
                if Double(match.range.location) < Double(firstPageLength) * 0.35 { score += 1.5 }
            }
            found["\(date)@\(match.range.location)"] = Candidate(date: date, score: score, position: match.range.location, isCityDate: isCity, isDeadline: isDeadline)
        }
        let whole = NSRange(location: 0, length: flat.length)
        textDate.enumerateMatches(in: flat as String, range: whole) { match, _, _ in if let match { add(match, kind: "text") } }
        monthFirstDate.enumerateMatches(in: flat as String, range: whole) { match, _, _ in if let match { add(match, kind: "text") } }
        japaneseDate.enumerateMatches(in: flat as String, range: whole) { match, _, _ in if let match { add(match, kind: "iso") } }
        isoDate.enumerateMatches(in: flat as String, range: whole) { match, _, _ in if let match { add(match, kind: "iso") } }
        numericDate.enumerateMatches(in: flat as String, range: whole) { match, _, _ in if let match { add(match, kind: "numeric") } }
        return found.values.sorted { ($0.score, $1.position) > ($1.score, $0.position) }
    }

    static func choose(_ candidates: [Candidate], modelDate: String, scanDate: Date) -> String {
        let best = candidates.first
        if let best, best.isCityDate { return best.date }
        // Neither an invented date nor a deadline or a reference to a law.
        if candidates.contains(where: { $0.date == modelDate && !$0.isDeadline }) { return modelDate }
        if let best, best.score >= 2 { return best.date }
        return iso(scanDate)
    }
}
