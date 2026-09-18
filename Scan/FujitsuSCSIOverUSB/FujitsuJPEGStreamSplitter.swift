import Foundation

/// Turns the JPEG byte stream a Fujitsu scanner produces in hardware
/// compression mode into one complete JPEG file per side.
///
/// This is a port of SANE's `read_from_JPEGduplex()` / `inject_jfif_header()`:
///
/// - The scanner omits the JFIF APP0 segment; one is inserted after SOI.
/// - In duplex mode most models send a single stream whose frame is twice as
///   wide as requested: the restart intervals alternate between the front and
///   the back side. Even-numbered RSTn markers switch to the back side,
///   odd-numbered ones back to the front. Each side gets the shared headers,
///   half the frame width, its own intervals and renumbered RST markers.
/// - If the frame width in SOF equals the requested width the stream is not
///   interlaced: it is a plain front-side JPEG and the back side has to be read
///   from the back window separately.
/// - Some models (the iX1600) write the requested window height into SOF and
///   simply stop the entropy data after the last real row once automatic
///   length detection ends the page. With a restart interval defined, the
///   number of restart intervals gives the number of MCU rows actually sent,
///   so the SOF height is corrected to that at EOI.
final class FujitsuJPEGStreamSplitter {
    enum Stage {
        case none, soi, head, sof, sos, front, back, eoi
    }

    let requestedWidth: Int
    let resolutionDPI: Int

    /// True while the stream is assumed to carry both sides. Starts as the
    /// `duplex` argument and flips to false when SOF reports the plain width.
    private(set) var isInterlaced: Bool
    private(set) var front = Data()
    private(set) var back = Data()
    /// Frame size per side as reported by SOF (height may be 0 when the
    /// scanner defers it to a DNL marker).
    private(set) var frameWidth = 0
    private(set) var frameHeight = 0
    private(set) var hasReachedEndOfImage = false

    /// Restart interval from DRI in MCUs, 0 when the stream has none.
    private(set) var restartInterval = 0

    private var stage: Stage = .none
    private var ffOffset = -1
    private var xByte: UInt8 = 0
    private var yByte: UInt8 = 0
    private var frontRestartCount = 0
    private var backRestartCount = 0
    private var currentMarker: UInt8 = 0
    private var componentCount = 0
    private var maxHorizontalSampling = 1
    private var maxVerticalSampling = 1
    /// Index of the SOF height's high byte in `front` / `back`.
    private var frontHeightOffset = -1
    private var backHeightOffset = -1

    init(requestedWidth: Int, resolutionDPI: Int, duplex: Bool) {
        self.requestedWidth = requestedWidth
        self.resolutionDPI = resolutionDPI
        self.isInterlaced = duplex
        front.reserveCapacity(4 * 1024 * 1024)
        if duplex {
            back.reserveCapacity(4 * 1024 * 1024)
        }
    }

    func feed(_ chunk: Data) {
        for original in chunk {
            if hasReachedEndOfImage {
                return
            }
            var byte = original

            // About to change stage: remember the 0xff, emit it with the next byte.
            if byte == 0xff && ffOffset != 0 {
                ffOffset = 0
                continue
            }

            // Last byte was 0xff, this one is a marker code (or a stuffed 0x00).
            if ffOffset == 0 {
                currentMarker = byte
                if stage == .soi && byte != 0xe0 {
                    appendJFIFHeader(to: &front)
                    if isInterlaced {
                        appendJFIFHeader(to: &back)
                    }
                    stage = .head
                }

                switch byte {
                case 0xd8:
                    stage = .soi
                case 0xe0, 0xc4, 0xdb, 0xdd:
                    // APP0 already present, or huffman/quantisation/restart tables.
                    stage = .head
                case 0xc0:
                    stage = .sof
                case 0xda:
                    stage = .sos
                case 0xd0...0xd7 where !isInterlaced:
                    stage = .front
                    frontRestartCount += 1
                case 0xd0, 0xd2, 0xd4, 0xd6:
                    stage = .back
                    if backRestartCount == 0 {
                        // The first back interval starts without a marker.
                        ffOffset += 1
                        backRestartCount += 1
                        continue
                    }
                    byte = 0xd0 + UInt8((backRestartCount - 1) % 8)
                    backRestartCount += 1
                case 0xd1, 0xd3, 0xd5, 0xd7:
                    stage = .front
                    byte = 0xd0 + UInt8(frontRestartCount % 8)
                    frontRestartCount += 1
                case 0xd9:
                    stage = .eoi
                default:
                    break
                }
            }
            ffOffset += 1

            if stage == .head && currentMarker == 0xdd {
                // DRI: length (2 bytes) then the restart interval in MCUs.
                if ffOffset == 4 {
                    restartInterval = Int(byte) << 8
                } else if ffOffset == 5 {
                    restartInterval |= Int(byte)
                }
            }

            if stage == .sof {
                switch ffOffset {
                case 5:
                    yByte = byte
                case 6:
                    frameHeight = Int(yByte) << 8 | Int(byte)
                case 9:
                    componentCount = Int(byte)
                    maxHorizontalSampling = 1
                    maxVerticalSampling = 1
                case 11...:
                    // Component descriptors: id, sampling factors (h << 4 | v), table.
                    if componentCount > 0, (ffOffset - 11) % 3 == 0, (ffOffset - 11) / 3 < componentCount {
                        maxHorizontalSampling = max(maxHorizontalSampling, Int(byte >> 4))
                        maxVerticalSampling = max(maxVerticalSampling, Int(byte & 0x0f))
                    }
                case 7:
                    // High byte of the frame width; emitted once the width is known.
                    xByte = byte
                    continue
                case 8:
                    let width = Int(xByte) << 8 | Int(byte)
                    if isInterlaced && width != requestedWidth {
                        // Both sides side by side: halve the width for each copy.
                        frameWidth = width / 2
                        front.append(UInt8(truncatingIfNeeded: width >> 9))
                        back.append(UInt8(truncatingIfNeeded: width >> 9))
                        byte = UInt8(truncatingIfNeeded: (width >> 1) & 0xff)
                    } else {
                        if isInterlaced {
                            isInterlaced = false
                            back.removeAll()
                        }
                        frameWidth = width
                        front.append(xByte)
                    }
                default:
                    break
                }
            }

            if [.soi, .head, .sof, .sos, .eoi, .front].contains(stage) {
                if ffOffset == 1 {
                    front.append(0xff)
                }
                front.append(byte)
                if stage == .sof && ffOffset == 5 {
                    frontHeightOffset = front.count - 1
                }
            }
            if isInterlaced && [.soi, .head, .sof, .sos, .eoi, .back].contains(stage) {
                if ffOffset == 1 {
                    back.append(0xff)
                }
                back.append(byte)
                if stage == .sof && ffOffset == 5 {
                    backHeightOffset = back.count - 1
                }
            }

            // Last byte of a three-component SOS segment; entropy data follows.
            if stage == .sos && ffOffset == 0x0d {
                stage = .front
            }
            if stage == .eoi {
                hasReachedEndOfImage = true
                correctFrameHeight()
            }
        }
    }

    /// Rows actually delivered for `intervals` restart intervals, rounded up
    /// to whole MCU rows.
    private func deliveredRows(intervals: Int) -> Int {
        let mcuWidth = 8 * maxHorizontalSampling
        let mcuHeight = 8 * maxVerticalSampling
        let mcusPerRow = max(1, (frameWidth + mcuWidth - 1) / mcuWidth)
        let mcus = intervals * restartInterval
        return (mcus + mcusPerRow - 1) / mcusPerRow * mcuHeight
    }

    /// Shrinks the SOF height to the rows the scanner actually sent when it
    /// wrote the window height into SOF and ended the data early.
    private func correctFrameHeight() {
        guard restartInterval > 0, frameWidth > 0, frameHeight > 0 else { return }
        let declaredHeight = frameHeight
        // The first interval of each side starts without a marker.
        let frontRows = deliveredRows(intervals: frontRestartCount + 1)
        if frontRows < declaredHeight, frontHeightOffset >= 0, frontHeightOffset + 1 < front.count {
            front[frontHeightOffset] = UInt8(truncatingIfNeeded: frontRows >> 8)
            front[frontHeightOffset + 1] = UInt8(truncatingIfNeeded: frontRows)
            frameHeight = frontRows
        }
        if isInterlaced {
            let backRows = deliveredRows(intervals: backRestartCount)
            if backRows < declaredHeight, backHeightOffset >= 0, backHeightOffset + 1 < back.count {
                back[backHeightOffset] = UInt8(truncatingIfNeeded: backRows >> 8)
                back[backHeightOffset + 1] = UInt8(truncatingIfNeeded: backRows)
            }
        }
    }

    private func appendJFIFHeader(to data: inout Data) {
        var header: [UInt8] = [
            0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46,
            0x00, 0x01, 0x02, 0x01, 0x00, 0x48, 0x00, 0x48,
            0x00, 0x00
        ]
        header[12] = UInt8(truncatingIfNeeded: resolutionDPI >> 8)
        header[13] = UInt8(truncatingIfNeeded: resolutionDPI)
        header[14] = header[12]
        header[15] = header[13]
        data.append(contentsOf: header)
    }
}
