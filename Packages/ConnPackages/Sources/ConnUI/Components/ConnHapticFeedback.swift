import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// App 统一的高强度触感。交互层只引用这个入口，避免各页面重新选择轻重。
public enum ConnHapticFeedback {
    public static let intensity = 1.0

    public static var highImpact: SensoryFeedback {
        .impact(weight: .heavy, intensity: intensity)
    }

    #if canImport(UIKit)
        @MainActor
        public static func performHighImpact() {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred(intensity: intensity)
        }
    #endif
}
