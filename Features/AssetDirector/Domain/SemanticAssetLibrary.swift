import Foundation

// v1.87 AI Asset Director — the library state: records, relationships and
// settings, saved as one versioned file (see AssetAnalysisStore). Search,
// corrections, relationships and delete checks are pure operations on it.

enum AssetRelationKind: String, Codable, CaseIterable, Sendable {
    /// Picture ↔ 3D model of the same character.
    case sameCharacter
    /// Model ↔ its skeleton / rigged version.
    case rigOf
    /// Skeleton ↔ motion that fits it.
    case compatibleMotion
    /// Model ↔ material used on it.
    case usesMaterial
    /// Building piece ↔ kit it belongs to.
    case partOfKit
    /// Terrain asset ↔ map theme.
    case themeOf
    /// Reference ↔ model made from it.
    case derivedFrom
    /// World object ↔ asset version it uses.
    case usedInWorld
    /// Style-alike assets.
    case sameStyle
}

enum AssetRelationOrigin: String, Codable, Sendable {
    /// Recorded by a Moonlight pipeline (e.g. auto-rig wrote a new version).
    case pipeline
    /// Suggested by analysis; not true until the user confirms.
    case suggested
    case user
}

struct AssetRelationship: Codable, Equatable, Hashable, Sendable {
    var from: String
    var to: String
    var kind: AssetRelationKind
    var origin: AssetRelationOrigin
    var confirmed: Bool
    var note: String?
}

/// Privacy and cost settings for the Asset Director.
struct AssetDirectorSettings: Codable, Equatable, Sendable {
    /// Local analysis (default on).
    var localAnalysis = true
    /// Cloud vision: off until the user turns it on here. Separate from the
    /// World Director's text-only cloud planning permission.
    var cloudVision = false
    /// Images sent per cloud request at most, and per day.
    var cloudPerTask = 1
    var cloudDailyLimit = 20
    var cloudUsedToday = 0
    var cloudDay = ""
}

struct AssetLibraryState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var records: [String: AssetIntelligenceRecord] = [:]
    var relationships: [AssetRelationship] = []
    var settings = AssetDirectorSettings()
    /// Thresholds in use (fitted on labelled data when available).
    var calibration = AssetCalibration.starter
    /// Last evaluation on a labelled set, kept for the report.
    var lastEvaluation: AssetEvaluation?
    /// Pending analysis, saved so it resumes after the app is closed.
    var queue = AssetQueueState()
}

/// A search over the library.
struct AssetQuery: Equatable, Sendable {
    var text = ""
    var category: AssetCategory?
    var status: AssetStatus?
    var mediaType: AssetMediaType?
    var use: AssetUse?
}

enum SemanticAssetLibrary {
    // MARK: Records

    /// The record for a content hash (dedupe: one record per content).
    static func record(forHash hash: String, in state: AssetLibraryState) -> AssetIntelligenceRecord? {
        state.records.values.first { $0.contentHash == hash }
    }

    /// Adds a new asset or returns the existing record for the same content.
    @discardableResult
    static func upsert(_ record: AssetIntelligenceRecord, into state: inout AssetLibraryState) -> (record: AssetIntelligenceRecord, duplicate: Bool) {
        if let existing = record(forHash: record.contentHash, in: state) { return (existing, true) }
        state.records[record.assetID] = record
        return (record, false)
    }

    static func sorted(_ state: AssetLibraryState) -> [AssetIntelligenceRecord] {
        state.records.values.sorted { $0.createdAt == $1.createdAt ? $0.assetID < $1.assetID : $0.createdAt > $1.createdAt }
    }

    static func search(_ q: AssetQuery, in state: AssetLibraryState) -> [AssetIntelligenceRecord] {
        let words = q.text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return sorted(state).filter { r in
            if let c = q.category, !r.categories.contains(c) { return false }
            if let s = q.status, r.status != s { return false }
            if let m = q.mediaType, r.mediaType != m { return false }
            if let u = q.use, !r.recommendedUses.contains(u) { return false }
            guard !words.isEmpty else { return true }
            let hay = ([r.title.lowercased()] + r.allTagNames.map { $0.lowercased() } + r.styleTags + r.categories.map { $0.rawValue + " " + $0.title.lowercased() }
                       + r.recommendedUses.map(\.rawValue)).joined(separator: " ")
            return words.allSatisfy { hay.contains($0) }
        }
    }

    static func counts(_ state: AssetLibraryState) -> [AssetStatus: Int] {
        var c: [AssetStatus: Int] = [:]
        for r in state.records.values { c[r.status, default: 0] += 1 }
        return c
    }

    // MARK: Corrections

    /// The user's category choice: applied, recorded and locked so AI re-analysis keeps it.
    static func setCategory(_ id: String, primary: AssetCategory, secondary: [AssetCategory], in state: inout AssetLibraryState, now: Date) {
        guard var r = state.records[id] else { return }
        r.corrections.append(AssetCorrection(field: .category, before: r.categories.map(\.rawValue).joined(separator: ","),
                                             after: ([primary] + secondary).map(\.rawValue).joined(separator: ","), at: now))
        r.primaryCategory = primary
        r.secondaryCategories = secondary.filter { $0 != primary }
        r.decision = .automatic
        r.confidence = AssetConfidence(value: 1, kind: .user)
        r.locks.insert(.category)
        if r.status == .needsReview { r.status = .ready }
        r.updatedAt = now
        state.records[id] = r
    }

    static func removeTag(_ id: String, tag: String, in state: inout AssetLibraryState, now: Date) {
        guard var r = state.records[id] else { return }
        r.corrections.append(AssetCorrection(field: .tags, before: tag, after: "", at: now))
        r.semanticTags.removeAll { $0.name == tag }
        r.userTags.removeAll { $0 == tag }
        r.locks.insert(.tags)
        r.updatedAt = now
        state.records[id] = r
    }

    /// Custom tag: plain text, trimmed and bounded.
    static func addTag(_ id: String, tag raw: String, in state: inout AssetLibraryState, now: Date) {
        let tag = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !tag.isEmpty, var r = state.records[id], !r.userTags.contains(tag), r.userTags.count < 64 else { return }
        r.userTags.append(tag)
        r.corrections.append(AssetCorrection(field: .tags, before: "", after: tag, at: now))
        r.updatedAt = now
        state.records[id] = r
    }

    static func setLock(_ id: String, field: AssetLockField, locked: Bool, in state: inout AssetLibraryState) {
        guard var r = state.records[id] else { return }
        if locked { r.locks.insert(field) } else { r.locks.remove(field) }
        state.records[id] = r
    }

    static func setProvenance(_ id: String, _ provenance: AssetProvenance, in state: inout AssetLibraryState, now: Date) {
        guard var r = state.records[id] else { return }
        r.corrections.append(AssetCorrection(field: .license, before: r.provenance.licenseName ?? "", after: provenance.licenseName ?? "", at: now))
        r.provenance = provenance
        r.locks.insert(.license)
        r.updatedAt = now
        state.records[id] = r
    }

    /// Batch category change (one correction per record).
    static func setCategory(_ ids: [String], primary: AssetCategory, in state: inout AssetLibraryState, now: Date) {
        for id in ids { setCategory(id, primary: primary, secondary: state.records[id]?.secondaryCategories ?? [], in: &state, now: now) }
    }

    // MARK: Relationships

    static func relate(_ rel: AssetRelationship, in state: inout AssetLibraryState) {
        guard rel.from != rel.to, state.records[rel.from] != nil, state.records[rel.to] != nil else { return }
        if let i = state.relationships.firstIndex(where: { $0.from == rel.from && $0.to == rel.to && $0.kind == rel.kind }) {
            // A user or pipeline fact is never downgraded to a suggestion.
            if state.relationships[i].origin == .suggested { state.relationships[i] = rel }
            return
        }
        state.relationships.append(rel)
    }

    static func confirm(_ from: String, _ to: String, kind: AssetRelationKind, accept: Bool, in state: inout AssetLibraryState) {
        guard let i = state.relationships.firstIndex(where: { $0.from == from && $0.to == to && $0.kind == kind }) else { return }
        if accept { state.relationships[i].confirmed = true; state.relationships[i].origin = .user } else { state.relationships.remove(at: i) }
    }

    static func relationships(of id: String, in state: AssetLibraryState) -> [AssetRelationship] {
        state.relationships.filter { $0.from == id || $0.to == id }
    }

    /// Suggestions only: a picture and a model that both look like a
    /// character are *possibly* the same one. Never confirmed automatically.
    static func suggestRelationships(in state: inout AssetLibraryState) {
        let records = sorted(state)
        let pictures = records.filter { ($0.mediaType == .image || $0.mediaType == .gif) && $0.categories.contains(.character) }
        let models = records.filter { $0.mediaType == .model && $0.categories.contains(.character) }
        for p in pictures { for m in models {
            let shared = Set(p.dominantColors.prefix(3)).intersection(m.dominantColors.prefix(3))
            if !shared.isEmpty || p.title.isEmpty == false && m.title.lowercased().contains(p.title.lowercased()) {
                relate(AssetRelationship(from: p.assetID, to: m.assetID, kind: .sameCharacter, origin: .suggested, confirmed: false,
                                         note: L10n.t("看起来相似，可能是同一角色：请确认", "Looks similar, possibly the same character: please confirm")), in: &state)
            }
        } }
        for group in ArtStyleMatcher.groups(records) where group.count >= 2 {
            for other in group.dropFirst() {
                relate(AssetRelationship(from: group[0], to: other, kind: .sameStyle, origin: .suggested, confirmed: false, note: nil), in: &state)
            }
        }
    }

    /// What a set of assets is missing to be complete game resources.
    static func missingResources(in state: AssetLibraryState) -> [(assetID: String, message: String, operation: AssetOperation)] {
        var out: [(String, String, AssetOperation)] = []
        for r in sorted(state) where r.mediaType == .model && r.categories.contains(.character) {
            let t = r.signals?.technical
            if t?.hasSkeleton != true {
                out.append((r.assetID, L10n.t("「\(r.title)」还没有骨骼：建议先自动绑定骨骼", "“\(r.title)” has no skeleton: auto-rig it first"), .autoRig))
            } else if (t?.animationNames ?? []).isEmpty && !state.relationships.contains(where: { $0.from == r.assetID && $0.kind == .compatibleMotion && $0.confirmed }) {
                out.append((r.assetID, L10n.t("「\(r.title)」有骨骼但没有动作：建议补充待机、行走、攻击动作", "“\(r.title)” is rigged but has no motion: add idle, walk and attack"), .generateMotion))
            }
        }
        return out
    }

    // MARK: Deleting

    /// Where an asset is still used: worlds (media bindings / statues by
    /// library or model id) and confirmed relationships. Empty: safe to remove.
    static func references(to id: String, in state: AssetLibraryState, worldMediaIDs: Set<String>, worldModelIDs: Set<String>) -> [String] {
        guard let r = state.records[id] else { return [] }
        var out: [String] = []
        switch r.storage {
        case .library(let lib) where worldMediaIDs.contains(lib): out.append(L10n.t("当前世界的方块正在显示它", "Blocks in the current world show it"))
        case .generatedModel(let model) where worldModelIDs.contains(model): out.append(L10n.t("当前世界的角色或雕像在使用它", "A character or statue in the current world uses it"))
        default: break
        }
        for rel in state.relationships where rel.confirmed && (rel.from == id || rel.to == id) && rel.kind != .sameStyle {
            out.append(L10n.t("与其他素材有已确认的关联（\(rel.kind.rawValue)）", "Has a confirmed link to another asset (\(rel.kind.rawValue))"))
        }
        return out
    }

    /// Removes only the analysis record and its links; the media file itself
    /// is owned by its store (library / models) and is never deleted here.
    static func removeRecord(_ id: String, in state: inout AssetLibraryState) {
        state.records[id] = nil
        state.relationships.removeAll { $0.from == id || $0.to == id }
    }

    /// Drops links to records that no longer exist (index repair).
    static func repair(_ state: inout AssetLibraryState) -> Int {
        let before = state.relationships.count
        state.relationships.removeAll { state.records[$0.from] == nil || state.records[$0.to] == nil }
        for (id, r) in state.records where !r.valid { state.records[id] = nil }
        return before - state.relationships.count
    }
}
