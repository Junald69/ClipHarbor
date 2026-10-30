import Foundation

/// 再生速度の表示フォーマットおよびスナップ処理
/// - 0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 2.0x の高精度統一フォーマット
/// - AVPlayerやPiP復帰時の微小浮動小数点誤差の吸収
public struct PlaybackSpeedFormatter {
    /// 標準の再生速度選択肢 (0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 2.0x)
    public static let standardSpeeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// 浮動小数点数の微小誤差を吸収し、最も近い標準速度にスナップする
    public static func snapToStandardSpeed(_ rate: Float) -> Float {
        for speed in standardSpeeds {
            if abs(rate - speed) < 0.02 {
                return speed
            }
        }
        return rate
    }

    /// 表示用文字列の生成
    /// - 0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 2.0x に統一
    /// - メニュー項目、プレイヤー下部表示、アクセシビリティ読み上げ値で共有
    public static func format(_ rate: Float) -> String {
        let snapped = snapToStandardSpeed(rate)
        let hundredths = Int((snapped * 100.0).rounded())
        if hundredths % 10 == 0 {
            return String(format: "%.1fx", Float(hundredths) / 100.0)
        } else {
            return String(format: "%.2fx", Float(hundredths) / 100.0)
        }
    }
}
