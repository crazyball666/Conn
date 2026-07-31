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
}
