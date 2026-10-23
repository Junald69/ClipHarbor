# ClipHarbor – Antigravity開発キット v2.0

更新日: 2026-10-13 / プロジェクト方針: **動画保存機能優先、将来の一般公開も選択肢として保持**

## 今回の決定

- 第1目標: Windows + Antigravity + クラウドmacOSで、個人iPhone向けの **ClipHarbor Personal** を開発する。
- 最優先機能: 動画の再生検出、動画保存候補の表示、ユーザー操作による直接ファイル・対応HLSの保存、端末内ファイル管理。**アプリが設ける回数・件数の上限はゼロ**。
- 並行して **ClipHarbor Store** を別ビルドとして設計する。App Storeに公開する動画保存機能は、第三者からの明示的な承認を裏付ける資料がある配信元等に限定する。
- 日本ではiOS 26.2以降に **代替アプリマーケットプレイス** 配信も制度上可能。Appleの公証・適格性・契約条件を要するため、将来検討とする。
- **個人利用版がApp Storeを通過する保証はない**。個人インストールでも第三者の権利、サービス利用規約、DRM・アクセス制限を尊重する。
- 絶対禁止: Appleの審査を欺く隠し機能／審査後の遠隔有効化、DRMや技術的アクセス制御の回避、資格情報の漏えい。

## フォルダ構成

| ファイル | 内容 |
|---|---|
| `00_START_HERE.md` | 最初に読む方針と順番 |
| `01_ANTIGRAVITY_PROMPT.md` | Antigravityに貼り付ける詳細な開発指示 |
| `02_PRODUCT_SPEC.md` | **改訂版の正式な製品・技術仕様 v2.0** |
| `03_WINDOWS_BUILD_GUIDE.md` | 個人署名〜将来のStore署名、配布経路比較 |
| `04_RELEASE_AND_RIGHTS_CHECKLIST.md` | 権利資料、審査対策、プライバシー、テスト用チェックリスト |
| `05_CHANGELOG_V2.md` | v1からの主要な変更・コードとの差分 |
| `ClipHarbor/`, `ClipHarbor.xcodeproj/` | v1から引き継いだ**未ビルドの試作コード（変更なし）** |
| `.github/workflows/build-ios-unsigned.yml` | 個人版の無署名ビルド用・未実行ワークフロー |

## 最初の作業

1. ZIPをWindowsで解凍し、そのフォルダをGoogle Antigravityで開く。
2. `01_ANTIGRAVITY_PROMPT.md` の全文を送る。
3. Antigravityに **Phase 0: 既存コードの脆弱性レビュー → Phase 1: ビルド成功** を行わせる。
4. GitHubリポジトリへの接続・pushは、内容を確認した後に明示的に許可する。
5. 無署名IPAを生成できたら、`03_WINDOWS_BUILD_GUIDE.md` の個人用署名・インストール手順を実施する。
6. 自作のテスト動画でのMP4保存から始める。

## 留意事項

このキットは**仕様書・プロンプトの改訂版**です。別ビルドの仕組みやApp Store向け権限管理を実装済みという意味ではありません。既存Swiftコード・GitHub ActionsをXcodeでコンパイルした実績、実機確認、Apple審査実績はありません。認証URLを保存するなど、既存コードには優先修正が必要な点があります。

## Apple等の一次情報

- App Review Guidelines 2.3.1 / 5.2.2 / 5.2.3: https://developer.apple.com/jp/app-store/review/guidelines/
- 日本の代替配信・公証: https://developer.apple.com/jp/support/app-distribution-in-japan/
- Apple Personal Team制限: https://developer.apple.com/help/account/basics/about-your-developer-account/
- TestFlight: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- GitHub Actions: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Sideloadly（Apple非公式）: https://sideloadly.io/
