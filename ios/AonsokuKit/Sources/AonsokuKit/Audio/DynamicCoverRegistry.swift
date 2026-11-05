import Foundation

/// Main-queue publication registry. Leases retain the producer's existing asset,
/// so its weak cache registry continues protecting live files without a new cache.
final class DynamicCoverRegistry<Asset: AnyObject> {
  private(set) var revision = 0
  private(set) var coverArtId: String?
  private var published: [String: (asset: Asset, rank: Int, order: Int)] = [:]
  private var publicationOrder = 0
  private var leases: [String: (owner: UUID, asset: Asset)] = [:]

  func begin(coverArtId: String?) {
    revision += 1
    self.coverArtId = coverArtId
    published.removeAll()
    // Outstanding video consumers explicitly release their old leases.
  }

  func publish(_ asset: Asset, format: String, rank: Int) {
    guard coverArtId != nil else { return }
    publicationOrder += 1
    if rank == 0 { published["\(format)-static"] = (asset, rank, publicationOrder) }
    let key = "\(format)-dynamic"
    if rank >= (published[key]?.rank ?? -1) { published[key] = (asset, rank, publicationOrder) }
  }

  func current(coverArtId: String, format: String, mode: String) -> Asset? {
    guard self.coverArtId == coverArtId else { return nil }
    if format == "any" {
      return published.filter { $0.key.hasSuffix("-\(mode)") }
        .sorted {
          $0.value.rank == $1.value.rank
            ? $0.value.order > $1.value.order : $0.value.rank > $1.value.rank
        }
        .first?.value.asset
    }
    return published["\(format)-\(mode)"]?.asset
  }

  func retain(_ asset: Asset, owner: UUID) -> String? {
    guard leases.values.filter({ $0.owner == owner }).count < 32 else { return nil }
    let id = UUID().uuidString
    leases[id] = (owner, asset)
    return id
  }

  func release(_ id: String, owner: UUID) {
    guard leases[id]?.owner == owner else { return }
    leases.removeValue(forKey: id)
  }

  func releaseAll(owner: UUID) {
    leases = leases.filter { $0.value.owner != owner }
  }
}
