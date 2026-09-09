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

    private var stage: Stage = .none
    private var ffOffset = -1
    private var xByte: UInt8 = 0
    private var yByte: UInt8 = 0
    private var frontRestartCount = 0
    private var backRestartCount = 0

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

            if stage == .sof {
                switch ffOffset {
                case 5:
                    yByte = byte
                case 6:
                    frameHeight = Int(yByte) << 8 | Int(byte)
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
            }
            if isInterlaced && [.soi, .head, .sof, .sos, .eoi, .back].contains(stage) {
                if ffOffset == 1 {
                    back.append(0xff)
                }
                back.append(byte)
            }

            // Last byte of a three-component SOS segment; entropy data follows.
            if stage == .sos && ffOffset == 0x0d {
                stage = .front
            }
            if stage == .eoi {
                hasReachedEndOfImage = true
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
