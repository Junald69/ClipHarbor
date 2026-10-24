import Foundation

/// ユーザーが入力した動画名から、安全なファイル名を作る。
enum FileNaming {
    static let maxCharacters = 80
    static let maxUTF8Bytes = 180
    private static let knownExtensions = ["mp4", "m4v", "mov", "webm", "m3u8", "movpkg"]

    /// 不正文字・制御文字・パス区切り・先頭のドットを除去する。結果が空ならnilではなく空文字を返す。
    static func sanitizedBaseName(_ raw: String) -> String {
        var s = raw.precomposedStringWithCanonicalMapping
        // 制御文字と書式文字（双方向制御文字など）を除去
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }))
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        s = s.components(separatedBy: illegal).joined(separator: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // ユーザーが拡張子まで入力した場合は取り除く（形式と拡張子はアプリ側で一致させる）
        let lower = s.lowercased()
        for ext in knownExtensions where lower.hasSuffix("." + ext) {
            s = String(s.dropLast(ext.count + 1))
            break
        }
        while s.hasPrefix(".") || s.hasPrefix("~") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > maxCharacters { s = String(s.prefix(maxCharacters)) }
        while s.utf8.count > maxUTF8Bytes { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "." || s == ".." { return "" }
        return s
    }

    /// 同名ファイルがある場合は「名前 (2).mp4」のように番号を付けたURLを返す。
    static func uniqueDestination(in folder: URL, baseName: String, fileExtension ext: String,
                                  fileManager: FileManager = .default) -> URL {
        let base = baseName.isEmpty ? "Video" : baseName
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) && counter < 10_000 {
            candidate = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// 保存先URLがフォルダの直下にあることを確認する（パストラバーサル対策）
    static func isDirectChild(_ url: URL, of folder: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let expected = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return parent == expected && !url.lastPathComponent.hasPrefix(".")
    }
}
