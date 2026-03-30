import Testing
@testable import FlasherFeature

@Test func parseDDProgressBSDStyle() async throws {
    let output = "12345678 bytes transferred in 1.234567 secs (9876543 bytes/sec)\n"
    let parsed = await WriterManager.parseDDProgress(output: output)
    #expect(parsed?.bytes == 12_345_678)
    #expect(parsed?.speed == 9_876_543)
}

@Test func parseDDProgressGNULike() async throws {
    let output = "512000000 bytes (512 MB) copied, 5.0 s, 102 MB/s"
    let parsed = await WriterManager.parseDDProgress(output: output)
    #expect(parsed?.bytes == 512_000_000)
    #expect(parsed?.speed != nil)
}
