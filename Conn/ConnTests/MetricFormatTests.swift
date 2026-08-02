import Testing
@testable import Conn

struct MetricFormatTests {
    @Test("字节单位固定使用 B 系列缩写")
    func bytesUseStableBUnits() {
        #expect(MetricFormat.bytes(Double(0)) == "0 B")
        #expect(MetricFormat.bytes(Double(455)) == "455 B")
        #expect(MetricFormat.bytes(Double(1024)) == "1.0 K")
        #expect(MetricFormat.rate(Double(455)) == "455 B/s")
        #expect(MetricFormat.compactBytes(Double(455)) == "455 B")
        #expect(!MetricFormat.bytes(Double(455)).contains("字节"))
    }

    @Test("紧凑已用与总量不插入任何空格")
    func compactPairOmitsSlashPadding() {
        #expect(MetricFormat.compactPair(used: 1024, total: 2048) == "1.0K/2.0K")
        #expect(MetricFormat.compactPair(used: nil, total: 2048) == "—")
    }
}
