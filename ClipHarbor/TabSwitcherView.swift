import SwiftUI

/// Aloha Browser風のタブ一覧画面（通常タブ ⇔ 🕶️プライベートタブ切り替え対応）
/// - 下部セグメントによる通常タブ／プライベートタブのワンタップ切り替え
/// - 通常タブとプライベートタブのカードを混在させない完全分離表示
/// - 通常タブ：既存の2列カードデザイン
/// - プライベートタブ：ダークチャコール／インディゴ系の専用テーマ
/// - プライベートタブ0件時の専用空状態（Aloha風説明と新規タブボタン）
/// - 各モードの個別タブ削除・全削除（Close All）対応
/// - 上限20件制限の厳格な遵守
/// - スナップショットはメモリ内のみ保持（永続化ファイル非保存）
struct TabSwitcherView: View {
    enum TabSwitchMode: Hashable {
        case regular
        case privateMode
    }

    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: TabSwitchMode
    @State private var showCloseAllAlert = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        _selectedMode = State(initialValue: tabManager.isPrivateMode ? .privateMode : .regular)
    }

    private var isViewingPrivate: Bool {
        selectedMode == .privateMode
    }

    private var currentTabs: [BrowserModel] {
        isViewingPrivate ? tabManager.privateTabs : tabManager.tabs
    }

    private var canCreateTabForCurrentMode: Bool {
        isViewingPrivate ? tabManager.canCreateNewPrivateTab : tabManager.canCreateNewTab
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    if isViewingPrivate && tabManager.privateTabs.isEmpty {
                        privateEmptyStateView
                            .padding(.top, 40)
                    } else {
                        VStack(spacing: 16) {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(currentTabs) { tab in
                                    TabCardView(
                                        tab: tab,
                                        isActive: isViewingPrivate
                                            ? (tab.id == tabManager.activePrivateTabID)
                                            : (tab.id == tabManager.activeTabID),
                                        isPrivate: isViewingPrivate,
                                        onSelect: {
                                            if isViewingPrivate {
                                                tabManager.selectPrivateTab(id: tab.id)
                                            } else {
                                                tabManager.selectTab(id: tab.id)
                                            }
                                            dismiss()
                                        },
                                        onClose: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if isViewingPrivate {
                                                    tabManager.closePrivateTab(id: tab.id)
                                                } else {
                                                    tabManager.closeTab(id: tab.id)
                                                }
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                            // 下部の新規タブ作成ボタン
                            Button {
                                handleCreateNewTab()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 18, weight: .semibold))
                                    Text(isViewingPrivate ? "Open New Private Tab" : "Open New Tab")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(
                                    canCreateTabForCurrentMode
                                        ? (isViewingPrivate ? Color.indigo : Color.blue)
                                        : Color.secondary
                                )
                                .padding(.vertical, 10)
                                .padding(.horizontal, 20)
                                .contentShape(Rectangle())
                            }
                            .disabled(!canCreateTabForCurrentMode)
                            .padding(.top, 6)
                            .padding(.bottom, 24)
                        }
                    }
                }

                // Aloha風 下部モード切り替えバー
                modeSwitcherFooter
            }
            .background(isViewingPrivate ? Color(red: 0.08, green: 0.09, blue: 0.12) : Color(.systemGroupedBackground))
            .navigationTitle(isViewingPrivate ? String(format: NSLocalizedString("Private (%lld)", comment: ""), tabManager.privateCount) : String(format: NSLocalizedString("Tabs (%lld)", comment: ""), tabManager.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        handleDone()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        if isViewingPrivate && !tabManager.privateTabs.isEmpty {
                            Button("Close All") {
                                showCloseAllAlert = true
                            }
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        }

                        Button {
                            handleCreateNewTab()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(!canCreateTabForCurrentMode)
                        .accessibilityLabel(isViewingPrivate ? "Open New Private Tab" : "Open New Tab")
                    }
                }
            }
            .confirmationDialog(
                "Close all open private tabs?",
                isPresented: $showCloseAllAlert,
                titleVisibility: .visible
            ) {
                Button("Close All Tabs", role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        tabManager.closeAllPrivateTabs()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Open private tabs and session data will be permanently cleared.")
            }
            .onAppear {
                tabManager.activeTab.captureSnapshot()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - アクション処理

    private func handleDone() {
        if isViewingPrivate {
            if !tabManager.privateTabs.isEmpty {
                _ = tabManager.switchBrowsingMode(toPrivate: true)
            } else {
                _ = tabManager.switchBrowsingMode(toPrivate: false)
            }
        } else {
            _ = tabManager.switchBrowsingMode(toPrivate: false)
        }
        dismiss()
    }

    private func handleCreateNewTab() {
        guard canCreateTabForCurrentMode else { return }
        if isViewingPrivate {
            _ = tabManager.createPrivateTab()
        } else {
            _ = tabManager.createNewTab()
        }
        dismiss()
    }

    // MARK: - Aloha風 下部モード切り替えバー

    private var modeSwitcherFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .background(isViewingPrivate ? Color.white.opacity(0.12) : Color(.separator))

            HStack(spacing: 8) {
                // 通常タブ切り替え
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMode = .regular
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 14, weight: .semibold))
                        Text(String(format: NSLocalizedString("Tabs (%lld)", comment: ""), tabManager.count))
                            .font(.subheadline.weight(!isViewingPrivate ? .semibold : .regular))
                    }
                    .foregroundStyle(!isViewingPrivate ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        !isViewingPrivate ? Color(.secondarySystemGroupedBackground) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .shadow(color: !isViewingPrivate ? Color.black.opacity(0.08) : Color.clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)

                // 🕶️ プライベート切り替え
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMode = .privateMode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 14, weight: .semibold))
                        Text(String(format: NSLocalizedString("Private (%lld)", comment: ""), tabManager.privateCount))
                            .font(.subheadline.weight(isViewingPrivate ? .semibold : .regular))
                    }
                    .foregroundStyle(isViewingPrivate ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        isViewingPrivate ? Color.indigo : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .shadow(color: isViewingPrivate ? Color.indigo.opacity(0.3) : Color.clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
            .padding(4)
            .background(
                isViewingPrivate ? Color(red: 0.14, green: 0.15, blue: 0.20) : Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(isViewingPrivate ? Color(red: 0.10, green: 0.11, blue: 0.15) : Color(.systemBackground))
    }

    // MARK: - プライベートタブ空状態ビュー

    private var privateEmptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Color.indigo)
                .padding(.bottom, 4)

            Text("Private Browsing")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            Text("Web pages opened in Private Tabs will not leave browsing history. When all tabs are closed, web data such as cookies and cache are automatically erased.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 36)

            Button {
                handleCreateNewTab()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Open New Private Tab")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.indigo, in: Capsule())
                .shadow(color: Color.indigo.opacity(0.4), radius: 6, y: 3)
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - 個別タブカード（スナップショット更新監視と安全なタップ分離）

private struct TabCardView: View {
    @ObservedObject var tab: BrowserModel
    let isActive: Bool
    let isPrivate: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 上部：サムネイル / プレビュー領域（タップで選択）
            previewArea
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(isPrivate ? Color(red: 0.12, green: 0.13, blue: 0.18) : Color(.tertiarySystemFill))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }

            Divider()
                .background(isPrivate ? Color.white.opacity(0.12) : Color(.separator))

            // 下部：タイトル・ドメインと閉じる「✕」ボタン
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.pageTitle.isEmpty ? (isPrivate ? NSLocalizedString("Private Tab", comment: "") : NSLocalizedString("Untitled", comment: "")) : tab.pageTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isPrivate ? Color.white : Color.primary)
                        .lineLimit(1)

                    if let host = hostString(for: tab.address) {
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundStyle(isPrivate ? Color.white.opacity(0.6) : Color.secondary)
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
                        .foregroundStyle(isPrivate ? Color.white.opacity(0.7) : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close Tab"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
            .background(isPrivate ? Color(red: 0.15, green: 0.16, blue: 0.22) : Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isActive ? (isPrivate ? Color.indigo : Color.blue) : (isPrivate ? Color.white.opacity(0.15) : Color(.separator).opacity(0.4)),
                    lineWidth: isActive ? 2.5 : 1
                )
        )
        .shadow(color: Color.black.opacity(isActive ? 0.15 : 0.05), radius: 6, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.pageTitle.isEmpty ? (isPrivate ? NSLocalizedString("Private Tab", comment: "") : NSLocalizedString("Untitled", comment: "")) : tab.pageTitle)\(isActive ? ", " + NSLocalizedString("Selected", comment: "") : "")")
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
            Image(systemName: isPrivate ? "eyeglasses" : placeholderIcon)
                .font(.system(size: 26))
                .foregroundStyle(isPrivate ? Color.indigo : Color.secondary)

            Text(isPrivate ? "Private" : "Page Preview")
                .font(.system(size: 11))
                .foregroundStyle(isPrivate ? Color.white.opacity(0.5) : Color.secondary)
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
