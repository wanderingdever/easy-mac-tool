import Foundation
import Testing
@testable import EasyMacTool

@Suite("Link preview network policy")
struct LinkPreviewNetworkPolicyTests {
    @Test func rejectsLocalAndPrivateTargets() {
        let blocked = [
            "http://localhost/",
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://172.16.0.1/",
            "http://192.168.1.1/",
            "http://169.254.1.1/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fc00::1]/",
            "http://192.0.2.1/",
        ]
        for value in blocked {
            #expect(LinkPreviewNetworkPolicy.allows(URL(string: value)!) == false)
        }
    }

    @Test func rejectsCredentialsAndNonStandardPorts() {
        #expect(LinkPreviewNetworkPolicy.allows(URL(string: "https://user:token@8.8.8.8/")!) == false)
        #expect(LinkPreviewNetworkPolicy.allows(URL(string: "https://8.8.8.8:8443/")!) == false)
        #expect(LinkPreviewNetworkPolicy.allows(URL(string: "file:///tmp/example")!) == false)
    }

    @Test func allowsPublicLiteralOnDefaultPorts() {
        #expect(LinkPreviewNetworkPolicy.allows(URL(string: "https://8.8.8.8/")!))
        #expect(LinkPreviewNetworkPolicy.allows(URL(string: "http://1.1.1.1:80/")!))
    }
}

