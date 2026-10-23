# Windows-only開発から個人配布・App Store・代替配布へのガイド v2.0

更新: 2026-10-13。以下は公式公開情報を踏まえた**計画**であり、実環境でのインストール/ストア申請実績ではない。

## 1. どの配布方法を使うか

| 経路 | 主な目的 | Apple有料メンバー | 開発・提出方法 | 留意点 |
|---|---|---|---|---|
| Personal + Sideloadly | 自分のiPhoneで試作 | 無料で開始可 | Windows Antigravity → GitHub ActionsのmacOSで無署名IPA → Windowsで個人署名・インストール | 無料Personal Teamの署名は原則7日で期限切れ。SideloadlyはApple非公式 |
| Ad Hoc | 少数の登録端末への正式なベータ配布 | 必要 | クラウドmacOSで有効な署名とAd Hocエクスポート | 登録端末と証明書管理などに制限がある |
| TestFlight | Appleのベータ配信 | 必要 | 署名済ビルドをApp Store Connectにアップロード | 90日の有効期限、外部テストはApple審査対象になり得る |
| App Store | 一般公開 | 必要 | 正規署名済archive/export・App Store Connect・App Review | 5.2.3などの審査をクリアする必要 |
| 日本の代替Marketplace | App Store外の一般向け配布候補 | 必要 | Apple公証、App Store Connectでの代替配信設定、マーケットプレイスとの連携 | iOS26.2以降、日本向けの追加条件。App Storeルールの回避を保証しない |

**重要**: 個人用`unsigned IPA`をそのままApp Store Connectへアップロードすることはできない。Store用には有効なApple Distribution署名と配布プロファイルを用いた別のビルド/アーカイブ/配布処理が必要。

## 2. 現段階 – Personal版をWindowsだけで実機に入れる

### 準備
- Windows 10/11、iPhone、USBケーブル。
- Antigravity (https://antigravity.google/download)。
- GitHub（非公開リポジトリを推奨）。
- Windows用Sideloadly（https://sideloadly.io/、Apple非公式）。
- Apple Account（無料で開始可能）。

### ソースコード
1. ZIP解凍→Antigravityでフォルダを開く。
2. `01_ANTIGRAVITY_PROMPT.md`を貼り、まず監査とビルドを依頼する。
3. 自身でGitHubのprivateリポジトリを作成。
4. ブランチと変更内容を確認し、認証情報が一切混入していないことを確認してpushする（AIに無断pushさせない）。
5. `.github/workflows/build-ios-unsigned.yml`をActionsで実行する。
6. `ClipHarbor-unsigned-ipa` Artifactを取得し、展開して`.ipa`を取り出す。
7. Sideloadlyの公式案内に従い、WindowsからiPhoneに**署名・インストール**する。必要に応じてiPhoneの開発者モードと開発者信頼設定を行う。
8. 権利を持つテスト動画で機能試験を行う。

### 無料Apple Accountの制約

Apple公式のPersonal Team案内では、アプリのプロビジョニングプロファイルは**7日**で失効し、同じ端末にインストールできるアプリは**最大3つ**などの制限がある。Sideloadlyに自動再署名機能があるとしても、確実な定期更新を保証するものではない。期限更新時の再インストールで保存動画が消えないか確認し、Filesへの手動バックアップ導線を優先実装する。

公式: https://developer.apple.com/help/account/basics/about-your-developer-account/

### GitHub Actions費用の注意

公開リポジトリの標準ランナーの無料条件、privateリポジトリの付与分数・macOSランナーの倍率、Artifact保存課金条件は変わり得る。利用する前に各プランの最新条件をGitHub公式で確認し、予算アラートを設定する。

公式: https://docs.github.com/en/billing/concepts/product-billing/github-actions

## 3. 将来 – App Store向けの正規配布

**Developer Program加入が必要**。加入は日本円/地域通貨表示の年会費を確認（米国参考価格年99 USD）。

1. App Store向け別Bundle ID（例`...clipharbor.store`）とStoreビルド構成を用意。
2. 署名証明書、App ID、プロビジョニング、App Store Connectアプリレコードを設定。
3. クラウドmacOS上で`xcodebuild archive` → `xcodebuild -exportArchive`を実行し、**配布用の正規署名**を行う。GitHub Actions等の適切な秘密情報管理を使用し、秘密鍵をリポジトリに保存しない。
4. App Store Connect API等で署名済ビルドをアップロード（CLI手順・認証方式は実装時のApple公式仕様で再確認）。
5. TestFlightで使用テスト。外部テストは審査があり得ること、ビルド有効期間90日を理解する。
6. App Privacy申告、プライバシーポリシーURL、サポートURL、対応地域、年齢区分、Review Notes、**許諾資料**を準備してApp Reviewに提出する。
7. 審査で第三者の明示的承認が要求されたときに証憑を提示できなければ、当該機能の範囲を縮小する。

個人開発でも「AIに任せたから自動公開」とはならず、Appleの契約、情報申告、審査対応と公開責任は本人にある。

## 4. 日本の代替アプリマーケットプレイス

AppleはiOS 26.2以降、日本での**公証を受けた**アプリの代替マーケットプレイス配布を認める制度を案内している。Appleの公証はApp Storeのフル審査とは範囲が異なるが、機能・セキュリティ・プライバシーの審査が残り、著作権や第三者サービスの規約を無視できるわけではない。個人のIPAをWebサイトに置くだけでApple公認の一般向けインストールが可能になる、という意味でもない。

調査項目：対応マーケットプレイスの実在と受付条件、Developer Program条件、利用地域、App Store Connectでの代替配信設定、公証の範囲、マーケット規約、手数料、ユーザーの更新体験。

公式: https://developer.apple.com/jp/support/app-distribution-in-japan/

## 5. よくある失敗の切り分け

| 症状 | 主な確認箇所 |
|---|---|
| GitHub ActionsでSwiftコンパイルエラー | Xcode/SDK/Scheme、実際の最初のcompiler error |
| Artifact ZIPがない | `Payload/*.app` のパス、Workflow実行結果、アップロードstep |
| Sideloadlyで署名できない | IPA構造、Bundle ID、Apple認証、Personal Team制限、端末接続 |
| 実機でクラッシュ | 開発者モード、信頼設定、署名、Swiftログ、iOSバージョン |
| 動画は再生できるが保存候補なし | blob/MSE/DRM、WebKitの観測限界、DOM sourceの仕様 |
| 候補があっても保存できない | 401/403、URL期限切れ、配信形式、容量、Cookie/リダイレクト |
| App Storeに提出できない | unsigned IPAを送ろうとしていないか、署名/プロファイル、規約同意 |
| 審査で拒否 | 5.2.2/5.2.3の権利根拠、説明と機能の整合、実際の審査メッセージ |

## 6. セキュリティ運用ルール

- GitHubはprivateから開始。Apple Account資格情報、Actionsシークレット、APIキー、認証Cookie、秘密鍵は絶対にコミットしない。
- CIの`xcodebuild`ログに環境変数や署名情報を丸ごとダンプしない。
- 誤アップロード時は単純削除だけでなく資格情報の失効と履歴の適切な処理が必要。
- 既存プロジェクトの個人用無署名ビルドは未検証。署名済みStore用Workflowは**まだ存在しない**。
