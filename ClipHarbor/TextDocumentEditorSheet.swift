//
//  TextDocumentEditorSheet.swift
//  ClipHarbor
//
//  Created for Phase F2-C: TXT/MD Text Editor.
//  Dedicated text editor with UTF-8 BOM, LF/CRLF preservation,
//  atomic saving, external modification checks, and read-only protection.
//

import SwiftUI

struct TextDocumentEditorSheet: View {
    let item: ManagedFileItem
    @ObservedObject var zipManager: ZipArchiveManager

    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var metadata: TextDocumentMetadata?
    @State private var isLoading: Bool = true
    @State private var loadErrorMessage: String?

    @State private var isSaving: Bool = false
    @State private var saveErrorMessage: String?
    @State private var showSaveErrorAlert: Bool = false
    @State private var showDiscardConfirmDialog: Bool = false
    @State private var isPreviewMode: Bool = false

    var isModified: Bool {
        content != originalContent
    }

    var characterCount: Int {
        content.count
    }

    var lineCount: Int {
        content.isEmpty ? 0 : content.components(separatedBy: "\n").count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if let error = loadErrorMessage {
                    errorView(error)
                } else {
                    editorContentView
                }
            }
            .navigationTitle(item.title + "." + item.fileExtension)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .interactiveDismissDisabled(isModified)
            .confirmationDialog(
                NSLocalizedString("Unsaved Changes", comment: ""),
                isPresented: $showDiscardConfirmDialog,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    dismiss()
                } label: {
                    Text("Discard Changes")
                }

                Button {
                    saveDocument(andDismiss: true)
                } label: {
                    Text("Save & Close")
                }

                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("You have unsaved changes. Do you want to discard them or save before closing?")
            }
            .alert(
                NSLocalizedString("Save Failed", comment: ""),
                isPresented: $showSaveErrorAlert
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveErrorMessage ?? NSLocalizedString("An unknown error occurred while saving.", comment: ""))
            }
            .onAppear {
                loadFileContent()
            }
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                if isModified {
                    showDiscardConfirmDialog = true
                } else {
                    dismiss()
                }
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            if let meta = metadata, meta.isReadOnly {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text("Read Only")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: Capsule())
            } else {
                Button {
                    saveDocument(andDismiss: false)
                } label: {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(!isModified || isSaving || metadata?.isReadOnly == true)
            }
        }
    }

    // MARK: - メインエディター

    private var editorContentView: some View {
        VStack(spacing: 0) {
            // 読み取り専用バナー
            if let meta = metadata, meta.isReadOnly, let reason = meta.readOnlyReason {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.15))
            }

            // メタデータ・ステータスバー
            statusBar

            Divider()

            // Markdown 切り替えコントロール
            if item.isMarkdown {
                Picker("Mode", selection: $isPreviewMode) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            // テキスト入力 / プレビュー
            if item.isMarkdown && isPreviewMode {
                ScrollView {
                    Text(LocalizedStringKey(content))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .disabled(metadata?.isReadOnly == true)
            }
        }
    }

    // MARK: - ステータスバー

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(String(format: NSLocalizedString("Chars: %lld", comment: ""), characterCount))
            Text(String(format: NSLocalizedString("Lines: %lld", comment: ""), lineCount))

            Spacer()

            if let meta = metadata {
                Text(meta.hasBOM ? "UTF-8 (BOM)" : "UTF-8")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 4))

                Text(meta.lineEnding.rawValue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground))
    }

    // MARK: - ローディング & エラー

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading document...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(error)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 読み込み・保存ロジック

    private func loadFileContent() {
        let fileURL = zipManager.resolveFileURL(for: item)
        let fm = FileManager.default

        guard fm.fileExists(atPath: fileURL.path) else {
            loadErrorMessage = NSLocalizedString("File not found on device.", comment: "")
            isLoading = false
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let modDate = attrs?[.modificationDate] as? Date
            let size = attrs?[.size] as? Int64

            let result = TextDocumentCodec.decode(
                data: data,
                fileModificationDate: modDate,
                fileByteSize: size
            )

            self.content = result.text
            self.originalContent = result.text
            self.metadata = result.metadata
            self.isLoading = false
        } catch {
            self.loadErrorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    private func saveDocument(andDismiss: Bool) {
        guard let currentMeta = metadata else { return }
        guard !currentMeta.isReadOnly else { return }

        isSaving = true

        do {
            let updatedItem = try zipManager.saveTextDocument(
                item,
                content: content,
                metadata: currentMeta
            )

            // 最新の属性を取得してメタデータをリフレッシュ
            let fileURL = zipManager.resolveFileURL(for: updatedItem)
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let newModDate = attrs?[.modificationDate] as? Date
            let newSize = attrs?[.size] as? Int64

            var refreshedMeta = currentMeta
            refreshedMeta.fileModificationDate = newModDate
            refreshedMeta.fileByteSize = newSize

            self.metadata = refreshedMeta
            self.originalContent = content
            self.isSaving = false

            if andDismiss {
                dismiss()
            }
        } catch {
            self.isSaving = false
            self.saveErrorMessage = error.localizedDescription
            self.showSaveErrorAlert = true
        }
    }
}
