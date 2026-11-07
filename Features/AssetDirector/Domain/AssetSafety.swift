import Foundation

// v1.87 AI Asset Director — what may come in, what may go out, and what an
// AI answer may say. Pure checks; the app calls them before reading,
// uploading or applying anything.

enum AssetImportRejection: Error, Equatable, Sendable {
    case empty
    case tooLarge(Int)
    case unsupported(String)
    /// The content does not look like the file type it claims.
    case mismatch(String)
    /// A model points at files outside the import or at the network.
    case externalReference(String)
    case damaged(String)

    var message: String {
        switch self {
        case .empty: L10n.t("文件是空的", "The file is empty")
        case .tooLarge(let limit): L10n.t("文件过大（上限 \(limit >> 20) MB）", "The file is too large (limit \(limit >> 20) MB)")
        case .unsupported(let ext): L10n.t("不支持的格式：\(ext)", "Unsupported format: \(ext)")
        case .mismatch(let what): L10n.t("文件内容与扩展名不符：\(what)", "The content does not match its extension: \(what)")
        case .externalReference(let ref): L10n.t("模型引用了外部资源，已拒绝：\(ref)", "The model refers to an outside resource and was refused: \(ref)")
        case .damaged(let why): L10n.t("文件已损坏：\(why)", "The file is damaged: \(why)")
        }
    }
}

enum AssetFileSafety {
    static let imageTypes = ["png", "jpg", "jpeg", "heic", "heif", "webp", "bmp", "tif", "tiff"]
    static let videoTypes = ["mov", "mp4", "m4v"]
    static let audioTypes = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "flac"]
    static let modelTypes = ModelImport.extensions + ["usdz", "usd", "usda", "usdc"]

    /// Size limits per kind (bytes).
    static func limit(_ type: AssetMediaType) -> Int {
        switch type {
        case .image: 60 << 20
        case .gif: 40 << 20
        case .video: 2048 << 20
        case .audio: 300 << 20
        case .model: 200 << 20
        }
    }

    static func mediaType(forExtension raw: String) -> AssetMediaType? {
        let ext = raw.lowercased()
        if ext == "gif" { return .gif }
        if imageTypes.contains(ext) { return .image }
        if videoTypes.contains(ext) { return .video }
        if audioTypes.contains(ext) { return .audio }
        if modelTypes.contains(ext) { return .model }
        return nil
    }

    /// Checks name, size and the first bytes. `head` is the start of the file (≥ 64 bytes when available).
    static func check(fileName: String, size: Int, head: [UInt8]) -> Result<AssetMediaType, AssetImportRejection> {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let type = mediaType(forExtension: ext) else { return .failure(.unsupported(ext.isEmpty ? "?" : ext)) }
        guard size > 0, !head.isEmpty else { return .failure(.empty) }
        guard size <= limit(type) else { return .failure(.tooLarge(limit(type))) }
        if let sniffed = sniff(head), !compatible(ext: ext, sniffed: sniffed) { return .failure(.mismatch("\(ext) ≠ \(sniffed)")) }
        return .success(type)
    }

    /// Container type from magic bytes, when recognisable.
    static func sniff(_ b: [UInt8]) -> String? {
        func starts(_ p: [UInt8], at o: Int = 0) -> Bool { b.count >= o + p.count && Array(b[o..<(o + p.count)]) == p }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts(Array("glTF".utf8)) { return "glb" }
        if starts(Array("RIFF".utf8)) && starts(Array("WAVE".utf8), at: 8) { return "wav" }
        if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return "webp" }
        if starts(Array("ID3".utf8)) || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) { return "mp3" }
        if starts(Array("fLaC".utf8)) { return "flac" }
        if starts(Array("FORM".utf8)) { return "aiff" }
        if starts(Array("caff".utf8)) { return "caf" }
        if starts(Array("ftyp".utf8), at: 4) {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            return ["heic", "heix", "mif1", "msf1", "heim", "heis", "hevc"].contains(brand) ? "heic" : "mp4"
        }
        if starts(Array("Kaydara FBX Binary".utf8)) { return "fbx" }
        if starts(Array("PXR-USDC".utf8)) { return "usdc" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "zip" }   // usdz, 3mf
        return nil
    }

    static func compatible(ext: String, sniffed: String) -> Bool {
        switch sniffed {
        case "png": ["png"].contains(ext)
        case "jpg": ["jpg", "jpeg"].contains(ext)
        case "gif": ext == "gif"
        case "glb": ext == "glb"
        case "mp4": ["mp4", "m4v", "mov", "m4a", "aac"].contains(ext)
        case "heic": ["heic", "heif"].contains(ext)
        case "zip": ["usdz", "3mf"].contains(ext)
        case "usdc": ["usd", "usdc"].contains(ext)
        case "wav": ext == "wav"
        case "webp": ext == "webp"
        case "mp3": ext == "mp3"
        case "flac": ext == "flac"
        case "aiff": ["aif", "aiff"].contains(ext)
        case "caf": ext == "caf"
        case "fbx": ext == "fbx"
        default: true
        }
    }

    /// External references a model file may not use: network URLs, absolute
    /// paths and parent-directory escapes. Embedded data and plain sibling
    /// file names (picked together with the model) are fine.
    static func unsafeReference(_ ref: String) -> Bool {
        let r = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if r.isEmpty || r.hasPrefix("data:") { return false }
        if r.contains("://") || r.hasPrefix("//") { return true }
        if r.hasPrefix("/") || r.hasPrefix("~") || r.range(of: #"^[a-z]:[\\/]"#, options: .regularExpression) != nil { return true }
        return r.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains("..")
    }

    /// References inside a text model (glTF JSON `uri`, OBJ `mtllib` / map
    /// lines, USDA `@asset@` paths) that `unsafeReference` refuses.
    static func externalReferences(modelExtension ext: String, data: Data) -> [String] {
        let text: String
        switch ext.lowercased() {
        case "gltf", "obj", "mtl", "usda": text = String(decoding: data.prefix(8 << 20), as: UTF8.self)
        case "glb":
            // JSON chunk follows the 12-byte header: length (4) + type "JSON" (4).
            let b = [UInt8](data.prefix(20))
            guard b.count >= 20 else { return [] }
            let length = Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24
            guard length > 0, data.count >= 20 + length else { return [] }
            text = String(decoding: data[20..<(20 + length)], as: UTF8.self)
        default: return []
        }
        var refs: [String] = []
        if ext == "gltf" || ext == "glb" {
            if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                for key in ["buffers", "images"] {
                    for item in json[key] as? [[String: Any]] ?? [] { if let uri = item["uri"] as? String { refs.append(uri) } }
                }
            }
        } else if ext == "usda" {
            var rest = Substring(text)
            while let a = rest.firstIndex(of: "@") {
                let after = rest[rest.index(after: a)...]
                guard let b = after.firstIndex(of: "@") else { break }
                refs.append(String(after[..<b])); rest = after[after.index(after: b)...]
            }
        } else {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if ["mtllib", "map_kd", "map_ka", "map_ks", "map_bump", "bump", "map_d", "norm"].contains(parts[0].lowercased()) { refs.append(String(parts[1])) }
            }
        }
        return refs.filter(unsafeReference)
    }
}

// MARK: Cloud

enum AssetCloudDecision: Equatable, Sendable {
    case allowed
    case denied(String)
}

/// Cloud vision runs only with its own consent and within budget, and
/// sends a small re-encoded thumbnail — never the original file, a whole
/// video, location or other metadata.
enum AssetCloudPolicy {
    static let maxImageSide = 512
    static let maxUploadBytes = 400 * 1024

    static func day(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func may(upload images: Int, settings s: AssetDirectorSettings, keyPresent: Bool, now: Date) -> AssetCloudDecision {
        guard s.cloudVision else { return .denied(L10n.t("云端分析未开启", "Cloud analysis is off")) }
        guard keyPresent else { return .denied(L10n.t("没有 API 密钥", "No API key")) }
        guard images <= s.cloudPerTask else { return .denied(L10n.t("超过单次上限", "Over the per-task limit")) }
        let used = s.cloudDay == day(now) ? s.cloudUsedToday : 0
        guard used + images <= s.cloudDailyLimit else { return .denied(L10n.t("今天的云端额度已用完", "Today's cloud budget is used up")) }
        return .allowed
    }

    static func record(_ images: Int, in s: inout AssetDirectorSettings, now: Date) {
        let today = day(now)
        if s.cloudDay != today { s.cloudDay = today; s.cloudUsedToday = 0 }
        s.cloudUsedToday += images
    }
}

/// Untrusted AI output → whitelisted labels. Unknown fields are ignored,
/// strings are bounded, and nothing in it is ever used as a path, URL or command.
enum AssetAIOutputValidator {
    static let maxLabels = 12

    struct Answer: Equatable, Sendable {
        var category: AssetCategory?
        var labels: [AssetTag]
        var styles: [String]
    }

    static let allowedStyles: Set<String> = ["pixel", "cartoon", "anime", "realistic", "ink", "painterly", "lowpoly", "voxel", "fantasy", "scifi"]

    static func parse(_ data: Data) -> Answer? {
        guard data.count <= 64 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let category = (object["category"] as? String).flatMap { AssetCategory(rawValue: $0.lowercased()) }
        var labels: [AssetTag] = []
        for item in (object["labels"] as? [Any] ?? []).prefix(maxLabels) {
            guard let entry = item as? [String: Any], let name = entry["name"] as? String else { continue }
            let clean = String(name.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " || $0 == "_" }.prefix(32).map(Character.init))
                .trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let score = (entry["score"] as? NSNumber)?.doubleValue ?? 0.5
            labels.append(AssetTag(name: clean, score: score.isFinite ? max(0, min(1, score)) : 0.5, source: .cloud))
        }
        let styles = (object["styles"] as? [Any] ?? []).compactMap { ($0 as? String)?.lowercased() }.filter(allowedStyles.contains)
        guard category != nil || !labels.isEmpty else { return nil }
        return Answer(category: category, labels: labels, styles: Array(Set(styles)).sorted())
    }
}
