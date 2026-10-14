import SwiftUI
import AppKit
import DottieKit

/// Tells people when a newer Dottie is on GitHub. It never downloads or installs anything: a Homebrew install
/// is told the `brew upgrade` command, anyone else gets the release page.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let interval: TimeInterval = 24 * 60 * 60
    private var checking = false

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? DottieVersion.current
    }

    /// Installed by `brew install --cask`, so updates should go through brew to keep its record right.
    private var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/dottie", "/usr/local/Caskroom/dottie"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// The automatic check: at most once a day, when the setting is on, quiet unless there is an update.
    /// Debug builds skip it so working on Dottie does not keep asking.
    func checkIfDue() {
        #if DEBUG
        return
        #else
        guard Pref.bool(Pref.checkForUpdates, default: true) else { return }
        let last = UserDefaults.standard.double(forKey: Pref.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        Task { await check(userInitiated: false) }
        #endif
    }

    /// Check for Updates…: also says when Dottie is up to date or the check failed.
    func check(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let release: LatestRelease
        do {
            release = try await fetchLatest()
        } catch {
            if userInitiated { show("Couldn't check for updates", error.localizedDescription) }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Pref.lastUpdateCheck)
        guard let newer = release.newer(than: currentVersion) else {
            if userInitiated { show("Dottie is up to date", "You have version \(currentVersion), the latest.") }
            return
        }
        if !userInitiated, UserDefaults.standard.string(forKey: Pref.skippedUpdate) == newer.description { return }
        offer(newer, release)
    }

    private func fetchLatest() async throws -> LatestRelease {
        var request = URLRequest(url: LatestRelease.endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dottie/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LatestRelease.self, from: data)
    }

    private func offer(_ version: ReleaseVersion, _ release: LatestRelease) {
        let alert = NSAlert()
        alert.messageText = "Dottie \(version) is available"
        let command = "brew upgrade --cask dottie"
        if installedWithHomebrew {
            alert.informativeText = "You have version \(currentVersion). You installed Dottie with Homebrew, so update it in Terminal with:\n\n\(command)"
            alert.addButton(withTitle: "Copy Command")
        } else {
            alert.informativeText = "You have version \(currentVersion). Download the new version and replace Dottie in your Applications folder."
            alert.addButton(withTitle: "Download")
        }
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installedWithHomebrew {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } else {
                NSWorkspace.shared.open(release.pageURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version.description, forKey: Pref.skippedUpdate)
        default:
            break
        }
    }

    private func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
