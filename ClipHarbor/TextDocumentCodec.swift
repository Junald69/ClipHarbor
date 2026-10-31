//
//  TextDocumentCodec.swift
//  ClipHarbor
//
//  Created for Phase F2-C: TXT/MD Text Editor.
//  Handles UTF-8 BOM, line endings (LF/CRLF), trailing newlines,
//  and detects binary/unsupported encodings for read-only safety.
//

import Foundation

/// テキスト文書のメタデータ（BOM、改行形式、末尾改行、保護フラグ）
struct TextDocumentMetadata: Equatable {
    enum LineEnding: String, Equatable {
        case lf = "LF"
        case crlf = "CRLF"
        case mixed = "Mixed"
    }

    var hasBOM: Bool
    var lineEnding: LineEnding
    var hasTrailingNewline: Bool
    var isReadOnly: Bool
    var readOnlyReason: String?
    var fileModificationDate: Date?
    var fileByteSize: Int64?
}

/// テキスト読み込み結果
struct TextDocumentLoadResult {
    let text: String
    let metadata: TextDocumentMetadata
}

/// テキストコーデック（BOM・改行コード・文字エンコーディングの厳格管理）
enum TextDocumentCodec {
    /// UTF-8 BOM（Byte Order Mark: 0xEF, 0xBB, 0xBF）
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    /// バイナリファイル判定
    /// 先頭最大4096バイトをスキャンし、NULLバイト（0x00）が存在すればバイナリと判定
    static func isBinaryData(_ data: Data) -> Bool {
        let sampleLength = min(data.count, 4096)
        let sample = data.prefix(sampleLength)
        return sample.contains(0x00)
    }

    /// ファイルDataからテキストおよびメタデータを安全にデコード
    static func decode(
        data: Data,
        fileModificationDate: Date? = nil,
        fileByteSize: Int64? = nil
    ) -> TextDocumentLoadResult {
        // 1. バイナリ検知（NULLバイト検出）
        if isBinaryData(data) {
            let fallbackText = String(decoding: data.prefix(2048), as: UTF8.self)
            return TextDocumentLoadResult(
                text: fallbackText,
                metadata: TextDocumentMetadata(
                    hasBOM: false,
                    lineEnding: .lf,
                    hasTrailingNewline: false,
                    isReadOnly: true,
                    readOnlyReason: NSLocalizedString("Binary file detected. Editing is disabled to prevent corruption.", comment: ""),
                    fileModificationDate: fileModificationDate,
                    fileByteSize: fileByteSize
                )
            )
        }

        // 2. BOM 検知
        var rawData = data
        var hasBOM = false
        if rawData.starts(with: utf8BOM) {
            hasBOM = true
            rawData = rawData.dropFirst(utf8BOM.count)
        }

        // 3. UTF-8 厳格デコード
        guard let decodedString = String(data: rawData, encoding: .utf8) else {
            // UTF-8で正常にデコードできない（Shift_JIS、EUC-JP等）
            // 不可逆なファイル破損を防ぐため、強制的に読み取り専用モードとする
            let lossyString = String(decoding: data, as: UTF8.self)
            return TextDocumentLoadResult(
                text: lossyString,
                metadata: TextDocumentMetadata(
                    hasBOM: hasBOM,
                    lineEnding: .lf,
                    hasTrailingNewline: false,
                    isReadOnly: true,
                    readOnlyReason: NSLocalizedString("Unsupported text encoding (not valid UTF-8). Opened in read-only mode to prevent data corruption.", comment: ""),
                    fileModificationDate: fileModificationDate,
                    fileByteSize: fileByteSize
                )
            )
        }

        // 4. 改行コード検知
        let lineEnding: TextDocumentMetadata.LineEnding
        let hasCRLF = decodedString.contains("\r\n")
        let withoutCRLF = decodedString.replacingOccurrences(of: "\r\n", with: "")
        let hasStandaloneLF = withoutCRLF.contains("\n")

        if hasCRLF && !hasStandaloneLF {
            lineEnding = .crlf
        } else if hasStandaloneLF && !hasCRLF {
            lineEnding = .lf
        } else if hasCRLF && hasStandaloneLF {
            lineEnding = .mixed
        } else {
            lineEnding = .lf
        }

        // 5. 末尾改行の検知
        let hasTrailingNewline = decodedString.hasSuffix("\n") || decodedString.hasSuffix("\r\n")

        // 編集用に内部テキストの改行を LF に統一
        let normalizedText = decodedString
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return TextDocumentLoadResult(
            text: normalizedText,
            metadata: TextDocumentMetadata(
                hasBOM: hasBOM,
                lineEnding: lineEnding,
                hasTrailingNewline: hasTrailingNewline,
                isReadOnly: false,
                readOnlyReason: nil,
                fileModificationDate: fileModificationDate,
                fileByteSize: fileByteSize
            )
        )
    }

    /// 編集テキストから保存用 Data を再構成（BOM・改行コード・末尾改行を元の仕様通りに再現）
    static func encode(text: String, metadata: TextDocumentMetadata) -> Data {
        var processedText = text

        // 1. 末尾改行の再現
        if metadata.hasTrailingNewline {
            if !processedText.isEmpty && !processedText.hasSuffix("\n") {
                processedText.append("\n")
            }
        } else {
            while processedText.hasSuffix("\n") {
                processedText.removeLast()
            }
        }

        // 2. 改行コードの再現
        if metadata.lineEnding == .crlf {
            processedText = processedText.replacingOccurrences(of: "\n", with: "\r\n")
        }

        // 3. UTF-8 バイト列構築
        var data = Data()
        if metadata.hasBOM {
            data.append(utf8BOM)
        }
        if let utf8Data = processedText.data(using: .utf8) {
            data.append(utf8Data)
        }
        return data
    }
}
