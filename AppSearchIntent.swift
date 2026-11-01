import Foundation

struct MediaSearchIntent: Equatable {
    let query: String
    let kind: String?
    static func parse(_ input: String) -> Self? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, kind) in [("搜索视频", "video"), ("搜视频", "video"), ("搜索图片", "image"), ("搜图片", "image"), ("搜索 ", ""), ("搜索：", ""), ("搜索:", ""), ("search ", "")] {
            if text.lowercased().hasPrefix(prefix) {
                return Self(query: String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines), kind: kind.isEmpty ? nil : kind)
            }
        }
        if ["搜索", "搜索媒体"].contains(text) { return Self(query: "", kind: nil) }
        return nil
    }
}
