import Foundation

@main
enum DynamicCoverInterfaceTests {
    final class Asset {}

    static func main() {
        let registry = DynamicCoverRegistry<Asset>()
        let owner = UUID()
        let otherOwner = UUID()
        registry.begin(coverArtId: "cover-1")
        let revision = registry.revision
        var original: Asset? = Asset()
        weak var pinned = original
        registry.publish(original!, format: "square", rank: 0)
        let depth = Asset()
        registry.publish(depth, format: "square", rank: 2)
        registry.publish(Asset(), format: "square", rank: 1)
        precondition(registry.current(coverArtId: "cover-1", format: "square", mode: "dynamic") === depth)
        precondition(registry.current(coverArtId: "cover-1", format: "square", mode: "static") === original)
        precondition(registry.current(coverArtId: "other", format: "square", mode: "dynamic") == nil)
        precondition(registry.current(coverArtId: "cover-1", format: "portrait", mode: "dynamic") == nil)
        let portrait = Asset()
        registry.publish(portrait, format: "portrait", rank: 2)
        precondition(registry.current(coverArtId: "cover-1", format: "any", mode: "dynamic") === portrait)
        registry.publish(depth, format: "square", rank: 2)
        precondition(registry.current(coverArtId: "cover-1", format: "any", mode: "dynamic") === depth)
        let lease = registry.retain(original!, owner: owner)!
        original = nil
        registry.begin(coverArtId: nil)
        precondition(registry.revision != revision)
        precondition(pinned != nil, "Lease must protect the asset after a track change")
        registry.release(lease, owner: otherOwner)
        precondition(pinned != nil, "A different bridge cannot release this lease")
        registry.release(lease, owner: owner)
        registry.release(lease, owner: owner)
        precondition(pinned == nil, "Release must relinquish the last asset reference")
        for _ in 0..<32 { precondition(registry.retain(depth, owner: owner) != nil) }
        precondition(registry.retain(depth, owner: owner) == nil)
        precondition(registry.retain(depth, owner: otherOwner) != nil)
        registry.releaseAll(owner: owner)
        precondition(registry.retain(depth, owner: owner) != nil)
        print("Dynamic cover registry: stage selection, revision isolation, lease lifetime and limits passed")
    }
}
