import Foundation

/// Converts a speaker embedding between its in-memory form (`[Float]`) and the
/// form SwiftData stores (`Data`).
///
/// Embeddings are persisted as a raw little-endian Float32 blob rather than as
/// a SwiftData `[Float]` attribute. Two reasons:
///
/// - **Size and predictability.** A 256-d vector is exactly 1,024 bytes here.
///   SwiftData encodes `[Float]` attributes through an opaque archive whose
///   size and layout are an implementation detail; a profile at the FIFO cap
///   holds 20 of these, and every recording's `SpeakerSlot` holds one more.
/// - **Backend portability.** Plan §0 keeps an ECAPA-TDNN (192-d) fallback
///   open. A length-agnostic blob round-trips any dimension, and
///   `VectorMath.cosineSimilarity` already answers 0 for a dimension mismatch,
///   so a mixed store degrades to "no match" rather than to a crash.
///
/// Byte order is pinned to little-endian so a store written on one machine
/// reads correctly on another.
public enum EmbeddingBlob {

    /// Packs a vector into little-endian Float32 bytes.
    public static func data(from vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpacks little-endian Float32 bytes into a vector.
    ///
    /// Returns an empty array for empty input. Trailing bytes that do not
    /// complete a float are ignored rather than treated as a failure — a
    /// truncated blob is still worth whatever whole values it contains, and
    /// the matcher will simply score it against nothing of matching length.
    public static func vector(from data: Data) -> [Float] {
        let stride = MemoryLayout<UInt32>.size
        let count = data.count / stride
        guard count > 0 else { return [] }

        var vector = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { buffer in
            for index in 0..<count {
                var bits: UInt32 = 0
                withUnsafeMutableBytes(of: &bits) { destination in
                    destination.copyMemory(
                        from: UnsafeRawBufferPointer(
                            rebasing: buffer[(index * stride)..<((index + 1) * stride)]
                        )
                    )
                }
                vector[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return vector
    }
}
