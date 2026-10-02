import Foundation
import XCTest
import OrbitCore
@testable import OrbitDrop

final class OutputNamingTests: EngineTestCase, @unchecked Sendable {
    func testSameNameCannotOverwriteOriginal() throws {
        let source = directory.appendingPathComponent("report.txt")
        try Data("original".utf8).write(to: source)
        let output = try OutputTransaction.write(source: source, outputDirectory: nil,
                                                 stem: "report", extension: "txt",
                                                 writer: { try Data("new".utf8).write(to: $0) }, validate: { _ in })
        XCTAssertEqual(output.lastPathComponent, "report (2).txt")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "new")
    }

    func testConcurrentWritersNeverOverwriteEachOther() async throws {
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let outputs = try await withThrowingTaskGroup(of: URL.self) { group in
            for value in 0..<16 {
                group.addTask {
                    try OutputTransaction.write(source: source, outputDirectory: nil,
                                                stem: "result", extension: "txt",
                                                writer: { try Data("\(value)".utf8).write(to: $0) }, validate: { _ in })
                }
            }
            var outputs: [URL] = []
            for try await output in group { outputs.append(output) }
            return outputs
        }
        XCTAssertEqual(Set(outputs).count, 16)
        let contents = try outputs.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(contents), Set((0..<16).map(String.init)))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testValidationFailureCleansStagingAndPublishesNothing() throws {
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        XCTAssertThrowsError(try OutputTransaction.write(source: source, outputDirectory: nil,
                                                         stem: "result", extension: "txt",
                                                         writer: { try Data("bad".utf8).write(to: $0) },
                                                         validate: { _ in throw OrbitError.invalidInput("Invalid fixture output") }))
        try assertDirectoryContainsExactly([source.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testUnsafeNamesAndSymlinkOutputsAreRejected() throws {
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        for stem in ["../escape", "bad/name", "bad\nname", ".", ""] {
            XCTAssertThrowsError(try OutputTransaction(source: source, outputDirectory: nil, stem: stem, extension: "txt"))
        }
        XCTAssertThrowsError(try OutputTransaction.write(source: source, outputDirectory: nil,
                                                         stem: "result", extension: "txt",
                                                         writer: { try FileManager.default.createSymbolicLink(at: $0, withDestinationURL: source) },
                                                         validate: { _ in }))
        try assertDirectoryContainsExactly([source.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }
}
