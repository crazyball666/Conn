import Foundation
import Testing
@testable import ConnKit

@Suite("Timestamp — 毫秒时间戳工具")
struct TimestampTests {
    @Test("now() 返回当前 Unix 毫秒，量级正确")
    func nowIsInMilliseconds() {
        let ms = Timestamp.now()
        // 2020-01-01 = 1_577_836_800_000ms；2100-01-01 = 4_102_444_800_000ms
        #expect(ms > 1_577_836_800_000)
        #expect(ms < 4_102_444_800_000)
    }

    @Test("毫秒与 Date 双向转换无损")
    func roundTripThroughDate() {
        let ms: Int64 = 1_752_912_000_123
        let date = Timestamp.date(from: ms)
        #expect(Timestamp.milliseconds(from: date) == ms)
    }

    @Test("Date → 毫秒保留亚秒精度")
    func preservesSubSecondPrecision() {
        let date = Date(timeIntervalSince1970: 1_752_912_000.789)
        #expect(Timestamp.milliseconds(from: date) == 1_752_912_000_789)
    }
}
