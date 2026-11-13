import XCTest
@testable import Scan

final class OCRmyPDFRunnerTests: XCTestCase {
    func testAppleOCRArgumentsSelectLiveText() {
        let input = URL(fileURLWithPath: "/tmp/in.pdf"), output = URL(fileURLWithPath: "/tmp/out.pdf")
        let tesseract = OCRmyPDFRunner.arguments(input: input, output: output, language: .german)
        XCTAssertFalse(tesseract.contains("--ocr-engine"))
        XCTAssertEqual(tesseract.suffix(2), ["/tmp/in.pdf", "/tmp/out.pdf"])
        let apple = OCRmyPDFRunner.arguments(input: input, output: output, language: .german, usesAppleOCR: true)
        XCTAssertEqual(apple.firstIndex(of: "--ocr-engine").map { apple[$0 + 1] }, "appleocr")
        XCTAssertEqual(apple.firstIndex(of: "--appleocr-recognition-mode").map { apple[$0 + 1] }, "livetext")
        XCTAssertEqual(apple.suffix(2), ["/tmp/in.pdf", "/tmp/out.pdf"], "input and output stay last")
    }

    func testALiveTextTimeoutIsRecognizedSoTesseractCanTakeOver() {
        let timeout = OCRmyPDFRunner.failure(errorOutput: "...\nTimeout in VKCImageAnalyzerRequest\n", status: 1, fileName: "a.pdf")
        XCTAssertTrue(timeout is OCRmyPDFRunner.LiveTextTimeout)
        let other = OCRmyPDFRunner.failure(errorOutput: "first\nPriorOcrFoundError: page already has text", status: 6, fileName: "a.pdf")
        XCTAssertFalse(other is OCRmyPDFRunner.LiveTextTimeout)
        XCTAssertTrue(other.localizedDescription.contains("a.pdf"))
    }

    func testCustomPathWinsAndAMissingOneFallsBackToTheSearch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OCRmyPDFRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let custom = folder.appendingPathComponent("my-ocrmypdf"), searched = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: searched, withIntermediateDirectories: true)
        for file in [custom, searched.appendingPathComponent("ocrmypdf")] {
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        XCTAssertEqual(OCRmyPDFRunner.locate(customPath: custom.path, in: [searched.path], environment: [:])?.executableURL.lastPathComponent, "my-ocrmypdf")
        XCTAssertEqual(OCRmyPDFRunner.locate(customPath: folder.appendingPathComponent("missing").path, in: [searched.path], environment: [:])?.executableURL.lastPathComponent, "ocrmypdf")
        XCTAssertNil(OCRmyPDFRunner.locate(in: [folder.appendingPathComponent("empty").path], environment: [:]))
    }

    func testSettingsWithoutAnEngineKeepTheirLanguageAndUseAutomatic() throws {
        let saved = Data(#"{"language":"dutch","runOCRmyPDF":true}"#.utf8)
        let settings = try JSONDecoder().decode(OCRSettings.self, from: saved)
        XCTAssertEqual(settings.language, .dutch)
        XCTAssertEqual(settings.engine, .automatic)
        XCTAssertEqual(settings.ocrmypdfPath, "")
    }
}
