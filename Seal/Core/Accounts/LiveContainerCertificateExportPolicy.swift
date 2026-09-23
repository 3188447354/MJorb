import Foundation

enum LiveContainerCertificateExportPolicy {
    static func isEligible(accountID: UUID, apps: [AppRecord]) -> Bool {
        apps.contains { app in
            app.accountID == accountID && isLiveContainer(app)
        }
    }

    private static func isLiveContainer(_ app: AppRecord) -> Bool {
        let bundleID = app.originalBundleIdentifier.lowercased()
        return bundleID == "com.kdt.livecontainer" || bundleID.hasPrefix("com.kdt.livecontainer.")
    }
}
