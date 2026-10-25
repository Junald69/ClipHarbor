import SwiftUI
import LocalAuthentication

/// Private Vault（非公開保管庫）の統合設定画面
/// - 生体認証（Face ID / Touch ID）の有効・無効切替
/// - 6桁パスコードの変更
/// - ファイル一覧でのVaultカード表示・非表示設定
/// - 暗号化仕様・自動ロック条件・パスコード紛失時の不可復旧性の説明
struct VaultSettingsView: View {
    @ObservedObject var vaultManager = VaultManager.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showChangePasscode = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // セクション 1: 認証・生体認証
                Section(NSLocalizedString("Unlock Settings", comment: "")) {
                    if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
                        Toggle(isOn: Binding(
                            get: { vaultManager.isBiometricsEnabled },
                            set: { enabled in
                                vaultManager.setBiometricsEnabled(enabled)
                                showToast(enabled ? "Face IDを有効にしました" : "Face IDを無効にしました")
                            }
                        )) {
                            Label(NSLocalizedString("Unlock with Face ID / Biometrics", comment: ""), systemImage: "faceid")
                        }
                    }

                    Button {
                        showChangePasscode = true
                    } label: {
                        HStack {
                            Label(NSLocalizedString("Change Passcode", comment: ""), systemImage: "key.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // セクション 2: 表示設定 (Private Vault一覧表示設定)
                Section {
                    Toggle(isOn: $settingsManager.hideVaultInFileList) {
                        Text(NSLocalizedString("Hide Private Vault from File List", comment: ""))
                    }
                } header: {
                    Text(NSLocalizedString("Display Settings", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Hides the Private Vault card from the file list. You can still access the Vault anytime from the top-right menu (…).", comment: ""))
                        .font(.caption2)
                }

                // セクション 3: セキュリティとロック条件
                Section(NSLocalizedString("Security Specifications", comment: "")) {
                    HStack {
                        Text(NSLocalizedString("Encryption", comment: ""))
                        Spacer()
                        Text("AES-256-GCM (1MBチャンク)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(NSLocalizedString("Key Derivation", comment: ""))
                        Spacer()
                        Text("PBKDF2 (SHA-256, 10万回)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(NSLocalizedString("Auto-Lock", comment: ""))
                        Spacer()
                        Text(NSLocalizedString("On app exit or background", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // セクション 4: 重要事項
                Section(NSLocalizedString("Important Notice", comment: "")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(NSLocalizedString("Passcode Management", comment: ""), systemImage: "exclamationmark.triangle.fill")
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
            .navigationTitle(NSLocalizedString("Private Vault Settings", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Close", comment: "")) { dismiss() }
                }
            }
            .sheet(isPresented: $showChangePasscode) {
                VaultChangePasscodeView {
                    showToast("パスコードを変更しました")
                }
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
