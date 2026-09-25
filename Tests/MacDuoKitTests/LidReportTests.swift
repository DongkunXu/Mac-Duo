import Testing
@testable import MacDuoKit

struct LidReportTests {
    @Test func decodesFineReportMeasuredOnDevice() {
        #expect(LidReport.decodeFine([0x07, 0xDA, 0x2F, 0x00, 0x00]) == 122.5)
    }

    @Test func decodesFineReportWithoutPadding() {
        #expect(LidReport.decodeFine([0x07, 0x10, 0x27]) == 100)
    }

    @Test func rejectsFineReportWithWrongIDOrLength() {
        #expect(LidReport.decodeFine([0x01, 0xDA, 0x2F, 0x00, 0x00]) == nil)
        #expect(LidReport.decodeFine([0x07, 0xDA]) == nil)
        #expect(LidReport.decodeFine([UInt8]()) == nil)
    }

    @Test func rejectsFineReportOutOfRange() {
        // 36001 hundredths = 360.01°
        #expect(LidReport.decodeFine([0x07, 0xA1, 0x8C, 0x00, 0x00]) == nil)
        #expect(LidReport.decodeFine([0x07, 0x00, 0x00, 0x00, 0x01]) == nil)
    }

    @Test func decodesCoarseReportMeasuredOnDevice() {
        #expect(LidReport.decodeCoarse([0x01, 0x7B, 0x00]) == 123)
        #expect(LidReport.decodeCoarse([0x01, 0x7A, 0x00]) == 122)
    }

    @Test func rejectsCoarseReportWithWrongIDOrLength() {
        #expect(LidReport.decodeCoarse([0x07, 0x7B, 0x00]) == nil)
        #expect(LidReport.decodeCoarse([0x01, 0x7B]) == nil)
    }

    @Test func rejectsCoarseReportOutOfRange() {
        #expect(LidReport.decodeCoarse([0x01, 0xFF, 0xFF]) == nil) // -1
        #expect(LidReport.decodeCoarse([0x01, 0x69, 0x01]) == nil) // 361
    }
}
