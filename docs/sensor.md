# Lid-angle sensor

Measured on a MacBook Pro (Mac17,9, M5 Pro) with macOS 26.5.

## Device

HID device VID 0x05AC, PID 0x8104, on the always-on sensor processor (SPU). The hardware is a
magnetic angle sensor in the hinge. The lid-angle collection is usage page 0x0020 (Sensor), usage
0x008A (Orientation).

| Report ID | Type | Size | Range | Meaning |
|---|---|---|---|---|
| 1 | input, also readable as feature | 9 bits | 0...360 | Lid angle, whole degrees |
| 7 | input | 50 bits as declared; 4 data bytes | 0...36000, exponent −2 | **Lid angle, hundredths of a degree** |
| 6 | output | 8 bits | 0...1 | Unknown; never written |

The remaining reports (2–5, 8) carry no angle.

## Reading the angle

- **Report 7 (fine)**: `IOHIDDeviceGetReport(kIOHIDReportTypeInput, 7)` returns `[07, b0, b1, b2, b3]`,
  a little-endian unsigned value in hundredths of a degree. Example: `07 DA 2F 00 00` → 12250 →
  122.50°.
- **Report 1 (coarse)**: `IOHIDDeviceGetReport(kIOHIDReportTypeFeature, 1)` returns `[01, lo, hi]` in
  whole degrees, the rounded value of report 7. Used only if report 7 is unreadable.
- **Pushed reports**: only report 1, once per second, with or without a subscription. That is too
  slow for animation, and the app polls the sensor.

Reading a report returns the processor's latest value without triggering a measurement. macOS uses
a separate lid switch for clamshell sleep.

## Timing and noise

| Measure | Value |
|---|---|
| Read latency | about 1–1.2 ms |
| Polling at 120 Hz | 120 Hz achieved, no failures |
| Noise at rest (report 7) | standard deviation 0.037°, range ±0.08° |
| Interval between value changes, at rest | median about 100 ms |
| Interval between value changes, moving | median about 100 ms (74–217 ms) |
| Step size during a brisk close | about 10° per update |

The value refreshes at about 10 Hz at all times. Polling faster only timestamps each new value more
precisely. Anything drawn at the display rate has to reconstruct motion between readings
(see [Architecture](ARCHITECTURE.md#motion-between-sensor-updates)).

## Decisions

- Poll report 7 on a dedicated thread: 5 Hz at utility priority while dormant, 120 Hz while awake.
  Fall back to report 1 on hardware where report 7 is unreadable, with wider noise tolerances.
- Treat values outside 0...360° as invalid reads.
- Never write output report 6.

## Screen capture latency

On the same Mac at 3600×2338, fetching the shareable content takes about 50 ms, and a stream started
with a ready filter delivers its first complete frame after about 25 ms. The app caches the content
filter and starts capture on wake.
