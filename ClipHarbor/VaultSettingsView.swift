import SwiftUI
import LocalAuthentication

/// Private Vault（非公開保管庫）の統合設定画面
/// - 生体認証（Face ID / Touch ID）の有効・無効切替
/// - 6桁パスコードの変更
/// - 隠しモード（Stealth Mode）の有効化・無効化
/// - 暗号化仕様・自動ロック条件・パスコード紛失時の不可復旧性の説明
struct VaultSettingsView: View {
    @ObservedObject var vaultManager = VaultManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showChangePasscode = false
    @State private var showStealthModeAlert = false
    @State private var showStealthModeExplanation = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // セクション 1: 認証・生体認証
                Section("ロック解除設定") {
                    if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                        Toggle(isOn: Binding(
                            get: { vaultManager.isBiometricsEnabled },
                            set: { enabled in
                                vaultManager.setBiometricsEnabled(enabled)
                                showToast(enabled ? "Face IDを有効にしました" : "Face IDを無効にしました")
                            }
                        )) {
                            Label("Face ID / 生体認証で解除", systemImage: "faceid")
                        }
                    }

                    Button {
                        showChangePasscode = true
                    } label: {
                        HStack {
                            Label("専用パスコードを変更", systemImage: "key.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // セクション 2: 隠しモード (Stealth Mode)
                Section {
                    Toggle(isOn: Binding(
                        get: { vaultManager.isStealthModeEnabled },
                        set: { enabled in
                            if enabled {
                                showStealthModeExplanation = true
                            } else {
                                vaultManager.setStealthModeEnabled(false)
                                showToast("隠しモードを無効化しました")
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("隠しモード（Stealth Mode）")
                                .font(.body)
                            Text(vaultManager.isStealthModeEnabled ? "有効: ファイル画面や設定からVaultの表示が完全に隠されています" : "無効: 通常ファイル一覧の先頭にVaultカードを表示します")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("プライバシー表示")
                } footer: {
                    Text("隠しモードを有効にすると、ファイル一覧やメニュー、設定画面からVaultの表示が消去されます。開くにはファイル画面タイトル「ファイル」を2秒長押しします。")
                        .font(.caption2)
                }

                // セクション 3: セキュリティとロック条件
                Section("セキュリティ保護仕様") {
                    HStack {
                        Text("暗号化方式")
                        Spacer()
                        Text("AES-256-GCM (1MBチャンク)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("鍵導出方式")
                        Spacer()
                        Text("PBKDF2 (SHA-256, 10万回)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("自動ロック")
                        Spacer()
                        Text("アプリ終了・バックグラウンド移行時")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // セクション 4: 重要事項
                Section("重要なお知らせ") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("パスコードの管理について", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("暗号化マスター鍵は入力されたパスコードのみから導出されるため、パスコードを忘れた場合は開発者を含め誰も保管庫内の動画を復号・復旧することはできません。必ず忘れない番号をご設定ください。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Private Vault 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showChangePasscode) {
                VaultChangePasscodeView {
                    showToast("パスコードを変更しました")
                }
            }
            .sheet(isPresented: $showStealthModeExplanation) {
                VaultStealthModeSetupSheet(
                    onConfirm: {
                        vaultManager.setStealthModeEnabled(true)
                        showToast("隠しモードを有効化しました")
                    }
                )
            }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(toast)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: toastMessage)
        }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                toastMessage = nil
            }
        }
    }
}

/// 隠しモード有効化前の説明・同意シート
struct VaultStealthModeSetupSheet: View {
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.12))
                            .frame(width: 80, height: 80)
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.indigo)
                    }
                    .padding(.top, 16)

                    VStack(spacing: 8) {
                        Text("隠しモードを有効にしますか？")
                            .font(.title2.weight(.bold))
                        Text("Private Vaultの存在そのものをアプリ内から隠蔽します")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        bulletPoint(
                            icon: "square.grid.2x2",
                            title: "一覧・メニューからの完全非表示",
                            description: "ファイル一覧のVaultカード、右上メニュー、設定画面、動画の「Vaultへ移動」ボタンがすべて非表示になります。"
                        )

                        bulletPoint(
                            icon: "hand.tap.fill",
                            title: "開き方：タイトル「ファイル」を2秒長押し",
                            description: "ファイル管理ルート画面の上部ナビゲーションタイトル「ファイル」を2秒間長押しすると、認証画面が表示されます。"
                        )

                        bulletPoint(
                            icon: "lock.shield.fill",
                            title: "毎回厳格な認証が必要",
                            description: "長押し操作を行うだけで解錠されることはありません。設定されたパスコードまたはFace IDでの認証を必ず経由します。"
                        )

                        bulletPoint(
                            icon: "accessibility",
                            title: "アクセシビリティ対応",
                            description: "VoiceOver環境では、タイトル「ファイル」のカスタムアクション「保管庫を開く」から起動できます。"
                        )
                    }
                    .padding(18)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)

                    Spacer(minLength: 20)

                    VStack(spacing: 12) {
                        Button {
                            onConfirm()
                            dismiss()
                        } label: {
                            Text("理解して隠しモードを有効化")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14))
                        }

                        Button("キャンセル") {
                            dismiss()
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func bulletPoint(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
