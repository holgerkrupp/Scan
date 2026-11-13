import XCTest
@testable import Scan

@MainActor final class DocumentAnalysisTests: XCTestCase {
    private let scanDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 9, hour: 12).date!

    private struct StubModel: DocumentModel {
        let answer: DocumentModelReply?
        func reply(toPrompt prompt: String) async -> DocumentModelReply? { answer }
    }

    /// The letter's own date beats a due date, a birth date or a period, in
    /// every OCR language; the model's answer is not needed for that.
    func testLetterDateIsFoundInEveryOCRLanguage() {
        let letters: [(String, String)] = [
            ("Rechnung\nBerlin, den 12. März 2026\nZahlbar bis 30.03.2026", "2026-03-12"),
            ("Beitragsrechnung\nRechnungsdatum: 05.02.2026\nLeistungszeitraum vom 01.01.2026 bis 31.12.2026\nGeboren am 14.07.1980", "2026-02-05"),
            ("Invoice\nOctober 14, 2025\nPayment due: November 2, 2025", "2025-10-14"),
            ("Statement\nDate of birth: 03/04/1975\nIssue date: 10/14/2025", "2025-10-14"),
            ("Factura\nMadrid, a 12 de marzo de 2026\nFecha de vencimiento: 30/03/2026", "2026-03-12"),
            ("Fattura\nRoma, 12 marzo 2026\nScadenza: 30/03/2026", "2026-03-12"),
            ("Factuur\nAmsterdam, 12 maart 2026\nVervaldatum: 30-03-2026", "2026-03-12"),
            ("Fatura\nLisboa, 12 de março de 2026\nData de vencimento: 30/03/2026", "2026-03-12"),
            ("Faktura\nWarszawa, dnia 12 marca 2026 r.\nTermin płatności: 30.03.2026", "2026-03-12"),
            ("Facture\nLyon, le 1er avril 2026\nÀ payer avant le 30/04/2026", "2026-04-01"),
            ("請求書\n2026年3月12日\n支払期限 2026年3月31日", "2026-03-12"),
        ]
        for (text, expected) in letters {
            let candidates = DocumentDates.candidates(in: text, reference: scanDate)
            XCTAssertEqual(DocumentDates.choose(candidates, modelDate: "", scanDate: scanDate), expected, text)
        }
    }

    func testCapitalizedWordsBeforeAComaAreNotPlaces() {
        let candidates = DocumentDates.candidates(in: "Datum, 05.02.2026\nBerlin, den 12.03.2026", reference: scanDate)
        XCTAssertEqual(candidates.first?.date, "2026-03-12")
        XCTAssertEqual(candidates.filter(\.isCityDate).map(\.date), ["2026-03-12"])
    }

    func testCityDateWinsOverADeadline() {
        let text = "Facture\nLyon, le 20 avril 2024\nDate limite de paiement : 15/05/2024"
        let candidates = DocumentDates.candidates(in: text, reference: scanDate)
        XCTAssertEqual(DocumentDates.choose(candidates, modelDate: "2024-05-15", scanDate: scanDate), "2024-04-20")
    }

    func testModelDateIsRejectedWhenItIsADeadlineOrInvented() {
        let candidates = DocumentDates.candidates(in: "Date limite de paiement : 15/05/2024", reference: scanDate)
        XCTAssertEqual(DocumentDates.choose(candidates, modelDate: "2024-05-15", scanDate: scanDate), "2026-11-09")
        XCTAssertEqual(DocumentDates.choose([], modelDate: "2001-01-01", scanDate: scanDate), "2026-11-09")
    }

    func testFutureDatesAreIgnored() {
        XCTAssertTrue(DocumentDates.candidates(in: "le 20 avril 2030", reference: scanDate).isEmpty)
    }

    func testPersonMatchesReorderedNamesAndAccents() {
        let list = "Léa = Léa Dupont, Dupont Léa\nMarc"
        XCTAssertEqual(DocumentAnalysis.person(in: "Patient : DUPONT, LEA", list: list), "Léa")
        XCTAssertEqual(DocumentAnalysis.person(in: "Bonjour marc", list: list), "Marc")
        XCTAssertEqual(DocumentAnalysis.person(in: "Bonjour Paul", list: list), "")
    }

    func testAnalysisCleansTheModelReply() async {
        let reply = DocumentModelReply(date: "", sender: "EDF", type: "Facture", subject: "Facture électricité novembre")
        let metadata = await DocumentAnalysis.analyze(text: "EDF vous adresse sa facture, électricité de novembre", scanDate: scanDate, people: "", model: StubModel(answer: reply))
        XCTAssertEqual(metadata.subject, "électricité novembre")
        XCTAssertEqual(metadata.date, "2026-11-09")
        XCTAssertEqual(metadata.sender, "EDF")
    }

    func testWordsNotInTheDocumentAreDropped() async {
        let reply = DocumentModelReply(date: "", sender: "Banque Inventée", type: "Ordonnance", subject: "Journée défense imaginaire et citoyenneté")
        let metadata = await DocumentAnalysis.analyze(text: "Ordre de convocation, Journée défense et citoyenneté", scanDate: scanDate, people: "", model: StubModel(answer: reply))
        XCTAssertEqual(metadata.type, "")
        XCTAssertEqual(metadata.sender, "")
        XCTAssertEqual(metadata.subject, "Journée défense et citoyenneté")
    }

    func testAnalysisWithoutModelStillDatesTheDocument() async {
        let metadata = await DocumentAnalysis.analyze(text: "Paris, le 3 mai 2025", scanDate: scanDate, people: "", model: StubModel(answer: nil))
        XCTAssertEqual(metadata.date, "2025-05-03")
        XCTAssertFalse(metadata.isDescriptive)
    }

    func testLongValuesAreCutBetweenWords() {
        XCTAssertEqual(DocumentAnalysis.cleaned("CONVOCATION A LA COMPETITION TRISPORTS", maximumLength: 30), "CONVOCATION A LA COMPETITION")
    }

    func testMeaninglessSubjectsAreRejected() {
        XCTAssertFalse(DocumentAnalysis.isRealSubject("3100,00 EUR"))
        XCTAssertFalse(DocumentAnalysis.isRealSubject("2 à 5 mots"))
        XCTAssertTrue(DocumentAnalysis.isRealSubject("Assurance habitation"))
    }

    /// 2026-11-09 10:00:00 in the Mac's time zone.
    private let exportDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 9, hour: 10).date!

    private func name(_ template: String, _ naming: DocumentNaming = DocumentNaming(), dateFormat: String = ExportSettings.defaultDateFormat, timeFormat: String = ExportSettings.defaultTimeFormat) -> String {
        ScanOutputWriter.renderName(ExportSettings(filenameTemplate: template, dateFormat: dateFormat, timeFormat: timeFormat), date: exportDate, naming: naming, page: nil, side: nil)
    }

    func testEmptyTokensLeaveNoDoubledSeparators() {
        let naming = DocumentNaming(name: nil, metadata: DocumentMetadata(date: "2026-03-12", sender: "Stadtwerke", type: "Rechnung", subject: "", person: ""))
        XCTAssertEqual(name("{docdate} {sender} {type} {subject} {person}", naming), "2026-03-12 Stadtwerke Rechnung")
        XCTAssertEqual(name("{docdate}-{type}-{subject}", naming), "2026-03-12-Rechnung")
        XCTAssertEqual(name("{date}-{time}-{name}"), "2026-11-09-10-00-00-Scan")
        XCTAssertEqual(name("{docdate} {subject}"), "2026-11-09")
    }

    func testDateAndTimeFormatsShapeTheFileName() {
        let naming = DocumentNaming(name: nil, metadata: DocumentMetadata(date: "2024-03-07", type: "Rechnung"))
        XCTAssertEqual(name("{docdate} {date} {time}", naming, dateFormat: "dd.MM.yyyy", timeFormat: "HH'h'mm"), "07.03.2024 09.11.2026 10h00")
        XCTAssertEqual(name("{docdate}_{type}", naming, dateFormat: "yyyyMMdd"), "20240307_Rechnung")
        XCTAssertEqual(name("{date} {time}", dateFormat: " ", timeFormat: ""), "2026-11-09 10-00-00", "an empty format uses the default")
    }

    func testProfilesSavedWithoutDateFormatsStillLoad() throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportSettings(filenameTemplate: "Mine-{date}"))) as? [String: Any])
        saved.removeValue(forKey: "dateFormat")
        saved.removeValue(forKey: "timeFormat")
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(decoded.filenameTemplate, "Mine-{date}")
        XCTAssertEqual(decoded.dateFormat, ExportSettings.defaultDateFormat)
        XCTAssertEqual(decoded.timeFormat, ExportSettings.defaultTimeFormat)
    }

    func testSettingsSavedBeforeThePeopleListStillLoad() throws {
        let saved = Data(#"{"language":"french","runOCRmyPDF":false}"#.utf8)
        let settings = try JSONDecoder().decode(OCRSettings.self, from: saved)
        XCTAssertEqual(settings.language, .french)
        XCTAssertFalse(settings.runOCRmyPDF)
        XCTAssertEqual(settings.people, "")
    }
}
