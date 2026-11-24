import XCTest
@testable import Search

final class PasswordHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, _ password: String, changed: Date? = nil, clear: Bool = false) -> PasswordHealth.Entry {
        PasswordHealth.Entry(id: id, name: id, user: "me", password: password, changed: changed, clear: clear)
    }

    func testWeakness() {
        XCTAssertEqual(PasswordHealth.weakness("abc12"), "Short")
        XCTAssertEqual(PasswordHealth.weakness("Password"), "Common")
        XCTAssertEqual(PasswordHealth.weakness("Password123!"), "Common")
        XCTAssertEqual(PasswordHealth.weakness("aaaaaaaabbbbbbbb"), "Repeats itself")
        XCTAssertNil(PasswordHealth.weakness("k7#Qm2vLx9!pRw"))
    }

    func testReusedCountsEveryAccountSharingOne() {
        let report = PasswordHealth.check([entry("a", "k7#Qm2vLx9!pRw"), entry("b", "k7#Qm2vLx9!pRw"), entry("c", "t9$Zr4nBw2&yHc")], now: now)
        XCTAssertEqual(report.count(.reused), 2)
        XCTAssertEqual(report.checked, 3)
        XCTAssertFalse(report.flagged.contains("c"))
        XCTAssertTrue(report.findings.first?.why.contains("Same password on 2 accounts") ?? false)
    }

    func testOldOnlyWhenTheDateIsKnown() {
        let longAgo = now.addingTimeInterval(-800 * 24 * 3600)
        let report = PasswordHealth.check([entry("known", "k7#Qm2vLx9!pRw", changed: longAgo),
                                           entry("unknown", "t9$Zr4nBw2&yHc"),
                                           entry("fresh", "w5!Hd8sJq3@fTn", changed: now.addingTimeInterval(-3600))], now: now)
        XCTAssertEqual(report.flagged, ["known"])
        XCTAssertEqual(report.findings.first?.kinds, [.old])
    }

    func testPlainHttpAndTheWorstFirst() {
        let report = PasswordHealth.check([entry("fine", "k7#Qm2vLx9!pRw", clear: true), entry("bad", "123456", clear: true)], now: now)
        XCTAssertEqual(report.findings.map(\.id), ["bad", "fine"])
        XCTAssertEqual(report.count(.plain), 2)
        XCTAssertEqual(report.count(.weak), 1)
    }

    func testAReportHoldsNoPassword() {
        let report = PasswordHealth.check([entry("a", "123456")], now: now)
        XCTAssertFalse("\(report)".contains("123456"))
    }
}
