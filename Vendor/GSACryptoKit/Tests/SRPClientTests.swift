//
//  SRPClientTests.swift
//  GSACryptoKitTests
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 GSACryptoKit. All rights reserved.
//

import Testing
import Foundation
import Crypto
import OpenSSL
@testable import GSACryptoKit

@Suite
struct SRPClientTests {

    // RFC 5054 2048-bit MODP Group Prime (N)
    private static let N_Hex = """
    AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050\
    A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50\
    E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8\
    55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B\
    CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748\
    544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6\
    AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6\
    94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73
    """

    private static let N_Bytes: Data = Data(hexString: N_Hex)!
    private static let g_Val: UInt32 = 2
    private static let groupSize = 256

    private static func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    @Test
    func srpClientInitialization() throws {
        let client = SRPClient()
        #expect(client != nil)
        #expect(client?.exchangeSize() == 256)
        #expect(client?.sessionKey() == nil)
    }

    @Test
    func srpAuthenticationStart() throws {
        let client = try #require(SRPClient())
        let clientPublicA = client.startAuthentication()
        let aData = try #require(clientPublicA)
        #expect(aData.count == 256)
    }

    @Test
    func fullSRP6aEndToEndExchange() throws {
        let username = "appleid@example.com"
        let password = "MySecurePassword123!"
        let salt = Data((0..<32).map { UInt8($0 + 5) })

        // Derive passwordBytes using PBKDF2
        let pwdDigest = Self.sha256(Data(password.utf8))
        let derivedKey = CryptoUtilities.pbkdf2SHA256(password: pwdDigest, salt: salt, rounds: 1000, outputLength: 32)
        let passwordBytes = try #require(derivedKey)

        // Derive x = SHA256(salt || SHA256(":" || passwordBytes))
        let h1 = Self.sha256(Data(":".utf8) + passwordBytes)
        let xData = Self.sha256(salt + h1)

        // Simulated Server: Compute verifier v = g^x mod N
        let verifierV = try computeServerVerifier(x: xData)

        // 1. Client starts authentication and generates public A
        let client = try #require(SRPClient())
        let clientA = try #require(client.startAuthentication())

        // 2. Server generates private ephemeral b, public ephemeral B = (k*v + g^b) mod N
        let (serverB, serverPrivateKeyB) = try generateServerEphemeral(verifier: verifierV)

        // 3. Client processes challenge with server B -> produces M1 proof
        let clientM1 = client.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: serverB
        )
        let m1Data = try #require(clientM1)
        #expect(m1Data.count == 32)

        // 4. Server computes shared secret S, session key K, and verifies M1
        let (serverM1, serverM2, serverK) = try computeServerVerification(
            username: username,
            salt: salt,
            clientA: clientA,
            serverB: serverB,
            serverPrivateB: serverPrivateKeyB,
            verifierV: verifierV
        )

        // Server confirms Client M1 matches
        #expect(m1Data == serverM1)

        // 5. Client verifies Server Proof M2
        let isServerVerified = client.verifyServerProof(serverM2)
        #expect(isServerVerified)

        // 6. Both client and server derived the identical session key K
        let clientK = try #require(client.sessionKey())
        #expect(clientK == serverK)
        #expect(clientK.count == 32)
    }

    @Test
    func s2kFoEndToEndExchange() throws {
        let username = "s2kfo_user@example.com"
        let password = "MySecurePassword123!"
        let salt = Data((0..<32).map { UInt8($0 + 5) })
        let iterations = 716

        // Derive passwordBytes using s2k_fo: PBKDF2(hexEncodedString(SHA256(password)))
        let pwdDigest = Self.sha256(Data(password.utf8))
        let hexString = pwdDigest.map { String(format: "%02hhx", $0) }.joined()
        let s2kFoInput = Data(hexString.utf8)
        #expect(s2kFoInput.count == 64)

        let derivedKey = CryptoUtilities.pbkdf2SHA256(password: s2kFoInput, salt: salt, rounds: iterations, outputLength: 32)
        let passwordBytes = try #require(derivedKey)

        // Derive x = SHA256(salt || SHA256(":" || passwordBytes))
        let h1 = Self.sha256(Data(":".utf8) + passwordBytes)
        let xData = Self.sha256(salt + h1)

        // Simulated Server: Compute verifier v = g^x mod N
        let verifierV = try computeServerVerifier(x: xData)

        // 1. Client starts authentication and generates public A
        let client = try #require(SRPClient())
        let clientA = try #require(client.startAuthentication())

        // 2. Server generates private ephemeral b, public ephemeral B = (k*v + g^b) mod N
        let (serverB, serverPrivateKeyB) = try generateServerEphemeral(verifier: verifierV)

        // 3. Client processes challenge with server B -> produces M1 proof
        let clientM1 = client.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: serverB
        )
        let m1Data = try #require(clientM1)
        #expect(m1Data.count == 32)

        // 4. Server computes shared secret S, session key K, and verifies M1
        let (serverM1, serverM2, serverK) = try computeServerVerification(
            username: username,
            salt: salt,
            clientA: clientA,
            serverB: serverB,
            serverPrivateB: serverPrivateKeyB,
            verifierV: verifierV
        )

        // Server confirms Client M1 matches
        #expect(m1Data == serverM1)

        // 5. Client verifies Server Proof M2
        let isServerVerified = client.verifyServerProof(serverM2)
        #expect(isServerVerified)

        // 6. Both client and server derived the identical session key K
        let clientK = try #require(client.sessionKey())
        #expect(clientK == serverK)
        #expect(clientK.count == 32)
    }

    @Test
    func srpWrongPasswordFailure() throws {
        let username = "user@test.com"
        let realPasswordBytes = Data(repeating: 0x11, count: 32)
        let wrongPasswordBytes = Data(repeating: 0x22, count: 32)
        let salt = Data(repeating: 0x42, count: 32)

        let realH1 = Self.sha256(Data(":".utf8) + realPasswordBytes)
        let realX = Self.sha256(salt + realH1)

        // Server has verifier for the real password
        let verifierV = try computeServerVerifier(x: realX)

        let client = try #require(SRPClient())
        let clientA = try #require(client.startAuthentication())
        let (serverB, serverPrivateB) = try generateServerEphemeral(verifier: verifierV)

        // Client attempts auth with wrong password
        let clientM1 = client.processChallenge(
            username: username,
            password: wrongPasswordBytes,
            salt: salt,
            serverPublicKey: serverB
        )
        let m1Data = try #require(clientM1)

        let (serverM1, _, _) = try computeServerVerification(
            username: username,
            salt: salt,
            clientA: clientA,
            serverB: serverB,
            serverPrivateB: serverPrivateB,
            verifierV: verifierV
        )

        // Proof must not match
        #expect(m1Data != serverM1)
    }

    @Test
    func srpInvalidServerPublicKey() throws {
        let username = "user@test.com"
        let passwordBytes = Data(repeating: 0x33, count: 32)
        let salt = Data(repeating: 0x11, count: 32)

        let client = try #require(SRPClient())
        _ = client.startAuthentication()

        // Server public key B = 0 (invalid modulo N)
        let invalidBZero = Data(repeating: 0, count: 256)
        let resultZero = client.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: invalidBZero
        )
        #expect(resultZero == nil)
    }

    @Test
    func srpTamperedServerProofRejected() throws {
        let username = "user@test.com"
        let passwordBytes = Data(repeating: 0x44, count: 32)
        let salt = Data(repeating: 0x77, count: 32)

        let h1 = Self.sha256(Data(":".utf8) + passwordBytes)
        let xData = Self.sha256(salt + h1)

        let verifierV = try computeServerVerifier(x: xData)
        let client = try #require(SRPClient())
        let clientA = try #require(client.startAuthentication())
        let (serverB, serverPrivateB) = try generateServerEphemeral(verifier: verifierV)

        _ = client.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: serverB
        )

        let (_, serverM2, _) = try computeServerVerification(
            username: username,
            salt: salt,
            clientA: clientA,
            serverB: serverB,
            serverPrivateB: serverPrivateB,
            verifierV: verifierV
        )

        // Tamper 1 byte of server M2 proof
        var tamperedM2 = Data(serverM2)
        if let firstIdx = tamperedM2.indices.first {
            tamperedM2[firstIdx] ^= 0xFF
        }

        #expect(!client.verifyServerProof(tamperedM2))
    }

    @Test
    func srpCrossValidationWithOpenSSLServer() throws {
        let username = "crossval@example.com"
        let passwordBytes = Data((0..<32).map { UInt8(($0 * 7) & 0xFF) })
        let salt = Data((0..<32).map { UInt8($0 + 11) })

        let h1 = Self.sha256(Data(":".utf8) + passwordBytes)
        let xData = Self.sha256(salt + h1)

        // 1. Compute server verifier v = g^x mod N using OpenSSL
        let verifierV = try computeOpenSSLServerVerifier(x: xData)

        // 2. Pure Swift Client generates A
        let client = try #require(SRPClient())
        let clientA = try #require(client.startAuthentication())

        // 3. OpenSSL generates server ephemeral B = (k*v + g^b) mod N and private b
        let (serverB, serverPrivateKeyB) = try generateOpenSSLServerEphemeral(verifier: verifierV)

        // 4. Pure Swift Client processes challenge with OpenSSL server B -> produces M1 proof
        let clientM1 = client.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: serverB
        )
        let m1Data = try #require(clientM1)

        // 5. OpenSSL Server computes shared secret S, session key K, and verifies M1
        let (serverM1, serverM2, serverK) = try computeOpenSSLServerVerification(
            username: username,
            salt: salt,
            clientA: clientA,
            serverB: serverB,
            serverPrivateB: serverPrivateKeyB,
            verifierV: verifierV
        )

        // Pure Swift Client M1 matches OpenSSL Server M1
        #expect(m1Data == serverM1)

        // Pure Swift Client verifies OpenSSL Server proof M2
        let isVerified = client.verifyServerProof(serverM2)
        #expect(isVerified)

        // Both derive the exact identical session key K
        let clientK = try #require(client.sessionKey())
        #expect(clientK == serverK)
        #expect(clientK.count == 32)
    }

    @Test
    func crossValidateAgainstDarwinCoreCryptoBaseline() throws {
        guard let darwinBaseline = DarwinCCSRPBaseline() else {
            // Skip when libcorecrypto is not available on non-Darwin platforms
            return
        }

        let username = "crossval@apple.com"
        let passwordBytes = Data((0..<32).map { UInt8(($0 * 7) & 0xFF) })
        let salt = Data((0..<16).map { UInt8(($0 * 13) & 0xFF) })

        // Derive x = SHA256(salt || SHA256(":" || passwordBytes))
        let h1 = Self.sha256(Data(":".utf8) + passwordBytes)
        let xData = Self.sha256(salt + h1)

        // Compute verifier v = g^x mod N
        let verifierV = try computeServerVerifier(x: xData)

        // Generate server ephemeral B
        let (serverB, serverPrivateB) = try generateServerEphemeral(verifier: verifierV)

        // 1. Pure Swift SRPClient:
        let pureClient = try #require(SRPClient())
        let pureA = try #require(pureClient.startAuthentication())
        let pureM1 = try #require(pureClient.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: serverB
        ))
        let pureK = try #require(pureClient.sessionKey())

        // 2. Darwin ccsrp baseline:
        let darwinA = try #require(darwinBaseline.startAuthentication())
        let darwinM1 = try #require(darwinBaseline.processChallenge(
            username: username,
            password: passwordBytes,
            salt: salt,
            serverPublicKey: serverB
        ))
        let darwinK = try #require(darwinBaseline.sessionKey())

        // 3. Server verification for pure Swift client:
        let (serverExpectedPureM1, serverPureM2, serverPureK) = try computeServerVerification(
            username: username,
            salt: salt,
            clientA: pureA,
            serverB: serverB,
            serverPrivateB: serverPrivateB,
            verifierV: verifierV
        )
        #expect(pureM1 == serverExpectedPureM1)
        #expect(pureK == serverPureK)
        #expect(pureClient.verifyServerProof(serverPureM2))

        // 4. Server verification for Darwin ccsrp baseline:
        let (serverExpectedDarwinM1, serverDarwinM2, serverDarwinK) = try computeServerVerification(
            username: username,
            salt: salt,
            clientA: darwinA,
            serverB: serverB,
            serverPrivateB: serverPrivateB,
            verifierV: verifierV
        )
        #expect(darwinM1 == serverExpectedDarwinM1)
        #expect(darwinK == serverDarwinK)
        #expect(darwinBaseline.verifyServerProof(serverDarwinM2))
    }

    // Helper: Compute server verifier v = g^x mod N (Pure Swift)
    private func computeServerVerifier(x: Data) throws -> Data {
        let bnN = BigUInt(data: Self.N_Bytes)
        let bng = BigUInt(UInt64(Self.g_Val))
        let bnx = BigUInt(data: x)
        let bnv = bng.power(bnx, modulus: bnN)
        return bnv.serialize(paddedTo: Self.groupSize)
    }

    // Helper: Generate server ephemeral B = (k*v + g^b) mod N and private b (Pure Swift)
    private func generateServerEphemeral(verifier: Data) throws -> (Data, Data) {
        let bnN = BigUInt(data: Self.N_Bytes)
        let bng = BigUInt(UInt64(Self.g_Val))
        let bnv = BigUInt(data: verifier)

        // k = SHA256(N || pad(g))
        var gPadded = Data(repeating: 0, count: Self.groupSize - 1)
        gPadded.append(UInt8(Self.g_Val))
        let kBytes = Self.sha256(Self.N_Bytes + gPadded)
        let bnk = BigUInt(data: kBytes)

        // Generate random b (256-bit)
        let bnb = BigUInt.random(bitWidth: 256)

        // gb = g^b mod N
        let bnGb = bng.power(bnb, modulus: bnN)
        let bnKv = (bnk * bnv) % bnN
        let bnB = (bnKv + bnGb) % bnN

        let bBytes = bnB.serialize(paddedTo: Self.groupSize)
        let privBBytes = bnb.serialize(paddedTo: 32)

        return (bBytes, privBBytes)
    }

    // Helper: Simulated server computation of S = (A * v^u)^b mod N, K = SHA256(S), M1, M2
    private func computeServerVerification(
        username: String,
        salt: Data,
        clientA: Data,
        serverB: Data,
        serverPrivateB: Data,
        verifierV: Data
    ) throws -> (Data, Data, Data) {
        let bnN = BigUInt(data: Self.N_Bytes)
        let bnA = BigUInt(data: clientA)
        let bnv = BigUInt(data: verifierV)
        let bnb = BigUInt(data: serverPrivateB)

        // u = SHA256(A || B)
        let uData = Self.sha256(clientA + serverB)
        let bnu = BigUInt(data: uData)

        // S = (A * v^u)^b mod N
        let bnVu = bnv.power(bnu, modulus: bnN)
        let bnBase = (bnA * bnVu) % bnN
        let bnS = bnBase.power(bnb, modulus: bnN)

        let sBytes = bnS.serialize(paddedTo: Self.groupSize)

        // K = SHA256(S)
        let serverK = Self.sha256(sBytes)

        // M1 = SHA256(H(N) ^ H(g) || H(U) || salt || A || B || K)
        let hn = Self.sha256(Self.N_Bytes)
        var gPadded = Data(repeating: 0, count: Self.groupSize - 1)
        gPadded.append(UInt8(Self.g_Val))
        let hg = Self.sha256(gPadded)

        var hXor = Data(count: 32)
        for i in 0..<32 {
            hXor[i] = hn[i] ^ hg[i]
        }

        let hu = Self.sha256(Data(username.utf8))
        let m1Payload = hXor + hu + salt + clientA + serverB + serverK
        let serverM1 = Self.sha256(m1Payload)

        // M2 = SHA256(A || M1 || K)
        let m2Payload = clientA + serverM1 + serverK
        let serverM2 = Self.sha256(m2Payload)

        return (serverM1, serverM2, serverK)
    }

    // Helper: Compute server verifier v = g^x mod N using OpenSSL BIGNUM
    private func computeOpenSSLServerVerifier(x: Data) throws -> Data {
        guard let bnN = BN_new(), let bng = BN_new(), let bnx = BN_new(), let bnv = BN_new(), let ctx = BN_CTX_new() else {
            throw NSError(domain: "SRPClientTests", code: 1, userInfo: nil)
        }
        defer {
            BN_free(bnN); BN_free(bng); BN_free(bnx); BN_free(bnv); BN_CTX_free(ctx)
        }

        _ = Self.N_Bytes.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(Self.N_Bytes.count), bnN) }
        BN_set_word(bng, UInt(Self.g_Val))
        _ = x.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(x.count), bnx) }

        guard BN_mod_exp(bnv, bng, bnx, bnN, ctx) == 1 else {
            throw NSError(domain: "SRPClientTests", code: 2, userInfo: nil)
        }

        var vBytes = Data(count: Self.groupSize)
        _ = vBytes.withUnsafeMutableBytes { BN_bn2binpad(bnv, $0.bindMemory(to: UInt8.self).baseAddress, Int32(Self.groupSize)) }
        return vBytes
    }

    // Helper: Generate server ephemeral B = (k*v + g^b) mod N and private b using OpenSSL
    private func generateOpenSSLServerEphemeral(verifier: Data) throws -> (Data, Data) {
        guard let bnN = BN_new(), let bng = BN_new(), let bnk = BN_new(),
              let bnv = BN_new(), let bnb = BN_new(), let bnB = BN_new(),
              let ctx = BN_CTX_new() else {
            throw NSError(domain: "SRPClientTests", code: 3, userInfo: nil)
        }
        defer {
            BN_free(bnN); BN_free(bng); BN_free(bnk); BN_free(bnv); BN_free(bnb); BN_free(bnB); BN_CTX_free(ctx)
        }

        _ = Self.N_Bytes.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(Self.N_Bytes.count), bnN) }
        BN_set_word(bng, UInt(Self.g_Val))
        _ = verifier.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(verifier.count), bnv) }

        var gPadded = Data(repeating: 0, count: Self.groupSize - 1)
        gPadded.append(UInt8(Self.g_Val))
        let kBytes = Self.sha256(Self.N_Bytes + gPadded)
        _ = kBytes.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(kBytes.count), bnk) }

        BN_rand(bnb, 256, 0, 0)

        guard let bnGb = BN_new(), let bnKv = BN_new() else {
            throw NSError(domain: "SRPClientTests", code: 4, userInfo: nil)
        }
        defer { BN_free(bnGb); BN_free(bnKv) }

        BN_mod_exp(bnGb, bng, bnb, bnN, ctx)
        BN_mod_mul(bnKv, bnk, bnv, bnN, ctx)
        BN_mod_add(bnB, bnKv, bnGb, bnN, ctx)

        var bBytes = Data(count: Self.groupSize)
        _ = bBytes.withUnsafeMutableBytes { BN_bn2binpad(bnB, $0.bindMemory(to: UInt8.self).baseAddress, Int32(Self.groupSize)) }

        var privBBytes = Data(count: 32)
        _ = privBBytes.withUnsafeMutableBytes { BN_bn2binpad(bnb, $0.bindMemory(to: UInt8.self).baseAddress, 32) }

        return (bBytes, privBBytes)
    }

    // Helper: Simulated server computation using OpenSSL
    private func computeOpenSSLServerVerification(
        username: String,
        salt: Data,
        clientA: Data,
        serverB: Data,
        serverPrivateB: Data,
        verifierV: Data
    ) throws -> (Data, Data, Data) {
        guard let bnN = BN_new(), let bng = BN_new(), let bnA = BN_new(),
              let bnv = BN_new(), let bnb = BN_new(), let bnu = BN_new(),
              let bnS = BN_new(), let ctx = BN_CTX_new() else {
            throw NSError(domain: "SRPClientTests", code: 5, userInfo: nil)
        }
        defer {
            BN_free(bnN); BN_free(bng); BN_free(bnA); BN_free(bnv); BN_free(bnb); BN_free(bnu); BN_free(bnS); BN_CTX_free(ctx)
        }

        _ = Self.N_Bytes.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(Self.N_Bytes.count), bnN) }
        BN_set_word(bng, UInt(Self.g_Val))
        _ = clientA.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(clientA.count), bnA) }
        _ = verifierV.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(verifierV.count), bnv) }
        _ = serverPrivateB.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(serverPrivateB.count), bnb) }

        let uData = Self.sha256(clientA + serverB)
        _ = uData.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32(uData.count), bnu) }

        guard let bnVu = BN_new(), let bnBase = BN_new() else {
            throw NSError(domain: "SRPClientTests", code: 6, userInfo: nil)
        }
        defer { BN_free(bnVu); BN_free(bnBase) }

        BN_mod_exp(bnVu, bnv, bnu, bnN, ctx)
        BN_mod_mul(bnBase, bnA, bnVu, bnN, ctx)
        BN_mod_exp(bnS, bnBase, bnb, bnN, ctx)

        var sBytes = Data(count: Self.groupSize)
        _ = sBytes.withUnsafeMutableBytes { BN_bn2binpad(bnS, $0.bindMemory(to: UInt8.self).baseAddress, Int32(Self.groupSize)) }

        let serverK = Self.sha256(sBytes)

        let hn = Self.sha256(Self.N_Bytes)
        var gPadded = Data(repeating: 0, count: Self.groupSize - 1)
        gPadded.append(UInt8(Self.g_Val))
        let hg = Self.sha256(gPadded)

        var hXor = Data(count: 32)
        for i in 0..<32 {
            hXor[i] = hn[i] ^ hg[i]
        }

        let hu = Self.sha256(Data(username.utf8))
        let m1Payload = hXor + hu + salt + clientA + serverB + serverK
        let serverM1 = Self.sha256(m1Payload)

        let m2Payload = clientA + serverM1 + serverK
        let serverM2 = Self.sha256(m2Payload)

        return (serverM1, serverM2, serverK)
    }
}

// Dynamic Darwin ccsrp wrapper for cross-validation baseline in unit tests
private final class DarwinCCSRPBaseline {
    private static let symGp      = "ccsrp_gp_rfc5054_2048"
    private static let symDi      = "ccsha256_di"
    private static let symInit    = "ccsrp_ctx_init"
    private static let symSetFlag = "ccsrp_client_set_noUsernameInX"
    private static let symStart   = "ccsrp_client_start_authentication"
    private static let symProc    = "ccsrp_client_process_challenge"
    private static let symVerify  = "ccsrp_client_verify_session"
    private static let symKey     = "ccsrp_get_session_key"
    private static let symRng     = "ccrng"

    private typealias RawBufferHandle        = UnsafeRawPointer
    private typealias MutableRawBufferHandle = UnsafeMutableRawPointer
    private typealias CString                = UnsafePointer<CChar>
    private typealias StatusRef              = UnsafeMutablePointer<Int32>
    private typealias LengthRef              = UnsafeMutablePointer<Int>

    private typealias ccsrp_gp_fn       = @convention(c) () -> RawBufferHandle
    private typealias ccdigest_fn       = @convention(c) () -> RawBufferHandle
    private typealias ccsrp_init_fn     = @convention(c) (MutableRawBufferHandle, RawBufferHandle, RawBufferHandle) -> Void
    private typealias ccsrp_set_flag_fn = @convention(c) (MutableRawBufferHandle, Bool) -> Bool
    private typealias ccrng_fn          = @convention(c) (StatusRef?) -> MutableRawBufferHandle?
    private typealias ccsrp_start_fn    = @convention(c) (MutableRawBufferHandle, MutableRawBufferHandle?, MutableRawBufferHandle) -> Int32
    private typealias ccsrp_proc_fn     = @convention(c) (MutableRawBufferHandle, CString, Int, RawBufferHandle, Int, RawBufferHandle, RawBufferHandle, MutableRawBufferHandle) -> Int32
    private typealias ccsrp_verify_fn   = @convention(c) (MutableRawBufferHandle, RawBufferHandle) -> Int32
    private typealias ccsrp_key_fn      = @convention(c) (MutableRawBufferHandle, LengthRef) -> RawBufferHandle?

    private let ctx: MutableRawBufferHandle
    private let start_fn: ccsrp_start_fn
    private let proc_fn: ccsrp_proc_fn
    private let verify_fn: ccsrp_verify_fn
    private let key_fn: ccsrp_key_fn
    private let rng_fn: ccrng_fn

    init?() {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        guard let gp_sym       = dlsym(handle, Self.symGp),
              let di_sym       = dlsym(handle, Self.symDi),
              let init_sym     = dlsym(handle, Self.symInit),
              let set_flag_sym = dlsym(handle, Self.symSetFlag),
              let start_sym    = dlsym(handle, Self.symStart),
              let proc_sym     = dlsym(handle, Self.symProc),
              let verify_sym   = dlsym(handle, Self.symVerify),
              let key_sym      = dlsym(handle, Self.symKey),
              let rng_sym      = dlsym(handle, Self.symRng) else { return nil }

        let gp_fn       = unsafeBitCast(gp_sym,       to: ccsrp_gp_fn.self)
        let di_fn       = unsafeBitCast(di_sym,       to: ccdigest_fn.self)
        let init_fn     = unsafeBitCast(init_sym,     to: ccsrp_init_fn.self)
        let set_flag_fn = unsafeBitCast(set_flag_sym, to: ccsrp_set_flag_fn.self)

        self.start_fn   = unsafeBitCast(start_sym,    to: ccsrp_start_fn.self)
        self.proc_fn    = unsafeBitCast(proc_sym,     to: ccsrp_proc_fn.self)
        self.verify_fn  = unsafeBitCast(verify_sym,   to: ccsrp_verify_fn.self)
        self.key_fn     = unsafeBitCast(key_sym,      to: ccsrp_key_fn.self)
        self.rng_fn     = unsafeBitCast(rng_sym,      to: ccrng_fn.self)

        self.ctx = MutableRawBufferHandle.allocate(byteCount: 8192, alignment: 16)
        init_fn(ctx, di_fn(), gp_fn())
        _ = set_flag_fn(ctx, true)
    }

    deinit {
        ctx.deallocate()
    }

    func startAuthentication() -> Data? {
        var err: Int32 = 0
        let rng = rng_fn(&err)
        var A = Data(count: 256)
        let res = A.withUnsafeMutableBytes { start_fn(ctx, rng, $0.baseAddress!) }
        guard res == 0 else { return nil }
        return A
    }

    func processChallenge(
        username: String,
        password passwordBytes: Data,
        salt: Data,
        serverPublicKey bData: Data
    ) -> Data? {
        var M1 = Data(count: 32)
        let res = M1.withUnsafeMutableBytes { m1Bytes in
            salt.withUnsafeBytes { saltBytes in
                bData.withUnsafeBytes { bBytes in
                    passwordBytes.withUnsafeBytes { pwdBytes in
                        proc_fn(ctx, username, passwordBytes.count, pwdBytes.baseAddress!, salt.count, saltBytes.baseAddress!, bBytes.baseAddress!, m1Bytes.baseAddress!)
                    }
                }
            }
        }
        guard res == 0 else { return nil }
        return M1
    }

    func verifyServerProof(_ proof: Data) -> Bool {
        return proof.withUnsafeBytes { verify_fn(ctx, $0.baseAddress!) != 0 }
    }

    func sessionKey() -> Data? {
        var len = 0
        guard let ptr = key_fn(ctx, &len) else { return nil }
        return Data(bytes: ptr, count: len)
    }
}

fileprivate extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteStr = String(cleaned[index..<nextIndex])
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
