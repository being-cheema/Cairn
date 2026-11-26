import XCTest
import WebKit
@testable import Search

/// Where an agent may not go: this Mac and the networks around it.
@MainActor
final class AgentNetworkTests: XCTestCase {
    private func ip(_ host: String) -> Bool { PrivateNetwork.isPrivate(host: host) }

    func testPrivateHostsInEveryForm() {
        for host in ["localhost", "LOCALHOST", "localhost.", "app.localhost", "printer.local", "db.internal", "nas.home.arpa",
                     "127.0.0.1", "127.255.255.254", "127.1", "2130706433", "0x7f.0.0.1", "0x7f000001", "0177.0.0.1", "0.0.0.0", "0",
                     "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "100.127.255.255",
                     "224.0.0.1", "255.255.255.255", "::1", "[::1]", "::", "fe80::1", "fe80::1%en0", "fc00::1", "fd12:3456::1",
                     "::ffff:127.0.0.1", "::ffff:192.168.0.1", "64:ff9b::7f00:1", "2002:c0a8:0101::1", "ff02::1",
                     "ｌｏｃａｌｈｏｓｔ", "127。0。0。1", "%6c%6fcalhost", ""] {
            XCTAssertTrue(ip(host), host)
        }
    }

    func testPublicHostsStayPublic() {
        for host in ["example.com", "localhost.example.com", "mylocal", "local.example.org", "internal.example.com",
                     "8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.63.0.1", "100.128.0.1", "11.0.0.1",
                     "198.18.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8", "64:ff9b::808:808", "10.example.com", "face.b00c"] {
            XCTAssertFalse(ip(host), host)
        }
    }

    func testRefusedAddresses() {
        for text in ["http://localhost:3000/", "http://127.0.0.1/", "http://2130706433/", "https://192.168.1.1", "http://[::1]:8080/",
                     "router.local", "http://169.254.169.254/latest/meta-data/"] {
            XCTAssertNotNil(AgentRules.webAddress(text), text)
            XCTAssertNil(AgentRules.address(text), text)
        }
        XCTAssertNotNil(AgentRules.address("https://example.com/"))
    }

    func testOnlyTheHostsLetThrough() {
        let url = URL(string: "http://127.0.0.1:8080/")!
        XCTAssertTrue(PrivateNetwork.refuses(url, allowed: []))
        XCTAssertFalse(PrivateNetwork.refuses(url, allowed: ["127.0.0.1"]))
        XCTAssertTrue(PrivateNetwork.refuses(URL(string: "ws://localhost/x")!, allowed: ["127.0.0.1"]))
        XCTAssertFalse(PrivateNetwork.refuses(URL(string: "data:text/plain,x")!, allowed: []))
    }

    private func resolves(_ addresses: [String], within: TimeInterval = 2, delay: TimeInterval = 0) -> Bool? {
        let done = expectation(description: "looked up")
        var said: Bool?
        PrivateNetwork.resolvesPrivately("name.example", within: within, lookUp: { _ in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return addresses.compactMap { PrivateNetwork.bytes(of: $0) }
        }) { said = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return said
    }

    func testANameThatPointsInside() {
        XCTAssertEqual(resolves(["93.184.216.34"]), false)
        XCTAssertEqual(resolves(["93.184.216.34", "127.0.0.1"]), true, "any private address is enough")
        XCTAssertEqual(resolves(["::1"]), true)
        XCTAssertEqual(resolves([]), false, "nowhere to go")
        XCTAssertEqual(resolves(["8.8.8.8"], within: 0.1, delay: 0.6), true, "no answer in time counts as private")
    }

    func testTheMacsOwnLookup() {
        XCTAssertTrue(PrivateNetwork.lookUp("localhost").contains { PrivateNetwork.isPrivate(bytes: $0) })
    }

    func testWebKitCompilesTheRules() {
        for allowed in [Set<String>(), ["127.0.0.1"]] {
            let done = expectation(description: "compiled")
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "agent-private-network-unit",
                encodedContentRuleList: PrivateNetworkRules.source(allowing: allowed)
            ) { list, error in
                XCTAssertNotNil(list, "\(String(describing: error))")
                done.fulfill()
            }
            self.wait(for: [done], timeout: 30)
        }
    }

    /// The rule list's own patterns, tried as ordinary ones.
    func testTheRulesCatchTheirAddresses() {
        func blocked(_ url: String) -> Bool {
            PrivateNetworkRules.hosts.contains { url.range(of: "^[a-z]+://\($0)[:/]", options: .regularExpression) != nil }
        }
        for url in ["http://localhost/", "http://localhost:3000/a", "ws://127.0.0.1:9/", "https://192.168.0.1/", "http://10.1.2.3/",
                    "http://172.20.0.1/", "http://169.254.169.254/", "http://100.100.1.1/", "http://[::1]/", "http://[fe80::1]/",
                    "http://[fd00::1]:80/", "http://[::ffff:7f00:1]/", "http://a.local/"] {
            XCTAssertTrue(blocked(url), url)
        }
        for url in ["https://example.com/", "https://localhost.example.com/", "https://10.example.com/", "https://127.0.0.1.example.com/",
                    "http://172.32.0.1/", "http://[2606:4700::1111]/", "https://local.example.org/", "https://a.com/?u=http://localhost/"] {
            XCTAssertFalse(blocked(url), url)
        }
    }

    // MARK: - what leaves

    func testWhatIsSentIsHeld() {
        let url = URL(string: "https://Shop.Example.com/x?token=abc")!
        for method in ["POST", "post", "PUT", "PATCH", "DELETE"] {
            XCTAssertEqual(AgentGate.hold(sending: method, to: url)?.reason, .submit, method)
        }
        for method in ["GET", "get", "HEAD", "OPTIONS"] {
            XCTAssertNil(AgentGate.hold(sending: method, to: url), method)
        }
        XCTAssertEqual(AgentGate.hold(sending: "POST", to: url)?.summary, "Send a form: this page is sending data to shop.example.com")
    }
}
