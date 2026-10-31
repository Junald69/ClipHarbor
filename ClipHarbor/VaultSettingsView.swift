import SwiftUI
import LocalAuthentication

/// Private Vault（非公開保管庫）の統合設定画面
/// - 生体認証（Face ID / Touch ID）の有効・無効切替
/// - 6桁パスコードの変更
/// - ファイル一覧でのVaultカード表示・非表示設定（旧設定。ステルスモードとは独立）
/// - ステルスモード（ON時は通常画面から全入口を非表示。有効化前にジェスチャー練習を必須化）
/// - 暗号化仕様・自動ロック条件・パスコード紛失時の不可復旧性の説明
struct VaultSettingsView: View {
    @ObservedObject var vaultManager = VaultManager.shared
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showChangePasscode = false
    @State private var toastMessage: String?
    @State private var integrityReport: VaultManager.VaultIntegrityReport?
    @State private var showStealthRehearsal = false

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
                                showToast(enabled ? NSLocalizedString("Enabled Face ID", comment: "") : NSLocalizedString("Disabled Face ID", comment: ""))
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
                    .disabled(settingsManager.isStealthModeEnabled)
                } header: {
                    Text(NSLocalizedString("Display Settings", comment: ""))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Hides the Private Vault card from the file list. You can still access the Vault anytime from the top-right menu (…).", comment: ""))
                        if settingsManager.isStealthModeEnabled {
                            Text(NSLocalizedString("While Stealth Mode is on, the card and all other entries are hidden regardless of this setting.", comment: ""))
                        }
                    }
                    .font(.caption2)
                }

                // セクション 3: ステルスモード
                Section {
                    Toggle(isOn: Binding(
                        get: { settingsManager.isStealthModeEnabled },
                        set: { enabled in
                            if enabled {
                                guard settingsManager.hideVaultInFileList else { return }
                                // 有効化前に必ずジェスチャーの説明と練習を経由（ロックアウト防止）
                                showStealthRehearsal = true
                            } else {
                                settingsManager.isStealthModeEnabled = false
                                showToast(NSLocalizedString("Stealth Mode disabled", comment: ""))
                            }
                        }
                    )) {
                        Label(NSLocalizedString("Stealth Mode", comment: ""), systemImage: "eye.slash")
                    }
                    .disabled(!settingsManager.hideVaultInFileList)

                    Picker(NSLocalizedString("Access Gesture", comment: ""), selection: $settingsManager.stealthAccessGesture) {
                        ForEach(StealthAccessGesture.allCases) { gesture in
                            Text(gesture.title).tag(gesture)
                        }
                    }
                    .disabled(!settingsManager.hideVaultInFileList || settingsManager.isStealthModeEnabled)

                    Text(settingsManager.stealthAccessGesture.instruction)
                        .font(.caption)
                        .foregroundStyle(settingsManager.hideVaultInFileList ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(NSLocalizedString("Stealth Mode", comment: ""))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !settingsManager.hideVaultInFileList {
                            Text(NSLocalizedString("To use Stealth Mode, please turn on \"Hide Private Vault from File List\" first.", comment: ""))
                        } else {
                            Text(NSLocalizedString("When Stealth Mode is on, the Vault card, menus, Move to Vault actions, and related descriptions are hidden from normal screens. The only way in is the selected gesture on the \"Files\" title, followed by your passcode or Face ID. Stealth Mode can only be turned off here after unlocking.", comment: ""))
                            if settingsManager.isStealthModeEnabled {
                                Text(NSLocalizedString("Turn off Stealth Mode to change the access gesture.", comment: ""))
                            }
                        }
                    }
                    .font(.caption2)
                }

                // セクション 4: セキュリティとロック条件
                Section(NSLocalizedString("Security Specifications", comment: "")) {
                    HStack {
                        Text(NSLocalizedString("Encryption", comment: ""))
                        Spacer()
                        Text("AES-256-GCM (1MB Chunks)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(NSLocalizedString("Key Derivation", comment: ""))
                        Spacer()
                        Text("PBKDF2 (SHA-256, 100,000 iterations)")
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

                // セクション 5: 整合性診断（読み取り専用）
                Section(NSLocalizedString("Integrity & Diagnostics", comment: "")) {
                    Button {
                        integrityReport = vaultManager.checkVaultIntegrity()
                    } label: {
                        Label(NSLocalizedString("Check Vault Integrity", comment: ""), systemImage: "stethoscope")
                    }

                    if let report = integrityReport {
                        HStack {
                            Text(NSLocalizedString("Vault Integrity", comment: ""))
                            Spacer()
                            if report.hasAnomalies {
                                Text(String(format: NSLocalizedString("Anomalies detected (Ghost: %lld, Orphan: %lld)", comment: ""), report.ghostItemIDs.count, report.orphanedDirectoryIDs.count))
                                    .foregroundStyle(.orange)
                            } else {
                                Text(NSLocalizedString("Healthy (0 anomalies)", comment: ""))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                // セクション 4: 重要事項
                Section(NSLocalizedString("Important Notice", comment: "")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(NSLocalizedString("Passcode Management", comment: ""), systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("Because the encryption master key is derived solely from the entered passcode, if you forget your passcode, no one—including the developer—can decrypt or recover videos in the vault. Please make sure to choose a passcode you will not forget.")
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
                    showToast(NSLocalizedString("Passcode changed", comment: ""))
                }
            }
            .sheet(isPresented: $showStealthRehearsal) {
                StealthModeRehearsalView(gesture: settingsManager.stealthAccessGesture) {
                    settingsManager.isStealthModeEnabled = true
                    showToast(NSLocalizedString("Stealth Mode enabled", comment: ""))
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

// MARK: - ステルスモード有効化前のジェスチャー練習シート

/// 選択中のジェスチャーを見本の「Files」タイトルで実際に成功させるまで有効化できない
/// - 本番と同一の StealthTitleGestureModifier を使用し、操作感の差異による締め出しを防止
struct StealthModeRehearsalView: View {
    let gesture: StealthAccessGesture
    let onEnable: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var didPerformGesture = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(NSLocalizedString("When Stealth Mode is on, the Vault card, menus, Move to Vault actions, and related descriptions are hidden from normal screens. The only way in is the selected gesture on the \"Files\" title, followed by your passcode or Face ID. Stealth Mode can only be turned off here after unlocking.", comment: ""))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    VStack(spacing: 14) {
                        Text(gesture.instruction)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Files")
                            .font(.headline)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .contentShape(Capsule())
                            .modifier(StealthTitleGestureModifier(gesture: gesture) {
                                withAnimation { didPerformGesture = true }
                            })

                        if didPerformGesture {
                            Label(NSLocalizedString("Gesture confirmed", comment: ""), systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    Text(gesture.title)
                } footer: {
                    Text(NSLocalizedString("Practice the gesture on the sample title above before enabling. With VoiceOver, double-tap and hold the title (long-press mode), or double-tap it 5 times within 3 seconds (5-tap mode).", comment: ""))
                        .font(.caption2)
                }

                Section {
                    Button {
                        onEnable()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text(NSLocalizedString("Enable Stealth Mode", comment: ""))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!didPerformGesture)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NSLocalizedString("Stealth Mode", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                }
            }
        }
    }
}
