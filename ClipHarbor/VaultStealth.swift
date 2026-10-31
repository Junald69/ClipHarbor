import SwiftUI

/// Private Vault ステルスモード関連の型・判定ロジック
/// - アクセスジェスチャー種別（Filesタイトル長押し / 5回タップ）
/// - 通常画面における Vault 入口・表示の可視性ポリシー
/// - 3秒以内5回タップ判定器
/// - 「Files」タイトル用ジェスチャーモディファイア
/// - Vault 画面終了時のロック判定
/// ※ 暗号化データ・マスター鍵・Keychain には一切関与しない（UserDefaults の表示設定のみ）

// MARK: - アクセスジェスチャー種別

enum StealthAccessGesture: String, CaseIterable, Identifiable, Codable {
    case longPress = "longPress"
    case fiveTaps = "fiveTaps"

    var id: String { rawValue }

    /// 不正値・未保存時のフォールバック（タイトルからのアクセス経路を必ず維持）
    static let fallback: StealthAccessGesture = .longPress
    /// 長押し判定時間（既存仕様の約2秒）
    static let longPressDuration: Double = 2.0
    /// 連続タップ必要回数
    static let requiredTapCount: Int = 5
    /// 連続タップ判定時間窓（秒）
    static let tapTimeWindow: TimeInterval = 3.0

    /// 保存値からの安全な復元（不正値は必ず長押しへフォールバック）
    static func resolve(rawValue: String?) -> StealthAccessGesture {
        guard let raw = rawValue, let value = StealthAccessGesture(rawValue: raw) else {
            return fallback
        }
        return value
    }

    var title: String {
        switch self {
        case .longPress:
            return NSLocalizedString("Long-press \"Files\" title", comment: "")
        case .fiveTaps:
            return NSLocalizedString("Tap \"Files\" title 5 times", comment: "")
        }
    }

    var instruction: String {
        switch self {
        case .longPress:
            return NSLocalizedString("Press and hold the \"Files\" title at the top of the file list for about 2 seconds.", comment: "")
        case .fiveTaps:
            return NSLocalizedString("Tap the \"Files\" title at the top of the file list 5 times within 3 seconds.", comment: "")
        }
    }
}

// MARK: - ステルス設定の永続化（テスト用に UserDefaults を注入可能）

enum VaultStealthSettingsStore {
    static let stealthModeKey = "clipHarbor.settings.isStealthModeEnabled"
    static let accessGestureKey = "clipHarbor.settings.stealthAccessGesture"
    static let hideVaultInFileListKey = "clipHarbor.settings.hideVaultInFileList"
    /// 旧バージョンの「隠しモード」キー（カード非表示のみを意味する。完全ステルスへは変換しない）
    static let legacyHideVaultKey = "VaultManager.isStealthModeEnabled"

    /// ステルスモード読み出し（未保存・不正値は必ず OFF）
    static func loadStealthModeEnabled(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: stealthModeKey) as? Bool) ?? false
    }

    static func saveStealthModeEnabled(_ enabled: Bool, to defaults: UserDefaults) {
        defaults.set(enabled, forKey: stealthModeKey)
    }

    /// アクセスジェスチャー読み出し（未保存・不正値は長押しへフォールバック）
    static func loadAccessGesture(from defaults: UserDefaults) -> StealthAccessGesture {
        StealthAccessGesture.resolve(rawValue: defaults.object(forKey: accessGestureKey) as? String)
    }

    static func saveAccessGesture(_ gesture: StealthAccessGesture, to defaults: UserDefaults) {
        defaults.set(gesture.rawValue, forKey: accessGestureKey)
    }

    /// 旧カード非表示設定の読み出し（新キー優先、未保存時のみ旧隠しモードを引き継ぐ。初期値: false=カード表示）
    static func loadHideVaultInFileList(from defaults: UserDefaults) -> Bool {
        if let existingVal = defaults.object(forKey: hideVaultInFileListKey) as? Bool {
            return existingVal
        }
        if let legacyVal = defaults.object(forKey: legacyHideVaultKey) as? Bool {
            defaults.set(legacyVal, forKey: hideVaultInFileListKey)
            return legacyVal
        }
        return false
    }
}

// MARK: - 通常画面における Vault 可視性ポリシー

struct VaultVisibilityPolicy: Equatable {
    let isStealthModeEnabled: Bool
    let hideVaultCardInFileList: Bool
    let isVaultInitialized: Bool

    /// 実効ステルス（未初期化の Vault には隠す対象が無いため適用しない）
    var isStealthActive: Bool { isStealthModeEnabled && isVaultInitialized }

    /// ファイル一覧ルートの Vault カード（旧カード非表示設定を常に尊重）
    var showsVaultCard: Bool { !isStealthActive && !hideVaultCardInFileList }
    /// 右上「…」メニューの Private Vault 項目
    var showsVaultMenuEntry: Bool { !isStealthActive }
    /// 通常動画からの Vault 移動（個別・一括）。UI 表示と実行経路の両方で参照する
    var allowsMoveToVaultFromNormalUI: Bool { !isStealthActive }
    /// 通常設定内の Vault 設定入口
    var showsVaultSettingsEntry: Bool { !isStealthActive }
    /// 通常画面の Vault 関連説明文・名称
    var showsVaultMentions: Bool { !isStealthActive }
    /// 「Files」タイトルの名前付きアクセシビリティアクション（"Open Vault"）
    var exposesNamedAccessibilityAction: Bool { !isStealthActive }

    @MainActor
    static func current(
        settings: AppSettingsManager = .shared,
        vaultManager: VaultManager = .shared
    ) -> VaultVisibilityPolicy {
        VaultVisibilityPolicy(
            isStealthModeEnabled: settings.isStealthModeEnabled,
            hideVaultCardInFileList: settings.hideVaultInFileList,
            isVaultInitialized: vaultManager.isInitialized
        )
    }
}

// MARK: - 3秒以内5回タップ判定器

struct StealthTapDetector: Equatable {
    let requiredTaps: Int
    let timeWindow: TimeInterval
    /// 同一操作の二重通知（タップ＋アクセシビリティ活性化）を除外する最小間隔
    let minimumInterval: TimeInterval
    private(set) var timestamps: [TimeInterval] = []

    init(
        requiredTaps: Int = StealthAccessGesture.requiredTapCount,
        timeWindow: TimeInterval = StealthAccessGesture.tapTimeWindow,
        minimumInterval: TimeInterval = 0.05
    ) {
        self.requiredTaps = max(1, requiredTaps)
        self.timeWindow = timeWindow
        self.minimumInterval = minimumInterval
    }

    /// タップを登録し、判定成立時に true を返す（成立時は履歴をクリア）
    mutating func registerTap(at time: TimeInterval) -> Bool {
        if let last = timestamps.last {
            if time < last {
                // 時刻の逆行は安全側で履歴を破棄
                timestamps.removeAll()
            } else if time - last < minimumInterval {
                return false
            }
        }
        timestamps.append(time)
        timestamps.removeAll { time - $0 > timeWindow }
        if timestamps.count >= requiredTaps {
            timestamps.removeAll()
            return true
        }
        return false
    }

    mutating func reset() {
        timestamps.removeAll()
    }
}

// MARK: - 「Files」タイトル用ジェスチャーモディファイア

/// 選択されたジェスチャーのみを排他的に付与する
/// - 長押し: 約2秒（VoiceOver ではダブルタップ＆ホールドで同じジェスチャーが通過）
/// - 5回タップ: 3秒以内5回（VoiceOver のダブルタップ活性化も1タップとして計数）
/// - 検出状態は成功時・画面離脱時・モード変更時にクリア
struct StealthTitleGestureModifier: ViewModifier {
    let gesture: StealthAccessGesture
    let onTrigger: () -> Void

    @State private var detector = StealthTapDetector()

    func body(content: Content) -> some View {
        Group {
            switch gesture {
            case .longPress:
                content
                    .onLongPressGesture(minimumDuration: StealthAccessGesture.longPressDuration) {
                        trigger()
                    }
            case .fiveTaps:
                content
                    .onTapGesture {
                        registerTap()
                    }
                    .accessibilityAction {
                        registerTap()
                    }
            }
        }
        .onChange(of: gesture) { _ in
            detector.reset()
        }
        .onDisappear {
            detector.reset()
        }
    }

    private func registerTap() {
        if detector.registerTap(at: ProcessInfo.processInfo.systemUptime) {
            trigger()
        }
    }

    private func trigger() {
        detector.reset()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onTrigger()
    }
}

/// ステルス OFF 時のみ名前付きアクセシビリティアクションを付与する
struct ConditionalNamedAccessibilityAction: ViewModifier {
    let isEnabled: Bool
    let name: Text
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

// MARK: - Vault 画面終了時のロック制御

@MainActor
enum VaultPresentationLifecycle {
    /// Vault 画面の onDisappear でロックすべきか（プレイヤーやネストした設定・インポート等のシート遷移中はロックしない）
    static func shouldLockOnDisappear(
        isPresentingPlayer: Bool,
        isPresentingNestedSheet: Bool = false
    ) -> Bool {
        !isPresentingPlayer && !isPresentingNestedSheet
    }

    /// Vault 画面（シート）が完全に閉じられた際のロック
    /// - 閉じるボタン・スワイプ閉鎖・システム都合の終了のいずれでも呼ばれる
    /// - 既にロック済みの場合は何もしない（セッショントークンを不要に更新しない）
    static func handleVaultScreenClosed(vaultManager: VaultManager) {
        if vaultManager.isUnlocked {
            vaultManager.lock()
        }
    }
}
