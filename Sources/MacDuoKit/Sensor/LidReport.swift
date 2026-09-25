import Foundation

/// One reading of the lid hinge angle.
public struct LidSample: Sendable, Equatable {
    public enum Resolution: String, Sendable, Codable {
        /// Input report 7, hundredths of a degree.
        case fine
        /// Feature report 1, whole degrees.
        case coarse
    }

    /// Hinge angle in degrees; 0 is closed.
    public let angle: Double
    /// Host time in seconds (`CACurrentMediaTime()`).
    public let timestamp: TimeInterval
    public let resolution: Resolution

    public init(angle: Double, timestamp: TimeInterval, resolution: Resolution) {
        self.angle = angle
        self.timestamp = timestamp
        self.resolution = resolution
    }
}

/// HID identity and report layouts of the MacBook lid-angle sensor (see docs/sensor.md).
public enum LidReport {
    public static let vendorID = 0x05AC
    public static let productID = 0x8104
    public static let usagePage = 0x0020
    public static let usage = 0x008A

    public static let fineReportID: UInt8 = 7
    public static let coarseReportID: UInt8 = 1

    public static let validDegrees: ClosedRange<Double> = 0...360

    /// Input report 7: `[7, b0, b1, b2?, b3?]`, little-endian unsigned hundredths of a degree.
    public static func decodeFine(_ bytes: some Collection<UInt8>) -> Double? {
        let bytes = Array(bytes)
        guard bytes.count >= 3, bytes[0] == fineReportID else { return nil }
        var value: UInt32 = 0
        for (index, byte) in bytes.dropFirst().prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * UInt32(index))
        }
        let degrees = Double(value) / 100
        return validDegrees.contains(degrees) ? degrees : nil
    }

    /// Feature report 1: `[1, lo, hi]`, little-endian signed whole degrees.
    public static func decodeCoarse(_ bytes: some Collection<UInt8>) -> Double? {
        let bytes = Array(bytes)
        guard bytes.count >= 3, bytes[0] == coarseReportID else { return nil }
        let degrees = Double(Int16(bitPattern: UInt16(bytes[1]) | UInt16(bytes[2]) << 8))
        return validDegrees.contains(degrees) ? degrees : nil
    }
}
