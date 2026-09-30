import Foundation
import PearfyCLIKit
import Testing

@Test func sdkVersionCatalogExposesV16ThroughV18CLIProfiles() throws {
    let releases = try PearfyModuleManager().sdkReleases()
    #expect(releases.map(\.version) == ["1.6", "1.7", "1.8"])
    #expect(releases.map(\.modules) == [["populate"], ["devkit-ui"], ["gateway-lab"]])
    #expect(releases[1].commands.contains("pearfy devkit start|open|doctor|export"))
    #expect(releases[2].commands.contains("pearfy add gateway-lab"))
}

@Test func devKitCLIResolvesOnlyDashboardRootOrExpectedPath() throws {
    let origin = try PearfyDevKitCLICommand.dashboardURL(from: "http://127.0.0.1:9090")
    #expect(origin.path == "/__pearfy/devkit")
    let explicit = try PearfyDevKitCLICommand.dashboardURL(from: "http://localhost:8080/__pearfy/devkit")
    #expect(explicit.path == "/__pearfy/devkit")

    var invalidPathRejected = false
    do {
        _ = try PearfyDevKitCLICommand.dashboardURL(from: "http://127.0.0.1:8080/admin")
    } catch {
        invalidPathRejected = true
    }
    #expect(invalidPathRejected)
}
