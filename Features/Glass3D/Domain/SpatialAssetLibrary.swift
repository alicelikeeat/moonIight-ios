import Foundation

// v1.65 open asset libraries: the built-in CC0 starter pack and online
// sources (Poly Haven textures, Openverse images). Pure parsing and rules
// here (tested on Linux); downloads and UI live in Glass3DAssetLibrary.

/// Where a library file came from and under which licence.
struct AssetAttribution: Codable, Equatable, Sendable {
    var title: String
    var author: String
    /// Short licence label, e.g. "CC0 1.0", "CC BY 2.0".
    var license: String
    var licenseURL: String?
    /// Page of the original work.
    var source: String
    /// Library or service, e.g. "Kenney", "Poly Haven", "Openverse · flickr".
    var provider: String
    /// Ready-made credit line when the licence asks for one.
    var credit: String?

    /// CC0 and public domain need no credit; everything else does.
    var needsCredit: Bool {
        let l = license.lowercased()
        return !(l.hasPrefix("cc0") || l.hasPrefix("pdm") || l.contains("public domain"))
    }
}

/// One file of the built-in starter pack (manifest.json in the bundle).
struct StarterAsset: Codable, Equatable, Identifiable, Sendable {
    var file: String
    var kind: String
    var group: String
    var character: String?
    var action: String?
    var title: String
    var titleEn: String
    var author: String
    var license: String
    var source: String
    var id: String { file }

    var attribution: AssetAttribution {
        AssetAttribution(title: titleEn, author: author, license: license, licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
                         source: source, provider: group == "textures" ? "Poly Haven" : "Kenney", credit: nil)
    }
}

struct StarterManifest: Codable, Sendable {
    var version: Int
    var items: [StarterAsset]

    static func decode(_ data: Data) -> StarterManifest? { try? JSONDecoder().decode(StarterManifest.self, from: data) }

    struct Character: Identifiable, Sendable { let id: String; let poses: [String: StarterAsset] }
    /// Starter characters in manifest order, each with its poses by action.
    var characters: [Character] {
        var order: [String] = []
        var poses: [String: [String: StarterAsset]] = [:]
        for item in items where item.group == "characters" {
            guard let character = item.character, let action = item.action else { continue }
            if poses[character] == nil { order.append(character) }
            poses[character, default: [:]][action] = item
        }
        return order.map { Character(id: $0, poses: poses[$0] ?? [:]) }
    }
}

/// Which starter pose plays for each character action.
enum StarterCharacterRecipe {
    /// action → (pose, speed, loop)
    static let mapping: [(CharacterAction, String, Double, Bool)] = [
        (.idle, "idle", 1, true), (.walk, "walk", 1, true), (.run, "walk", 1.6, true),
        (.jump, "jump", 1, false), (.fall, "fall", 1, true), (.attack, "attack", 1.4, false),
        (.skill, "cheer", 1.2, false), (.dodge, "jump", 1, false), (.hurt, "hurt", 1, false),
        (.death, "hurt", 1, false), (.interact, "cheer", 1, true), (.transform, "cheer", 1.5, false),
    ]

    /// Clips from the bindings made for each pose (pose name → binding id).
    static func clips(bindings: [String: String]) -> [String: ActionClip] {
        var clips: [String: ActionClip] = [:]
        for (action, pose, speed, loop) in mapping {
            guard let binding = bindings[pose] else { continue }
            clips[action.rawValue] = ActionClip(bindingIDs: [binding], speed: speed, loop: loop)
        }
        return clips
    }

    /// A ready character: billboard, picture proportions of the pack (80×110).
    static func template(id: String, name: String, bindings: [String: String]) -> CharacterTemplate {
        CharacterTemplate(id: id, name: name, mode: .billboard, clips: clips(bindings: bindings), height: 1.6, aspect: 80.0 / 110.0)
    }
}

/// A result from an online library, ready to preview and import.
struct OnlineAsset: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var thumbnail: URL
    /// Direct file, or nil when it has to be looked up first (Poly Haven).
    var download: URL?
    var fileExtension: String
    var attribution: AssetAttribution
    var tags: [String] = []
}

enum OnlineAssetParsing {
    static let polyHavenCDN = "https://cdn.polyhaven.com/asset_img/thumbs/"

    /// `GET api.polyhaven.com/assets?t=textures` → assets, most downloaded first.
    static func polyHaven(_ data: Data) -> [OnlineAsset] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let rows: [(Int, OnlineAsset)] = root.compactMap { id, value in
            guard let info = value as? [String: Any], let name = info["name"] as? String,
                  let thumb = URL(string: polyHavenCDN + id + ".png?width=256&height=256") else { return nil }
            let authors = (info["authors"] as? [String: Any]).map { Array($0.keys).sorted().joined(separator: ", ") } ?? ""
            let tags = ((info["categories"] as? [String]) ?? []) + ((info["tags"] as? [String]) ?? [])
            let attribution = AssetAttribution(title: name, author: authors.isEmpty ? "Poly Haven" : authors, license: "CC0 1.0",
                                               licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
                                               source: "https://polyhaven.com/a/" + id, provider: "Poly Haven", credit: nil)
            return ((info["download_count"] as? Int) ?? 0, OnlineAsset(id: id, title: name, thumbnail: thumb, download: nil, fileExtension: "jpg", attribution: attribution, tags: tags))
        }
        return rows.sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 > $1.0 }.map(\.1)
    }

    /// `GET api.polyhaven.com/files/{id}` → the colour map at the wanted size.
    static func polyHavenDiffuse(_ data: Data, size: String = "1k") -> URL? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["Diffuse", "diffuse", "Color", "albedo"] {
            guard let map = root[key] as? [String: Any] else { continue }
            let sized = (map[size] as? [String: Any]) ?? (map["1k"] as? [String: Any]) ?? (map["2k"] as? [String: Any])
            for format in ["jpg", "png"] {
                if let file = sized?[format] as? [String: Any], let url = (file["url"] as? String).flatMap(URL.init(string:)) { return url }
            }
        }
        return nil
    }

    /// `GET api.openverse.org/v1/images/?q=…` → results. The original is used
    /// when it is an https picture, otherwise Openverse's own resized copy.
    static func openverse(_ data: Data) -> [OnlineAsset] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { row in
            guard let id = row["id"] as? String, let thumb = (row["thumbnail"] as? String).flatMap(URL.init(string:)) else { return nil }
            let original = (row["url"] as? String).flatMap(URL.init(string:))
            let ext = (original?.pathExtension.lowercased()).flatMap { ["jpg", "jpeg", "png", "gif", "webp"].contains($0) ? $0 : nil }
            let usable = original.flatMap { $0.scheme == "https" && ext != nil && ext != "webp" ? $0 : nil }
            let code = (row["license"] as? String) ?? ""
            let version = (row["license_version"] as? String) ?? ""
            let provider = (row["provider"] as? String).map { "Openverse · " + $0 } ?? "Openverse"
            let title = ((row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let attribution = AssetAttribution(title: title, author: (row["creator"] as? String) ?? "", license: licenseLabel(code, version),
                                               licenseURL: row["license_url"] as? String,
                                               source: (row["foreign_landing_url"] as? String) ?? "https://openverse.org/image/" + id,
                                               provider: provider, credit: row["attribution"] as? String)
            return OnlineAsset(id: id, title: title, thumbnail: thumb, download: usable ?? thumb,
                               fileExtension: usable == nil ? "jpg" : (ext == "jpeg" ? "jpg" : ext ?? "jpg"), attribution: attribution,
                               tags: ((row["tags"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        }
    }

    /// "by-sa" + "2.0" → "CC BY-SA 2.0"; cc0 → "CC0 1.0"; pdm → "Public Domain".
    static func licenseLabel(_ code: String, _ version: String) -> String {
        switch code.lowercased() {
        case "cc0": return "CC0 1.0"
        case "pdm": return "Public Domain"
        case "": return "Unknown"
        default: return "CC " + code.uppercased() + (version.isEmpty ? "" : " " + version)
        }
    }

    /// Openverse search address. `cc0Only` keeps to no-credit works; the
    /// default allows commercial use and adaptation (BY, BY-SA, CC0, public
    /// domain). No-derivatives (ND) and non-commercial (NC) works are left
    /// out: putting a picture on a block, cropping or splitting it adapts it.
    static func openverseURL(query: String, page: Int, cc0Only: Bool) -> URL? {
        var parts = URLComponents(string: "https://api.openverse.org/v1/images/")
        var items = [URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                     URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: "page_size", value: "30"),
                     URLQueryItem(name: "mature", value: "false")]
        items.append(URLQueryItem(name: "license", value: cc0Only ? "cc0,pdm" : "by,by-sa,cc0,pdm"))
        parts?.queryItems = items
        return parts?.url
    }

    /// Local filter for the Poly Haven list (name, categories, tags).
    static func filter(_ assets: [OnlineAsset], query: String) -> [OnlineAsset] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return assets }
        return assets.filter { asset in
            let text = ([asset.title, asset.id] + asset.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}
