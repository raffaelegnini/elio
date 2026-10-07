import Foundation
import Testing
@testable import ElioPhone

/// Pairing decides where the token (and everything the user says) goes: these links must never reach another host.
struct PairingTests {
    let token = "abcdefABCDEF0123456789_-abcdefABCDEF0123456789"

    @Test func acceptsTheMacLink() throws {
        let p = try #require(Pairing.parse("https://mac.tail1234.ts.net/#pair=\(token)"))
        #expect(p.host == "mac.tail1234.ts.net")
        #expect(p.token == token)
        #expect(p.baseURL.absoluteString == "https://mac.tail1234.ts.net/")
        #expect(p.socketURL.absoluteString == "wss://mac.tail1234.ts.net/ws")
    }

    @Test func normalizesCaseAndTrailingDot() throws {
        let p = try #require(Pairing.parse("elio://pair?host=MAC.Tail1234.TS.NET.&token=\(token)"))
        #expect(p.host == "mac.tail1234.ts.net")
    }

    @Test func acceptsElioLinkWrapper() throws {
        let link = "https://mac.tail1234.ts.net/#pair=\(token)".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(Pairing.parse("elio://pair?link=\(link)")?.host == "mac.tail1234.ts.net")
    }

    @Test(arguments: [
        "evil.com/x.ts.net", "evil.com?.ts.net", "evil.com#.ts.net", "user@evil.com:1@x.ts.net",
        "evil.com%2F.ts.net", "evil.com\\.ts.net", "evil .ts.net", "évil.ts.net", "ts.net", ".ts.net",
        "evil.com", "evil.com:443", "evil.ts.net.evil.com",
    ])
    func rejectsHostsThatAreNotTheTailnet(_ host: String) {
        #expect(Pairing.parse("elio://pair?host=\(host.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&token=\(token)") == nil)
        #expect(Pairing.parse("elio://pair?host=\(host)&token=\(token)") == nil)
        #expect(Pairing.parse(token, fallbackHost: host) == nil)
    }

    @Test(arguments: [
        "https://evil.com/x.ts.net#pair=TOKEN", "https://evil.com?.ts.net#pair=TOKEN", "https://evil.com#.ts.net&pair=TOKEN",
        "https://user@evil.com:1@x.ts.net/#pair=TOKEN", "https://x.ts.net@evil.com/#pair=TOKEN", "http://mac.tail1234.ts.net/#pair=TOKEN",
        "javascript:alert(1)//x.ts.net#pair=TOKEN",
    ])
    func rejectsCraftedLinks(_ link: String) {
        let p = Pairing.parse(link.replacingOccurrences(of: "TOKEN", with: token))
        #expect(p == nil || (p!.baseURL.host() == "mac.tail1234.ts.net" && p!.isTailnet), "\(link) -> \(String(describing: p))")
        if let p { #expect(p.baseURL.host()?.hasSuffix(".ts.net") == true) }
    }

    @Test func rejectsBadTokens() {
        #expect(Pairing.parse("https://mac.tail1234.ts.net/#pair=short") == nil)
        #expect(Pairing.parse("elio://pair?host=mac.tail1234.ts.net&token=\(token)%0D%0AX-Evil:1") == nil)
    }

    @Test func advancedPathAllowsOtherHostsButStillStrict() {
        #expect(Pairing.parse(token, fallbackHost: "mac.local:8443", allowAnyHost: true)?.baseURL.absoluteString == "https://mac.local:8443/")
        #expect(Pairing.parse(token, fallbackHost: "user@evil.com", allowAnyHost: true) == nil)
        #expect(Pairing.parse(token, fallbackHost: "evil.com:99999", allowAnyHost: true) == nil)
        #expect(Pairing.parse(token, fallbackHost: "evil.com/x", allowAnyHost: true)?.host != "evil.com/x")
    }

    @Test func linksNeverPairOtherHostsWithoutAdvanced() {
        #expect(Pairing.parse("https://mac.local/#pair=\(token)") == nil)
        #expect(Pairing.parse("https://mac.local/#pair=\(token)", allowAnyHost: true)?.host == "mac.local")
    }
}
