import CryptoKit
import Foundation
import Testing
@testable import ElioCore

@Suite struct WebPushTests {
    /// RFC 8291, Appendix A.
    @Test func rfc8291Vector() throws {
        let asPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: unb64url("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")!)
        let body = try WebPush.encrypt(Data("When I grow up, I want to be a watermelon".utf8),
                                       uaPublic: unb64url("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")!,
                                       authSecret: unb64url("BTBZMqHH6r4Tts7J_aSIgg")!,
                                       ephemeral: asPrivate, fixedSalt: unb64url("DGv6ra1nlYgDCS1FRnbzlw")!)
        #expect(b64url(body) == "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
    }
}
