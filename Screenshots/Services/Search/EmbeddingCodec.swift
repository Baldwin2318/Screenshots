import Accelerate
import Foundation

enum EmbeddingCodec {
    static let dimension = 512

    static func encodeNormalizedVector(_ vector: [Float]) -> Data? {
        guard vector.count == dimension else { return nil }
        let normalized = normalize(vector)
        guard normalized.count == dimension else { return nil }
        return normalized.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: dimension * MemoryLayout<Float>.size)
        }
    }

    static func decodeNormalizedVector(from data: Data) -> [Float]? {
        let expectedByteCount = dimension * MemoryLayout<Float>.size
        guard data.count == expectedByteCount else { return nil }

        var vector = [Float](repeating: 0, count: dimension)
        _ = vector.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return normalize(vector)
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var squares: Float = 0
        vector.withUnsafeBufferPointer { pointer in
            vDSP_svesq(pointer.baseAddress!, 1, &squares, vDSP_Length(vector.count))
        }
        let magnitude = sqrt(max(squares, 0.000_000_1))
        var divisor = magnitude
        var output = [Float](repeating: 0, count: vector.count)
        vector.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vsdiv(src.baseAddress!, 1, &divisor, dst.baseAddress!, 1, vDSP_Length(vector.count))
            }
        }
        return output
    }
}
