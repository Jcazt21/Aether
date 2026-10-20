import Testing
@testable import AetherCore

@Suite struct OutputDeviceTests {
    @Test func bestRatePrefersExactThenIntegerMultipleThenMax() {
        let rates: [Double] = [44_100, 48_000, 88_200, 96_000]
        #expect(OutputDevice.bestRate(for: 96_000, among: rates) == 96_000)
        #expect(OutputDevice.bestRate(for: 176_400, among: rates) == 88_200)
        #expect(OutputDevice.bestRate(for: 192_000, among: rates) == 96_000)
        #expect(OutputDevice.bestRate(for: 22_050, among: rates) == 44_100)
        #expect(OutputDevice.bestRate(for: 32_000, among: []) == 32_000)
    }

    @Test(.enabled(if: OutputDevice.defaultOutput() != nil))
    func defaultDeviceReportsSaneValues() throws {
        let device = try #require(OutputDevice.defaultOutput())
        #expect(!device.name.isEmpty)
        #expect(device.nominalSampleRate >= 8_000)
        #expect(device.availableSampleRates.contains(device.nominalSampleRate))
    }
}
