import Foundation
import SwiftUI
import WebKit

/// 複数タブのライフサイクル（生成・切り替え・削除・上限管理）を担当するマネージャー。
/// - 各タブは独立した BrowserModel インスタンスとして保持される。
/// - 通常タブ間では既存の WKWebsiteDataStore.default() を共有し、同一セッション・ログイン状態を維持する。
/// - タブ切り替え時は既存の BrowserModel および WKWebView を再利用し、破棄や再読み込みを行わない。
/// - タブ削除時のみ BrowserModel.teardown() を呼び出し、强参照循環やメモリリークを防止する。
@MainActor
final class TabManager: ObservableObject {
    /// 安全のためのタブ上限数（過剰なメモリ消費を防止）
    static let maxTabs: Int = 20

    /// 管理中の全通常タブ（最低1つを維持）
    @Published private(set) var tabs: [BrowserModel] = []

    /// 現在画面に表示中のアクティブタブID
    @Published var activeTabID: UUID {
        didSet {
            if oldValue != activeTabID {
                handleActiveTabChanged(from: oldValue, to: activeTabID)
            }
        }
    }

    /// 現在のアクティブタブ（常に有効なインスタンスを返す）
    var activeTab: BrowserModel {
        if let current = tabs.first(where: { $0.id == activeTabID }) {
            return current
        }
        if let first = tabs.first {
            return first
        }
        // 万が一空の場合は新しいホームタブを生成して復旧
        let fallback = BrowserModel()
        tabs = [fallback]
        activeTabID = fallback.id
        return fallback
    }

    /// 新規タブが作成可能か
    var canCreateNewTab: Bool {
        tabs.count < Self.maxTabs
    }

    /// タブ数
    var count: Int {
        tabs.count
    }

    init() {
        let initialTab = BrowserModel()
        self.tabs = [initialTab]
        self.activeTabID = initialTab.id
    }

    // MARK: - タブ操作API

    /// 新しいタブを作成し、アクティブにする
    @discardableResult
    func createNewTab(url: URL = BrowserModel.homeURL) -> BrowserModel? {
        guard canCreateNewTab else { return nil }
        activeTab.captureSnapshot()
        let newTab = BrowserModel(initialURL: url)
        tabs.append(newTab)
        activeTabID = newTab.id
        return newTab
    }

    /// 指定IDのタブをアクティブにする（WebViewの再生成や再読み込みは行わない）
    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard activeTabID != id else { return }
        activeTab.captureSnapshot()
        activeTabID = id
    }

    /// 指定IDのタブを明示的に閉じる
    /// - 最後のタブを閉じた場合は空画面にせず、自動的に新しいホームタブを作成する。
    /// - 削除されたタブに対してのみ BrowserModel.teardown() を実行する。
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTab = tabs[index]

        // 閉じる対象がアクティブタブの場合、削除前に新しいアクティブタブを決定する
        if activeTabID == id {
            if tabs.count > 1 {
                let nextIndex = index > 0 ? index - 1 : index + 1
                activeTabID = tabs[nextIndex].id
            }
        }

        tabs.remove(at: index)

        // WebKit強参照循環およびKVO・delegateを安全に解除
        closingTab.teardown()

        // 最後のタブを閉じた場合は空画面にせず、新しいホームタブを作成
        if tabs.isEmpty {
            let freshTab = BrowserModel()
            tabs = [freshTab]
            activeTabID = freshTab.id
        }
    }

    // MARK: - 内部処理

    private func handleActiveTabChanged(from oldID: UUID, to newID: UUID) {
        // 将来のステップでタブ非アクティブ化時のサムネイル記録や音声制御を安全にフック可能
    }
}
