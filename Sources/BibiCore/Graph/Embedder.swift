import Foundation
import NaturalLanguage

/// Turns text into a vector for similarity. The default uses Apple's on-device sentence embedding.
public protocol Embedder: Sendable {
    func vector(_ text: String) -> [Float]?
}

/// NLEmbedding's English sentence embedding (512 dimensions), loaded once. nil if the asset isn't available,
/// in which case Similarity falls back to word overlap.
public final class SentenceEmbedder: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var embedding: NLEmbedding?

    public init() {}

    public func vector(_ text: String) -> [Float]? {
        lock.withLock {
            if !loaded {
                embedding = NLEmbedding.sentenceEmbedding(for: .english)
                loaded = true
            }
            return embedding?.vector(for: text.lowercased()).map { $0.map(Float.init) }
        }
    }
}

/// No vectors: similarity uses word overlap only (tests, or when embeddings are unavailable).
public struct NoEmbedder: Embedder {
    public init() {}
    public func vector(_: String) -> [Float]? { nil }
}
