import XCTest
@testable import Search

final class PasswordGeneratorTests: XCTestCase {
    func testRandomHasEveryKindAndTheLength() {
        for length in [12, 20, 40] {
            let value = PasswordGenerator.make(.init(style: .random, length: length, symbols: true))
            XCTAssertEqual(value.count, length)
            XCTAssertTrue(value.contains { $0.isLowercase }); XCTAssertTrue(value.contains { $0.isUppercase })
            XCTAssertTrue(value.contains { $0.isNumber }); XCTAssertTrue(value.contains { "!#$%&*+-=?@^_".contains($0) })
        }
    }

    func testNoLookAlikesAndNoSymbolsWhenOff() {
        for _ in 0..<200 {
            let value = PasswordGenerator.make(.init(style: .random, length: 40, symbols: false))
            XCTAssertFalse(value.contains { "lIO01".contains($0) })
            XCTAssertTrue(value.allSatisfy { $0.isLetter || $0.isNumber })
        }
    }

    func testPassphraseShape() {
        let value = PasswordGenerator.make(.init(style: .phrase, words: 6))
        let parts = value.split(separator: "-")
        XCTAssertEqual(parts.count, 7, "six words and a number")
        XCTAssertEqual(parts.dropLast().filter { $0.first?.isUppercase == true }.count, 1)
        XCTAssertNotNil(Int(parts.last ?? ""))
    }

    func testTheWordListIsCleanAndBigEnough() {
        let list = PasswordWords.list
        XCTAssertEqual(Set(list).count, list.count, "no word twice")
        XCTAssertGreaterThanOrEqual(list.count, 500)
        XCTAssertTrue(list.allSatisfy { (3...7).contains($0.count) && $0.allSatisfy { $0.isLowercase && $0.isASCII } })
    }

    func testValuesDiffer() {
        XCTAssertEqual(Set((0..<50).map { _ in PasswordGenerator.make() }).count, 50)
    }

    func testStrengthWords() {
        XCTAssertEqual(PasswordGenerator.strength(PasswordGenerator.bits(.init(style: .random, length: 20))), "Very strong")
        XCTAssertEqual(PasswordGenerator.strength(PasswordGenerator.bits(.init(style: .random, length: 12, symbols: false))), "Strong")
    }
}
