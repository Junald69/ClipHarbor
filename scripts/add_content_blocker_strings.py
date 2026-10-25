import json
from pathlib import Path

path = Path("ClipHarbor/Localizable.xcstrings")
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

new_strings = {
    "Content Blocking": {
        "en": "Content Blocking",
        "ja": "コンテンツブロック"
    },
    "Block Ads & Trackers": {
        "en": "Block Ads & Trackers",
        "ja": "広告とトラッカーをブロック"
    },
    "Block Annoying Pop-ups": {
        "en": "Block Annoying Pop-ups",
        "ja": "迷惑ポップアップをブロック"
    },
    "Block evaluation is performed on-device using local rules. Browsing URLs and history are never sent to external servers for block evaluation.": {
        "en": "Block evaluation is performed on-device using local rules. Browsing URLs and history are never sent to external servers for block evaluation.",
        "ja": "ブロック判定は端末内のルールで行われ、ブロック判定のために閲覧URLや履歴を外部送信しません。"
    },
    "Blocked an annoying pop-up. If this was intentional, allow it for this site and retry.": {
        "en": "Blocked an annoying pop-up. If this was intentional, allow it for this site and retry.",
        "ja": "迷惑ポップアップをブロックしました。正常な操作の場合は、このサイトで許可して再試行してください。"
    },
    "Allow for this site and reload": {
        "en": "Allow for this site and reload",
        "ja": "このサイトで許可して再読み込み"
    },
    "Site Protection": {
        "en": "Site Protection",
        "ja": "サイトの保護設定"
    },
    "Enable Protection on This Site": {
        "en": "Enable Protection on This Site",
        "ja": "このサイトで保護を有効化"
    },
    "Disable Protection on This Site": {
        "en": "Disable Protection on This Site",
        "ja": "このサイトで保護を無効化"
    },
    "Protection Enabled": {
        "en": "Protection Enabled",
        "ja": "保護有効"
    },
    "Protection Disabled": {
        "en": "Protection Disabled",
        "ja": "保護解除中"
    },
    "Global content blocking is disabled in Settings.": {
        "en": "Global content blocking is disabled in Settings.",
        "ja": "設定画面でコンテンツブロックが無効化されています。"
    },
    "※ Exceptions set in Private Browsing are kept in memory and cleared when private tabs are closed.": {
        "en": "※ Exceptions set in Private Browsing are kept in memory and cleared when private tabs are closed.",
        "ja": "※ プライベートブラウズ中の例外設定はメモリ内のみ保持され、プライベートタブ終了時に消去されます。"
    },
    "Protection status for %@": {
        "en": "Protection status for %@",
        "ja": "%@ の保護設定"
    },
    "Content Blocker & Data Sources": {
        "en": "Content Blocker & Data Sources",
        "ja": "コンテンツブロック・データ出典"
    },
    "licenses_adaway_desc": {
        "en": "ClipHarbor adapts the open-source AdAway Default Blocklist into WebKit Content Rule List format to block known tracking and advertising domains directly on device.",
        "ja": "AdAway Default Blocklist をWebKitコンテンツルール形式に変換して採用し、既知の広告・トラッカー配信ドメインを端末内で直接ブロックします。"
    },
    "licenses_adaway_license": {
        "en": "Source: AdAway (commit f39ba0a)\nLicense: Creative Commons Attribution 3.0 Unported (CC BY 3.0)\nAdaptation: Converted hosts format to WebKit url-filter rules.",
        "ja": "出典: AdAway (コミット f39ba0a)\nライセンス: Creative Commons Attribution 3.0 Unported (CC BY 3.0)\n改変内容: hosts形式からWebKit url-filterルールへ変換して同梱"
    }
}

for key, trans in new_strings.items():
    data["strings"][key] = {
        "extractionState": "manual",
        "localizations": {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": trans["en"]
                }
            },
            "ja": {
                "stringUnit": {
                    "state": "translated",
                    "value": trans["ja"]
                }
            }
        }
    }

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

print(f"Added {len(new_strings)} strings. Total strings: {len(data['strings'])}")
