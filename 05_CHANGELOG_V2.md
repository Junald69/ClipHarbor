# 変更履歴：ClipHarbor開発キット v1 → v2

日付: 2026-10-13

| 項目 | v1 | v2 |
|---|---|---|
| 製品戦略 | 個人向けMVP | **Personal動画保存機能最優先**＋Store公開を将来目標として保持 |
| ビルド | Personal一種類を想定 | Personal/Storeの**別バイナリ**を将来導入する設計 |
| 権利処理 | 許諾を受けた動画に限定という共通方針 | StoreのRightsPolicyと証憑台帳を明示、未確認ソースを除外 |
| Store対応 | App Storeは範囲外 | App Review 2.3.1 / 5.2.2 / 5.2.3を設計要件化 |
| 日本の流通 | App Storeか個人サイドロード | iOS 26.2以降の代替マーケット配信を将来の第三案として記載 |
| CI/CD | 無署名IPAのみ | 無署名IPAの継続利用。将来別の署名済みStore配布ワークフローが必要と明記 |
| セキュリティ | URLをログに出さない | 認証付きソースURLの**永続化自体を禁止**。既存コード上の課題を指摘 |
| テスト | 個人向け動画保存を中心 | 実機機能/Store向け権利確認/配布経路/セキュリティを分けて記録 |

## この版に含まれるコードの状態

- `ClipHarbor/*.swift`、`ClipHarbor.xcodeproj/`、`.github/workflows/build-ios-unsigned.yml`は**前回の試作コードをそのまま収録**。v2のビルド構成、RightsPolicy、トークン永続化対策等を実装したものではない。
- 既存`DownloadCenter.swift`には`SavedVideo.sourceURLString`として元の動画URL全文を`UserDefaults`へ永続化する処理がある。URLに期限付き認証トークン等を含む可能性があるので**最優先修正対象**。
- 既存Cookie/Referer引き継ぎロジックはリダイレクト時の認証情報送信も含めたセキュリティレビューが必要。
- GitHub Actionsでのビルド、Sideloadlyインストール、実機機能、App Store審査は**未実施**。
- v2改訂時点の作業は**要件定義・開発指示・ガイドの更新**であって、動作検証や新機能実装を意味しない。
