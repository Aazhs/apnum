import Foundation
import Testing
@testable import ApnumLinkCore

@Suite struct LinkCoreTests {
    private func connected() throws -> (Session, Session, Data, Data) {
        let a = try generateKeypair(), b = try generateKeypair()
        let phone = try Handshake.initiator(localPrivateKey: a.privateKey)
        let mac = try Handshake.responder(localPrivateKey: b.privateKey)
        try mac.readMessage(message: try phone.writeMessage())
        try phone.readMessage(message: try mac.writeMessage())
        try mac.readMessage(message: try phone.writeMessage())
        #expect(phone.isFinished() && mac.isFinished())
        #expect(phone.remotePublicKey() == b.publicKey)
        #expect(mac.remotePublicKey() == a.publicKey)
        let hashes = (try phone.handshakeHash(), try mac.handshakeHash())
        let sessions = (try phone.intoSession(), try mac.intoSession())
        #expect(throws: LinkError.self) { try phone.intoSession() }
        return (sessions.0, sessions.1, hashes.0, hashes.1)
    }

    @Test func handshakeAndSealOpen() throws {
        let (phone, mac, h1, h2) = try connected()
        #expect(h1 == h2)
        #expect(safetyNumber(handshakeHash: h1) == safetyNumber(handshakeHash: h2))
        #expect(safetyNumber(handshakeHash: h1).count == 6)
        for n in [0, 10, 65_000, 65_001, 1_000_000] {
            let data = Data((0..<n).map { UInt8($0 % 251) })
            #expect(try mac.open(sealed: try phone.seal(plaintext: data)) == data)
            #expect(try phone.open(sealed: try mac.seal(plaintext: data)) == data)
        }
    }

    @Test func tamperFails() throws {
        let (phone, mac, _, _) = try connected()
        var sealed = try phone.seal(plaintext: Data("hi".utf8))
        sealed[sealed.count - 1] ^= 1
        #expect(throws: LinkError.self) { try mac.open(sealed: sealed) }
    }

    @Test func pairURIRoundTrip() throws {
        let kp = try generateKeypair()
        let token = try pairingToken()
        #expect(pairingCode(token: token).count == 8)
        let uri = makePairUri(host: "192.168.1.5", port: 47800, publicKey: kp.publicKey, token: token, name: "Aarsh's Mac é 日本")
        let info = try parsePairUri(uri: uri)
        #expect(info.host == "192.168.1.5" && info.port == 47800)
        #expect(info.publicKey == kp.publicKey && info.token == token)
        #expect(info.name == "Aarsh's Mac é 日本")
        #expect(throws: LinkError.self) { try parsePairUri(uri: "nope") }
        #expect(fingerprint(publicKey: kp.publicKey).split(separator: " ").count == 4)
    }
}
