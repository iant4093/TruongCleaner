import Testing
@testable import CleanerCore

struct ByteFormatterTests {
    @Test(arguments: [
        (Int64(1_500_000), "MB"),
        (Int64(12_400_000_000), "GB"),
        (Int64(2_000), "kB"),
    ])
    func usesFinderUnits(bytes: Int64, unit: String) {
        #expect(ByteFormatter.string(bytes).contains(unit))
    }
}
