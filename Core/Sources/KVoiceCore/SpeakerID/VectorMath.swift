import Foundation

/// Vector primitives for speaker embeddings.
///
/// Deliberately plain Swift (no Accelerate, no model dependency) so the
/// matcher's arithmetic is exercised by unit tests that need neither a
/// downloaded model nor a network. Embeddings are 256-d, so the constant
/// factor is irrelevant next to CoreML inference.
public enum VectorMath {

    /// Euclidean (L2) length.
    public static func l2Norm(_ vector: [Float]) -> Float {
        var sum: Float = 0
        for value in vector { sum += value * value }
        return sum.squareRoot()
    }

    /// Unit-length copy. A zero (or non-finite) vector is returned unchanged —
    /// callers treat a zero vector as "no usable embedding" rather than
    /// dividing by zero.
    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = l2Norm(vector)
        guard norm.isFinite, norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Dot product. Returns 0 when the dimensions disagree.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }

    /// Cosine similarity in `-1...1`.
    ///
    /// Returns 0 for a dimension mismatch or a zero-length vector. Dimension
    /// mismatch is a real case, not paranoia: a profile written by one
    /// embedding backend (256-d WeSpeaker) must not crash the matcher after a
    /// switch to another (e.g. 192-d ECAPA-TDNN, the documented fallback in
    /// plan §0) — it must simply fail to match.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let normA = l2Norm(a)
        let normB = l2Norm(b)
        guard normA > 0, normB > 0 else { return 0 }
        let value = dot(a, b) / (normA * normB)
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }

    /// Element-wise mean. Returns nil for an empty input or ragged dimensions.
    public static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        guard vectors.allSatisfy({ $0.count == first.count }) else { return nil }

        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            for index in vector.indices { sum[index] += vector[index] }
        }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }

    /// The cluster embedding: mean of the span embeddings, L2-normalized.
    ///
    /// This is spec §3 step 3 ("average them into a cluster embedding"). The
    /// normalization makes cosine similarity equal to the dot product and
    /// keeps every stored vector on the same scale regardless of how many
    /// spans went into it.
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let mean = mean(vectors) else { return nil }
        let normalized = l2Normalized(mean)
        // An all-zero mean (e.g. two exactly opposite vectors) carries no
        // speaker information; surface that as nil rather than a zero vector
        // that would silently score 0 against everything.
        return l2Norm(normalized) > 0 ? normalized : nil
    }
}
