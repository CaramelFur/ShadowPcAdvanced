import Accelerate
import AppKit
import IOSurface

/// BGRA copy of the guest's primary surface in an IOSurface, which a CALayer
/// shows directly (the GPU composites and scales it).
///
/// spice-glib decodes into its own memory and reports dirty rectangles —
/// thousands per second on a busy screen. `invalidate` therefore only grows a
/// dirty rectangle (O(1), on the GLib thread); the pixels are copied once per
/// displayed frame by `flush`, off both the GLib and the main thread.
final class SpiceFramebuffer: @unchecked Sendable {
    // SPICE_SURFACE_FMT_*
    private static let format16_555: Int32 = 16
    private static let format16_565: Int32 = 80

    /// Guards the fields below; held only for moments.
    private let state = NSLock()
    /// Held while pixels are being read from `source`, so `create`/`destroy`
    /// can't pull the memory away mid-copy. Never taken by `invalidate`.
    private let sourceGuard = NSLock()

    private var surface: IOSurface?
    private var source: UnsafePointer<UInt8>?
    private var sourceStride = 0
    private var format: Int32 = 32
    private var width = 0
    private var height = 0
    private var dirty: (x0: Int, y0: Int, x1: Int, y1: Int)?

    var currentSurface: IOSurface? { state.withLock { surface } }
    var size: CGSize { state.withLock { CGSize(width: width, height: height) } }

    // MARK: GLib thread

    func create(format: Int32, width: Int, height: Int, stride: Int, data: UnsafePointer<UInt8>?) {
        let fresh = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
        ])
        sourceGuard.withLock {
            state.withLock {
                surface = fresh
                source = data
                // A negative stride means the rows are stored bottom-up.
                sourceStride = stride
                self.format = format
                self.width = width
                self.height = height
                dirty = (0, 0, width, height)
            }
        }
    }

    func destroy() {
        sourceGuard.withLock {
            state.withLock {
                source = nil
                surface = nil
                width = 0
                height = 0
                dirty = nil
            }
        }
    }

    func invalidate(x: Int, y: Int, width w: Int, height h: Int) {
        state.withLock {
            let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
            guard x1 > x0, y1 > y0 else { return }
            if let d = dirty {
                dirty = (min(d.x0, x0), min(d.y0, y0), max(d.x1, x1), max(d.y1, y1))
            } else {
                dirty = (x0, y0, x1, y1)
            }
        }
    }

    // MARK: render queue

    /// Copies everything invalidated since the last call. Returns false when
    /// there was nothing to do.
    @discardableResult
    func flush() -> Bool {
        sourceGuard.lock()
        defer { sourceGuard.unlock() }
        let snapshot = state.withLock { () -> (IOSurface, UnsafePointer<UInt8>, Int, Int32, Int, (x0: Int, y0: Int, x1: Int, y1: Int))? in
            guard let surface, let source, let d = dirty else { return nil }
            dirty = nil
            return (surface, source, sourceStride, format, height, d)
        }
        guard let (surface, source, stride, format, height, d) = snapshot else { return false }

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let dstStride = surface.bytesPerRow
        let dstBase = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let absStride = abs(stride)
        let columns = d.x1 - d.x0, rows = d.y1 - d.y0

        if format == Self.format16_555 || format == Self.format16_565 {
            let is565 = format == Self.format16_565
            for row in d.y0..<d.y1 {
                let srcRow = source + (stride < 0 ? (height - 1 - row) : row) * absStride
                let src = UnsafeRawPointer(srcRow + d.x0 * 2).assumingMemoryBound(to: UInt16.self)
                let dst = UnsafeMutableRawPointer(dstBase + row * dstStride + d.x0 * 4).assumingMemoryBound(to: UInt32.self)
                for i in 0..<columns {
                    let p = UInt32(src[i])
                    let r = is565 ? (p >> 11) & 0x1F : (p >> 10) & 0x1F
                    let g = is565 ? (p >> 5) & 0x3F : (p >> 5) & 0x1F
                    let b = p & 0x1F
                    let g8 = is565 ? (g << 2 | g >> 4) : (g << 3 | g >> 2)
                    dst[i] = 0xFF00_0000 | (r << 3 | r >> 2) << 16 | g8 << 8 | (b << 3 | b >> 2)
                }
            }
            return true
        }

        // 32-bit: xRGB leaves the alpha byte undefined, so copy B,G,R and force
        // A to 0xFF — one SIMD pass with vImage (fast even in debug builds).
        var dst = vImage_Buffer(data: dstBase + d.y0 * dstStride + d.x0 * 4, height: vImagePixelCount(rows), width: vImagePixelCount(columns), rowBytes: dstStride)
        if stride > 0 {
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: source + d.y0 * stride + d.x0 * 4),
                height: vImagePixelCount(rows), width: vImagePixelCount(columns), rowBytes: stride
            )
            // copyMask 0x1 = the last of the four channels, which is A in BGRA memory order.
            vImageOverwriteChannelsWithScalar_ARGB8888(0xFF, &src, &dst, 0x1, vImage_Flags(kvImageNoFlags))
        } else {
            for row in d.y0..<d.y1 {
                memcpy(dstBase + row * dstStride + d.x0 * 4, source + (height - 1 - row) * absStride + d.x0 * 4, columns * 4)
            }
            vImageOverwriteChannelsWithScalar_ARGB8888(0xFF, &dst, &dst, 0x1, vImage_Flags(kvImageNoFlags))
        }
        return true
    }

    // MARK: any thread

    func pngData() -> Data? {
        guard let surface = currentSurface else { return nil }
        let width = surface.width, height = surface.height
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
