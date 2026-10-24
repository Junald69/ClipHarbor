import SwiftUI

/// Aloha Browser風の2列カード型タブ一覧画面（Step 2-C）
/// - LazyVGridによる2列カード配置
/// - 各タブのページプレビュー（WKWebView.takeSnapshotによるメモリ内サムネイル）
/// - ページタイトルとドメイン表示
/// - カードタップでタブ切り替え、右下「✕」ボタン（44x44pt以上）でタブ削除
/// - 選択中タブの青枠強調表示
/// - 新規タブ作成（ナビゲーションバーの「＋」および下部の「新しいタブを開く」ボタン）
/// - 最大20タブ制限の維持
/// - ダークモード・ライトモード・Safe Area対応
struct TabSwitcherView: View {
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(tabManager.tabs) { tab in
                            TabCardView(
                                tab: tab,
                                isActive: (tab.id == tabManager.activeTabID),
                                onSelect: {
                                    tabManager.selectTab(id: tab.id)
                                    dismiss()
                                },
                                onClose: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        tabManager.closeTab(id: tab.id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // 下部の「新しいタブを開く」ボタン（モックデザイン対応）
                    Button {
                        handleCreateNewTab()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 18, weight: .semibold))
                            Text("新しいタブを開く")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(tabManager.canCreateNewTab ? Color.blue : Color.secondary)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                    }
                    .disabled(!tabManager.canCreateNewTab)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("タブ (\(tabManager.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完了") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        handleCreateNewTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!tabManager.canCreateNewTab)
                    .accessibilityLabel("新しいタブを開く")
                }
            }
            .onAppear {
                tabManager.activeTab.captureSnapshot()
            }
        }
        .presentationDetents([.large])
    }

    private func handleCreateNewTab() {
        guard tabManager.canCreateNewTab else { return }
        _ = tabManager.createNewTab()
        dismiss()
    }
}

// MARK: - 個別タブカード（スナップショット更新監視と安全なタップ分離）

private struct TabCardView: View {
    @ObservedObject var tab: BrowserModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 上部：サムネイル / プレビュー領域（タップで選択）
            previewArea
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color(.tertiarySystemFill))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }

            Divider()

            // 下部：タイトル・ドメインと閉じる「✕」ボタン
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.pageTitle.isEmpty ? "名称未設定" : tab.pageTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let host = hostString(for: tab.address) {
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }

                Spacer(minLength: 4)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("タブを閉じる")
            }
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isActive ? Color.blue : Color(.separator).opacity(0.4), lineWidth: isActive ? 2.5 : 1)
        )
        .shadow(color: Color.black.opacity(isActive ? 0.12 : 0.05), radius: 6, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.pageTitle.isEmpty ? "名称未設定" : tab.pageTitle)\(isActive ? ", 選択中" : "")")
    }

    // MARK: - プレビュー表示（スナップショット または プレースホルダー）

    @ViewBuilder
    private var previewArea: some View {
        if let snapshot = tab.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: placeholderIcon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)

            Text("ページプレビュー")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderIcon: String {
        if tab.hasAnyMedia {
            return "play.circle.fill"
        }
        let lower = tab.address.lowercased()
        if lower.contains("google") || lower.contains("search") || lower.contains("yahoo") || lower.contains("bing") {
            return "magnifyingglass"
        }
        return "globe"
    }

    private func hostString(for raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
