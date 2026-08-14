import Foundation
import Testing

@testable import KVoiceCore

@Suite("Vector math")
struct VectorMathTests {

    @Test("l2Normalized produces a unit vector")
    func normalizes() {
        let normalized = VectorMath.l2Normalized([3, 4])
        #expect(abs(VectorMath.l2Norm(normalized) - 1) < 1e-6)
        #expect(abs(normalized[0] - 0.6) < 1e-6)
        #expect(abs(normalized[1] - 0.8) < 1e-6)
    }

    @Test("l2Normalized leaves a zero vector alone rather than dividing by zero")
    func normalizingZeroIsSafe() {
        let zero = [Float](repeating: 0, count: 8)
        #expect(VectorMath.l2Normalized(zero) == zero)
    }

    @Test("cosine similarity of identical vectors is 1, opposites -1, orthogonal 0")
    func cosineExtremes() {
        let vector: [Float] = [1, 2, 3, 4]
        #expect(abs(VectorMath.cosineSimilarity(vector, vector) - 1) < 1e-6)
        #expect(abs(VectorMath.cosineSimilarity(vector, vector.map { -$0 }) + 1) < 1e-6)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
    }

    @Test("cosine similarity is scale invariant")
    func cosineIgnoresMagnitude() {
        let a: [Float] = [1, 2, 3]
        let b = a.map { $0 * 17.5 }
        #expect(abs(VectorMath.cosineSimilarity(a, b) - 1) < 1e-6)
    }

    /// A profile written by a 256-d backend must not crash the matcher after a
    /// switch to a 192-d one — it must simply fail to match (plan §0 fallback).
    @Test("mismatched dimensions score 0 instead of trapping")
    func dimensionMismatch() {
        #expect(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VectorMath.dot([1, 2, 3], [1, 2]) == 0)
    }

    @Test("zero-length vectors score 0")
    func zeroVectorsScoreZero() {
        #expect(VectorMath.cosineSimilarity([0, 0], [1, 1]) == 0)
        #expect(VectorMath.cosineSimilarity([], []) == 0)
    }

    @Test("mean averages element-wise")
    func meanAverages() throws {
        let mean = try #require(VectorMath.mean([[0, 0, 2], [2, 4, 4]]))
        #expect(mean == [1, 2, 3])
    }

    @Test("mean rejects empty or ragged input")
    func meanRejectsBadInput() {
        #expect(VectorMath.mean([]) == nil)
        #expect(VectorMath.mean([[]]) == nil)
        #expect(VectorMath.mean([[1, 2], [1, 2, 3]]) == nil)
    }

    @Test("centroid averages then normalizes to unit length")
    func centroidIsUnitLength() throws {
        let centroid = try #require(VectorMath.centroid([[1, 0], [0, 1]]))
        #expect(abs(VectorMath.l2Norm(centroid) - 1) < 1e-6)
        #expect(abs(centroid[0] - centroid[1]) < 1e-6)
    }

    /// Two exactly opposite vectors average to zero, which carries no speaker
    /// information; nil is the honest answer.
    @Test("centroid of cancelling vectors is nil, not a zero vector")
    func centroidOfCancellingVectors() {
        #expect(VectorMath.centroid([[1, 0], [-1, 0]]) == nil)
    }

    @Test("test helper produces vectors at the requested similarity")
    func neighborHelperIsAccurate() {
        let base = TestVectors.unit(seed: 1)
        for target: Float in [0.2, 0.5, 0.62, 0.9] {
            let neighbor = TestVectors.neighbor(of: base, similarity: target)
            #expect(abs(VectorMath.cosineSimilarity(base, neighbor) - target) < 1e-3)
        }
    }
}
