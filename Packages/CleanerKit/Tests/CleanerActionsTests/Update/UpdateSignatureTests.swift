import CleanerTestSupport
import CryptoKit
import Foundation
import Testing

@testable import CleanerActions

/// `SHA256SUMS.sig`: parsing, trust, and the downloader refusing anything not signed by a trusted key.
struct UpdateSignatureTests {
    private let zipBytes = Data("pretend this is a zip".utf8)
    private var sums: Data { Data(FixtureAssets.checksumLine(for: zipBytes).utf8) }

    // MARK: UpdateTrust

    @Test func trust_acceptsASignatureFromATrustedKey() throws {
        let signer = FixtureSigner()
        let file = try signer.signatureFile(for: sums)
        #expect(signer.trust.isValid(signatureFile: file, for: sums))
    }

    @Test func trust_acceptsASignatureLineWithoutTheTrailingNewline() throws {
        let signer = FixtureSigner()
        let text = try signer.key.signature(for: sums).base64EncodedString()
        #expect(signer.trust.isValid(signatureFile: Data(text.utf8), for: sums))
    }

    @Test func trust_refusesASignatureFromAnotherKey() throws {
        let trusted = FixtureSigner()
        let attacker = FixtureSigner()
        let file = try attacker.signatureFile(for: sums)
        #expect(!trusted.trust.isValid(signatureFile: file, for: sums))
    }

    @Test func trust_refusesAChecksumFileThatChangedByOneByte() throws {
        let signer = FixtureSigner()
        let file = try signer.signatureFile(for: sums)
        var changed = sums
        changed[0] ^= 0x01
        #expect(!signer.trust.isValid(signatureFile: file, for: changed))
    }

    @Test func trust_refusesEverythingWhenNoKeyIsTrusted() throws {
        let signer = FixtureSigner()
        let file = try signer.signatureFile(for: sums)
        #expect(!UpdateTrust(publicKeys: []).isValid(signatureFile: file, for: sums))
        #expect(!UpdateTrust(base64Keys: []).isValid(signatureFile: file, for: sums))
    }

    @Test func trust_acceptsAnyOfSeveralKeys() throws {
        let first = FixtureSigner()
        let second = FixtureSigner()
        let trust = UpdateTrust(publicKeys: [first.key.publicKey, second.key.publicKey])
        #expect(trust.isValid(signatureFile: try second.signatureFile(for: sums), for: sums))
        #expect(trust.isValid(signatureFile: try first.signatureFile(for: sums), for: sums))
    }

    @Test func trust_ignoresInvalidEntriesInTheKeyList() throws {
        let signer = FixtureSigner()
        let good = signer.key.publicKey.rawRepresentation.base64EncodedString()
        let short = Data(repeating: 7, count: 31).base64EncodedString()
        let trust = UpdateTrust(base64Keys: ["not base64 !!", "", short, good])
        #expect(trust.isValid(signatureFile: try signer.signatureFile(for: sums), for: sums))

        // With only unusable entries nothing is trusted.
        let none = UpdateTrust(base64Keys: ["not base64 !!", "", short])
        #expect(!none.isValid(signatureFile: try signer.signatureFile(for: sums), for: sums))
    }

    @Test func trust_readsKeysGivenAsBase64() throws {
        let signer = FixtureSigner()
        let trust = UpdateTrust(base64Keys: [signer.key.publicKey.rawRepresentation.base64EncodedString()])
        #expect(trust.isValid(signatureFile: try signer.signatureFile(for: sums), for: sums))
    }

    @Test func trust_refusesMalformedSignatureFiles() throws {
        let signer = FixtureSigner()
        let real = try signer.key.signature(for: sums)
        let line = real.base64EncodedString()
        let sixtyThree = Data(real.prefix(63)).base64EncodedString()
        let sixtyFive = (Data(real) + Data([0])).base64EncodedString()
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("only a newline", Data("\n".utf8)),
            ("not base64", Data("this is not base64!\n".utf8)),
            ("63 bytes", Data((sixtyThree + "\n").utf8)),
            ("65 bytes", Data((sixtyFive + "\n").utf8)),
            ("two lines", Data((line + "\n" + line + "\n").utf8)),
            ("a blank line after", Data((line + "\n\n").utf8)),
            ("leading blank line", Data(("\n" + line + "\n").utf8)),
            ("windows line ending", Data((line + "\r\n").utf8)),
            ("trailing space", Data((line + " \n").utf8)),
            ("longer than 1 KB", Data((line + String(repeating: " ", count: 1100)).utf8)),
            ("raw signature bytes", Data(real)),
            ("not UTF-8", Data([0xFF, 0xFE, 0x00])),
        ]
        for (name, file) in cases {
            #expect(!signer.trust.isValid(signatureFile: file, for: sums), "\(name) must be refused")
        }
    }

    // MARK: UpdateAssets

    @Test func assets_refuseASignatureAddressOffTheAllowList() throws {
        let evil = try #require(URL(string: "https://evil.example/SHA256SUMS.sig"))
        #expect(UpdateAssets(archive: FixtureAssets.archiveURL, checksums: FixtureAssets.checksumsURL, signature: evil) == nil)
    }

    @Test func assets_withoutASignatureHaveNone() throws {
        let assets = try #require(UpdateAssets(archive: FixtureAssets.archiveURL, checksums: FixtureAssets.checksumsURL))
        #expect(assets.signature == nil)
        let signed = try FixtureAssets.make()
        #expect(signed.signature == FixtureAssets.signatureURL)
    }

    // MARK: Picking the assets out of a release

    private func entries(_ names: [String], base: String = "https://github.com/iant4093/TruongCleaner/releases/download/build-21/")
        -> [(name: String, address: String)]
    {
        names.map { (name: $0, address: base + $0) }
    }

    @Test func select_findsTheSignatureWhenTheReleaseHasOne() throws {
        let assets = try #require(
            UpdateAssets.select(from: entries(["TruongCleaner.dmg", "TruongCleaner.zip", "SHA256SUMS", "SHA256SUMS.sig"])))
        #expect(assets.signature == FixtureAssets.signatureURL)
        #expect(assets.archive == FixtureAssets.archiveURL)
        #expect(assets.checksums == FixtureAssets.checksumsURL)
    }

    @Test func select_stillOffersAReleaseWithoutASignature() throws {
        let assets = try #require(UpdateAssets.select(from: entries(["TruongCleaner.zip", "SHA256SUMS", "install.sh"])))
        #expect(assets.signature == nil)
    }

    @Test func select_treatsTwoSignatureAssetsAsNoSignature() throws {
        let assets = try #require(
            UpdateAssets.select(from: entries(["TruongCleaner.zip", "SHA256SUMS", "SHA256SUMS.sig", "SHA256SUMS.sig"])))
        #expect(assets.signature == nil)
    }

    @Test func select_refusesAReleaseWhoseSignatureAddressIsOffTheAllowList() {
        var list = entries(["TruongCleaner.zip", "SHA256SUMS"])
        list.append((name: "SHA256SUMS.sig", address: "https://evil.example/SHA256SUMS.sig"))
        #expect(UpdateAssets.select(from: list) == nil)
    }

    @Test(arguments: [
        ["SHA256SUMS", "SHA256SUMS.sig"],
        ["TruongCleaner.zip", "SHA256SUMS.sig"],
        ["TruongCleaner.zip", "TruongCleaner.zip", "SHA256SUMS", "SHA256SUMS.sig"],
        ["TruongCleaner.zip", "SHA256SUMS", "SHA256SUMS"],
    ])
    func select_refusesAReleaseMissingOrDoublingARequiredFile(_ names: [String]) {
        #expect(UpdateAssets.select(from: entries(names)) == nil)
    }

    // MARK: UpdateDownloader

    private func downloader(
        _ tree: FixtureTree, sums: Data, signature: Data?, trust: UpdateTrust? = nil
    ) throws -> (UpdateDownloader, FakeFetcher) {
        try tree.addDirectory("tmp")
        let fetcher = FakeFetcher(archive: zipBytes, checksums: sums, signature: signature)
        let root = tree.url(for: "tmp")
        let downloader = trust.map { UpdateDownloader(fetcher: fetcher, workRoot: root, trust: $0) }
            ?? UpdateDownloader(fetcher: fetcher, workRoot: root)
        return (downloader, fetcher)
    }

    @Test func download_refusesAnUnsignedReleaseBeforeFetchingAnything() async throws {
        try await withUpdateTree { tree in
            let signer = FixtureSigner()
            let (downloader, fetcher) = try downloader(
                tree, sums: sums, signature: try signer.signatureFile(for: sums), trust: signer.trust)

            await #expect(throws: UpdateError.unsigned) {
                try await downloader.download(FixtureAssets.make(signed: false)) { _ in }
            }
            #expect(fetcher.requestedURLs.isEmpty)
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test func download_refusesABadSignatureBeforeFetchingTheArchive() async throws {
        try await withUpdateTree { tree in
            let trusted = FixtureSigner()
            let attacker = FixtureSigner()
            let (downloader, fetcher) = try downloader(
                tree, sums: sums, signature: try attacker.signatureFile(for: sums), trust: trusted.trust)

            await #expect(throws: UpdateError.badSignature) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(!fetcher.requestedURLs.contains(FixtureAssets.archiveURL))
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test func download_refusesChecksumsChangedAfterSigning() async throws {
        try await withUpdateTree { tree in
            let signer = FixtureSigner()
            let signature = try signer.signatureFile(for: sums)
            // The attacker swaps in a checksum line for their own ZIP but cannot re-sign.
            let forged = Data(FixtureAssets.checksumLine(for: Data("evil".utf8)).utf8)
            let (downloader, fetcher) = try downloader(tree, sums: forged, signature: signature, trust: signer.trust)

            await #expect(throws: UpdateError.badSignature) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(!fetcher.requestedURLs.contains(FixtureAssets.archiveURL))
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test(arguments: ["", "garbage\n", "AAAA\n"])
    func download_refusesAMalformedSignatureFile(_ text: String) async throws {
        try await withUpdateTree { tree in
            let signer = FixtureSigner()
            let (downloader, fetcher) = try downloader(
                tree, sums: sums, signature: Data(text.utf8), trust: signer.trust)

            await #expect(throws: UpdateError.badSignature) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(!fetcher.requestedURLs.contains(FixtureAssets.archiveURL))
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test func download_acceptsAGoodSignatureAndAGoodArchive() async throws {
        try await withUpdateTree { tree in
            let signer = FixtureSigner()
            let (downloader, fetcher) = try downloader(
                tree, sums: sums, signature: try signer.signatureFile(for: sums), trust: signer.trust)

            let result = try await downloader.download(FixtureAssets.make()) { _ in }

            #expect(try Data(contentsOf: result.archive) == zipBytes)
            // The order matters: the signature is read before the ZIP is fetched.
            #expect(fetcher.requestedURLs == [
                FixtureAssets.checksumsURL, FixtureAssets.signatureURL, FixtureAssets.archiveURL,
            ])
            let kept = try FileManager.default.contentsOfDirectory(atPath: result.folder.path(percentEncoded: false))
            #expect(Set(kept) == ["SHA256SUMS", "SHA256SUMS.sig", "TruongCleaner.zip"])
        }
    }

    @Test func download_refusesAWrongArchiveEvenWithAGoodSignature() async throws {
        try await withUpdateTree { tree in
            let signer = FixtureSigner()
            // Signed checksums that describe a different ZIP than the one served.
            let signedSums = Data(FixtureAssets.checksumLine(for: Data("another zip".utf8)).utf8)
            let (downloader, _) = try downloader(
                tree, sums: signedSums, signature: try signer.signatureFile(for: signedSums), trust: signer.trust)

            await #expect(throws: UpdateError.checksumMismatch) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    @Test func download_stopsWhenTheSignatureFileIsTooLong() async throws {
        try await withUpdateTree { tree in
            let signer = FixtureSigner()
            let long = try signer.signatureFile(for: sums) + Data(repeating: 0x20, count: 2000)
            let (downloader, fetcher) = try downloader(tree, sums: sums, signature: long, trust: signer.trust)

            await #expect(throws: UpdateError.self) {
                try await downloader.download(FixtureAssets.make()) { _ in }
            }
            #expect(!fetcher.requestedURLs.contains(FixtureAssets.archiveURL))
            #expect(updateFolders(in: tree.url(for: "tmp")).isEmpty)
        }
    }

    // MARK: Safety rule

    /// An update is never installed without a valid signature from a trusted key. If the signature
    /// check is removed from the downloader, the cases below return a download instead of throwing.
    @Test func rule_updateRequiresSignature() async throws {
        try await withUpdateTree { tree in
            let trusted = FixtureSigner()
            let attacker = FixtureSigner()
            let attackerSignature = try attacker.signatureFile(for: sums)
            try tree.addDirectory("tmp")
            let root = tree.url(for: "tmp")

            // 1. A release without a signature asset.
            let unsignedFetcher = FakeFetcher(archive: zipBytes, checksums: sums)
            let unsigned = UpdateDownloader(fetcher: unsignedFetcher, workRoot: root, trust: trusted.trust)
            await #expect(throws: UpdateError.unsigned) {
                try await unsigned.download(FixtureAssets.make(signed: false)) { _ in }
            }
            #expect(unsignedFetcher.requestedURLs.isEmpty)

            // 2. A signature made by a key the app does not trust, with a matching ZIP.
            let forgedFetcher = FakeFetcher(archive: zipBytes, checksums: sums, signature: attackerSignature)
            let forged = UpdateDownloader(fetcher: forgedFetcher, workRoot: root, trust: trusted.trust)
            await #expect(throws: UpdateError.badSignature) {
                try await forged.download(FixtureAssets.make()) { _ in }
            }

            // 3. The shipping trust list never accepts a signature from a random key.
            let production = UpdateDownloader(fetcher: forgedFetcher, workRoot: root)
            await #expect(throws: UpdateError.badSignature) {
                try await production.download(FixtureAssets.make()) { _ in }
            }

            // 4. A trust list with no keys accepts nothing, even a well-formed signature.
            let emptyTrust = UpdateDownloader(fetcher: forgedFetcher, workRoot: root, trust: UpdateTrust(publicKeys: []))
            await #expect(throws: UpdateError.badSignature) {
                try await emptyTrust.download(FixtureAssets.make()) { _ in }
            }

            #expect(!forgedFetcher.requestedURLs.contains(FixtureAssets.archiveURL))
            #expect(updateFolders(in: root).isEmpty)
        }
    }

    /// A shipping build with no usable key could never update itself again.
    @Test func production_trustsEveryListedKeyAndAtLeastOne() throws {
        #expect(!UpdateTrust.productionPublicKeys.isEmpty)
        for text in UpdateTrust.productionPublicKeys {
            let data = try #require(Data(base64Encoded: text))
            #expect(data.count == 32)
            #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil)
        }
    }
}
