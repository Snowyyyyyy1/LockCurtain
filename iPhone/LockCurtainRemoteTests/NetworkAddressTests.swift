import Foundation
import Testing
@testable import LockCurtain

/// 网络地址的解析 / 存取，以及「蓝牙优先、什么时候该开网络」的纯规则
struct NetworkAddressTests {
    @Test
    func parsesIPv4() {
        let a = NetworkAddress.parse("192.168.1.23:52811")
        #expect(a == NetworkAddress(host: "192.168.1.23", port: 52811))
        #expect(a?.text == "192.168.1.23:52811")
        #expect(NetworkAddress.parse("100.101.102.103:49200")?.port == 49200)
    }

    @Test
    func parsesBracketedIPv6() {
        let a = NetworkAddress.parse("[fd7a:115c:a1e0::1]:52811")
        #expect(a?.host == "fd7a:115c:a1e0::1")
        #expect(a?.port == 52811)
        #expect(a?.isIPv6 == true)
        #expect(a?.text == "[fd7a:115c:a1e0::1]:52811")
        #expect(NetworkAddress.parse("[::1]:80")?.host == "::1")
    }

    @Test
    func parsesHostnames() {
        #expect(NetworkAddress.parse("my-mac.local:52811") == NetworkAddress(host: "my-mac.local", port: 52811))
        #expect(NetworkAddress.parse("mac.tail1234.ts.net:49300")?.host == "mac.tail1234.ts.net")
        #expect(NetworkAddress.parse("studio:1")?.port == 1)
        #expect(NetworkAddress.parse("studio:65535")?.port == 65535)
    }

    @Test
    func trimsWhitespace() {
        #expect(NetworkAddress.parse("  192.168.1.23:52811 \n") == NetworkAddress(host: "192.168.1.23", port: 52811))
    }

    @Test
    func rejectsBadPorts() {
        #expect(NetworkAddress.parse("192.168.1.23:0") == nil)
        #expect(NetworkAddress.parse("192.168.1.23:70000") == nil)
        #expect(NetworkAddress.parse("192.168.1.23:65536") == nil)
        #expect(NetworkAddress.parse("192.168.1.23:-1") == nil)
        #expect(NetworkAddress.parse("192.168.1.23:12a") == nil)
        #expect(NetworkAddress.parse("192.168.1.23:") == nil)
        #expect(NetworkAddress.parse("192.168.1.23:0000001") == nil)   // 太长
        #expect(NetworkAddress.parse("[::1]:0") == nil)
    }

    @Test
    func rejectsMissingPortOrHost() {
        #expect(NetworkAddress.parse("192.168.1.23") == nil)
        #expect(NetworkAddress.parse("studio") == nil)
        #expect(NetworkAddress.parse(":52811") == nil)
        #expect(NetworkAddress.parse("[]:52811") == nil)
        #expect(NetworkAddress.parse("[::1]") == nil)
        #expect(NetworkAddress.parse("[::1]52811") == nil)
        #expect(NetworkAddress.parse("") == nil)
        #expect(NetworkAddress.parse("   ") == nil)
    }

    @Test
    func rejectsUnbracketedIPv6AndJunk() {
        #expect(NetworkAddress.parse("fd7a::1:52811") == nil)
        #expect(NetworkAddress.parse("[not-v6]:80") == nil)
        #expect(NetworkAddress.parse("999.1.1.1:80") == nil)
        #expect(NetworkAddress.parse("a..b:80") == nil)
        #expect(NetworkAddress.parse("-a:80") == nil)
        #expect(NetworkAddress.parse("http://mac:80") == nil)
        #expect(NetworkAddress.parse("my mac:80") == nil)
        #expect(NetworkAddress.parse("电脑:80") == nil)
    }

    @Test
    func storesAndClearsInUserDefaults() throws {
        let suite = "lc.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NetworkAddress.load(defaults) == nil)
        let a = try #require(NetworkAddress.parse("[fd00::5]:50000"))
        NetworkAddress.save(a, defaults)
        #expect(defaults.string(forKey: "lc.netAddress") == "[fd00::5]:50000")
        #expect(NetworkAddress.load(defaults) == a)
        NetworkAddress.clear(defaults)
        #expect(NetworkAddress.load(defaults) == nil)
        #expect(defaults.object(forKey: "lc.netAddress") == nil)
    }
}

struct NetworkLinkPlanTests {
    @Test
    func bluetoothAlwaysWinsThePath() {
        #expect(NetworkLinkPlan.path(bleReady: true, networkReady: true) == .bluetooth)
        #expect(NetworkLinkPlan.path(bleReady: true, networkReady: false) == .bluetooth)
        #expect(NetworkLinkPlan.path(bleReady: false, networkReady: true) == .network)
        #expect(NetworkLinkPlan.path(bleReady: false, networkReady: false) == nil)
    }

    @Test
    func neverTriesNetworkWithoutAnAddress() {
        for waited in [0.0, 5, 600] {
            #expect(NetworkLinkPlan.decide(paired: true, hasAddress: false, foreground: true, bleReady: false,
                                           waited: waited, running: false) == .stop)
        }
    }

    @Test
    func waitsForBluetoothFiveSecondsThenRuns() {
        func d(_ waited: TimeInterval, running: Bool = false) -> NetworkLinkPlan.Decision {
            NetworkLinkPlan.decide(paired: true, hasAddress: true, foreground: true, bleReady: false,
                                   waited: waited, running: running)
        }
        #expect(d(0) == .wait(5))
        #expect(d(2) == .wait(3))
        #expect(d(5) == .run)
        #expect(d(30) == .run)
        // 已经在跑的不再重新等
        #expect(d(0, running: true) == .run)
    }

    @Test
    func bluetoothTakingOverStopsTheNetwork() {
        #expect(NetworkLinkPlan.decide(paired: true, hasAddress: true, foreground: true, bleReady: true,
                                       waited: 99, running: true) == .stop)
    }

    @Test
    func backgroundOrUnpairedNeverRuns() {
        #expect(NetworkLinkPlan.decide(paired: true, hasAddress: true, foreground: false, bleReady: false,
                                       waited: 99, running: true) == .stop)
        #expect(NetworkLinkPlan.decide(paired: false, hasAddress: true, foreground: true, bleReady: false,
                                       waited: 99, running: false) == .stop)
    }

    @Test
    func onlyBluetoothCanLift() {
        #expect(NetworkLinkPlan.canLift(path: .bluetooth))
        #expect(!NetworkLinkPlan.canLift(path: .network))
        #expect(!NetworkLinkPlan.canLift(path: nil))
    }

    @Test
    func failedStaysFailedUntilConnected() {
        typealias S = NetworkStatus
        #expect(NetworkLinkPlan.status(client: .connecting, previous: .none) == S.trying)
        #expect(NetworkLinkPlan.status(client: .waiting(retryIn: 1), previous: .trying) == S.failed)
        #expect(NetworkLinkPlan.status(client: .connecting, previous: .failed) == S.failed)
        #expect(NetworkLinkPlan.status(client: .connected, previous: .failed) == S.failed)
        #expect(NetworkLinkPlan.status(client: .ready, previous: .failed) == S.none)
        #expect(NetworkLinkPlan.status(client: .stopped, previous: .failed) == S.none)
    }
}

/// 保存前的整理 / 诊断 / 保存判断
struct NetworkAddressSaveTests {
    private let v4 = NetworkAddress(host: "1.2.3.4", port: 5)

    @Test
    func normalizesFullWidth() {
        #expect(NetworkAddress.normalize("１９２.１６８.１.２３：５２８１１") == "192.168.1.23:52811")
        #expect(NetworkAddress.normalize("［::1］：８０") == "[::1]:80")
        #expect(NetworkAddress.parseNormalized("１９２.１６８.１.２３：５２８１１") == NetworkAddress(host: "192.168.1.23", port: 52811))
    }

    @Test
    func stripsWhitespaceAndScheme() {
        #expect(NetworkAddress.parseNormalized(" \n1.2.3.4 : 5\n ") == v4)
        #expect(NetworkAddress.parseNormalized("tcp://1.2.3.4:5/") == v4)
        #expect(NetworkAddress.parseNormalized("HTTP://1.2.3.4:5") == v4)
        #expect(NetworkAddress.parseNormalized("ftp://1.2.3.4:5") == nil)
        #expect(NetworkAddress.parse("tcp://1.2.3.4:5/") == nil)   // parse 本身仍严格
    }

    @Test
    func diagnoses() {
        #expect(NetworkAddress.diagnose("1.2.3.4:5") == nil)
        #expect(NetworkAddress.diagnose("1.2.3.4") == .missingPort)
        #expect(NetworkAddress.diagnose("1.2.3.4：") == .missingPort)
        #expect(NetworkAddress.diagnose("my-mac.local") == .missingPort)
        #expect(NetworkAddress.diagnose("[fd00::1]") == .missingPort)
        #expect(NetworkAddress.diagnose("tcp://1.2.3.4/") == .missingPort)
        #expect(NetworkAddress.diagnose("1.2.3.4:0") == .malformed)
        #expect(NetworkAddress.diagnose("999.1.1.1:80") == .malformed)
        #expect(NetworkAddress.diagnose("fd00::1") == .malformed)
        #expect(NetworkAddress.diagnose("[nope]") == .malformed)
        #expect(NetworkAddress.diagnose("电脑") == .malformed)
        #expect(NetworkAddress.diagnose("") == .malformed)
    }

    @Test
    func saveCheck() {
        #expect(SaveCheck.evaluate(text: "1.2.3.4:5", paired: false) == .reject(.notPaired))
        #expect(SaveCheck.evaluate(text: "", paired: false) == .reject(.notPaired))
        #expect(SaveCheck.evaluate(text: "1.2.3.4", paired: true) == .reject(.missingPort))
        #expect(SaveCheck.evaluate(text: "???", paired: true) == .reject(.malformed))
        #expect(SaveCheck.evaluate(text: "", paired: true) == .reject(.malformed))
        #expect(SaveCheck.evaluate(text: "1.2.3.4:5", paired: true) == .save(v4))
        #expect(SaveCheck.evaluate(text: "１.２.３.４：５\n", paired: true) == .save(v4))
        #expect(SaveCheck.evaluate(text: "mac.local:52811", paired: true) == .save(NetworkAddress(host: "mac.local", port: 52811)))
        #expect(SaveCheck.evaluate(text: "[fd00::1]:80", paired: true) == .save(NetworkAddress(host: "fd00::1", port: 80)))
    }

    @Test
    func copyCoversEveryReason() {
        #expect(NetworkAddressCopy.text(for: .notPaired) == NetworkAddressCopy.notPaired)
        #expect(NetworkAddressCopy.text(for: .missingPort) == NetworkAddressCopy.missingPort)
        #expect(NetworkAddressCopy.text(for: .malformed) == NetworkAddressCopy.malformed)
    }
}
