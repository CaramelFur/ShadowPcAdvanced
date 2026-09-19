import AppKit
import IOSurface

/// BGRA copy of the guest's primary surface, backed by an IOSurface that a
/// CALayer can show directly.
///
/// spice-glib owns the source pixels and only guarantees them inside its
/// display callbacks, so dirty rectangles are copied here *on the GLib thread*;
/// the main thread only ever touches the IOSurface.
final class SpiceFramebuffer: @unchecked Sendable {
    // SPICE_SURFACE_FMT_*
    private static let format16_555: Int32 = 16
    private static let format16_565: Int32 = 80

    private let lock = NSLock()
    private var surface: IOSurface?
    private var source: UnsafePointer<UInt8>?
    private var sourceStride = 0
    private var format: Int32 = 32
    private(set) var width = 0
    private(set) var height = 0

    var currentSurface: IOSurface? { lock.withLock { surface } }
    var size: CGSize { lock.withLock { CGSize(width: width, height: height) } }

    // MARK: GLib thread

    func create(format: Int32, width: Int, height: Int, stride: Int, data: UnsafePointer<UInt8>?) {
        let fresh = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
        ])
        lock.withLock {
            surface = fresh
            source = data
            // A negative stride means the rows are stored bottom-up.
            sourceStride = stride
            self.format = format
            self.width = width
            self.height = height
        }
        invalidate(x: 0, y: 0, width: width, height: height)
    }

    func destroy() {
        lock.withLock {
            source = nil
            surface = nil
            width = 0
            height = 0
        }
    }

    func invalidate(x: Int, y: Int, width w: Int, height h: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface, let source else { return }
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return }

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let dstStride = surface.bytesPerRow
        let dstBase = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let absStride = abs(sourceStride)
        let count = x1 - x0

        for row in y0..<y1 {
            let srcRow = source + (sourceStride < 0 ? (height - 1 - row) : row) * absStride
            let dst = UnsafeMutableRawPointer(dstBase + row * dstStride + x0 * 4).assumingMemoryBound(to: UInt32.self)
            if format == Self.format16_555 || format == Self.format16_565 {
                let src = UnsafeRawPointer(srcRow + x0 * 2).assumingMemoryBound(to: UInt16.self)
                let is565 = format == Self.format16_565
                for i in 0..<count {
                    let p = UInt32(src[i])
                    let r = is565 ? (p >> 11) & 0x1F : (p >> 10) & 0x1F
                    let g = is565 ? (p >> 5) & 0x3F : (p >> 5) & 0x1F
                    let b = p & 0x1F
                    let g8 = is565 ? (g << 2 | g >> 4) : (g << 3 | g >> 2)
                    dst[i] = 0xFF00_0000 | (r << 3 | r >> 2) << 16 | g8 << 8 | (b << 3 | b >> 2)
                }
            } else {
                // xRGB leaves the alpha byte undefined; force it opaque.
                let src = UnsafeRawPointer(srcRow + x0 * 4).assumingMemoryBound(to: UInt32.self)
                for i in 0..<count { dst[i] = src[i] | 0xFF00_0000 }
            }
        }
    }

    // MARK: any thread

    func pngData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let surface, width > 0, height > 0 else { return nil }
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
