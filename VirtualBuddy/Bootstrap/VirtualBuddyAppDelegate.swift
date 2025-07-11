//
//  VirtualBuddyNSApp.swift
//  VirtualBuddy
//
//  Created by Guilherme Rambo on 07/04/22.
//

import Cocoa
@_exported import VirtualCore
@_exported import VirtualUI
import VirtualWormhole
import DeepLinkSecurity
import OSLog
import Combine
import SwiftUI

#if BUILDING_NON_MANAGED_RELEASE
#error("Trying to build for release without using the managed scheme. This build won't include managed entitlements. This error is here for Rambo, you may safely comment it out and keep going.")
#endif

@MainActor
@objc final class VirtualBuddyAppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(for: VirtualBuddyAppDelegate.self)

    let settingsContainer = VBSettingsContainer.current
    let updateController = SoftwareUpdateController.shared
    let library = VMLibraryController()
    let sessionManager = VirtualMachineSessionUIManager.shared

    func applicationWillFinishLaunching(_ notification: Notification) {
        DeepLinkHandler.bootstrap(library: library)

        NSApp?.appearance = NSAppearance(named: .darkAqua)
    }

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        GuestAdditionsDiskImage.current.$state.sink { state in
            switch state {
            case .ready:
                self.logger.debug("Guest disk image ready")
            case .installing:
                self.logger.debug("Guest disk image installing")
            case .installFailed(let error):
                self.logger.debug("Guest disk image installation failed - \(error, privacy: .public)")
            }
        }
        .store(in: &cancellables)

        Task {
            try? await GuestAdditionsDiskImage.current.installIfNeeded()
        }

        #if DEBUG
        runLaunchDebugTasks()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let firstValidAssertion = sender.assertionsPreventingAppTermination.first {
            logger.debug("Preventing app termination due to active assertions: \(sender.assertionsPreventingAppTermination.map(\.reason).formatted(.list(type: .and)), privacy: .public)")

            let reply: NSApplication.TerminateReply

            if let assertionReply = firstValidAssertion.handleShouldTerminate() {
                logger.debug("Assertion handles should terminate, returning its reply \(assertionReply)")

                reply = assertionReply
            } else {
                logger.debug("Assertion doesn't handle should terminate, performing default handling")

                let alert = NSAlert()
                alert.messageText = "Quit VirtualBuddy?"
                alert.informativeText = "VirtualBuddy is currently \(firstValidAssertion.reason). This will be cancelled if you quit the app."

                let button = alert.addButton(withTitle: "Quit")
                button.hasDestructiveAction = true

                let button2 = alert.addButton(withTitle: "Quit When Done")
                button2.keyEquivalent = "\r"

                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()

                reply = switch response {
                case .alertFirstButtonReturn: .terminateNow
                case .alertSecondButtonReturn: .terminateLater
                default: .terminateCancel
                }
            }

            switch reply {
            case .terminateCancel:
                logger.info("User cancelled termination request. Good.")
            case .terminateNow:
                logger.info("User decided to terminate now despite assertions :(")
            case .terminateLater:
                logger.info("User wants app to terminate when assertions preventing termination are invalidated.")

                /// Note that there's  no point in resetting this to `false` in any other case because once `.terminateLater`
                /// has been returned from this method, any attempt to terminate the app will no longer trigger it.
                sender.shouldTerminateWhenLastAssertionInvalidated = true
            @unknown default:
                logger.fault("Unknown terminate reply \(reply, privacy: .public)")
            }

            return reply
        } else {
            return .terminateNow
        }
    }

    private var settingsWindow: NSWindow?

    private(set) lazy var openSettingsAction = OpenVirtualBuddySettingsAction { [weak self] in
        self?.openSettingsWindow()
    }

    private func openSettingsWindow() {
        if let settingsWindow {
            logger.debug("Settings window already available, showing")
            settingsWindow.makeKeyAndOrderFront(self)
            return
        }

        let rootView = SettingsScreen(
            enableAutomaticUpdates: updateController.automaticUpdatesBinding,
            deepLinkSentinel: DeepLinkHandler.shared.sentinel
        )
        .environmentObject(settingsContainer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsScreen.width, height: SettingsScreen.minHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)

        window.makeKeyAndOrderFront(self)
        window.center()

        self.settingsWindow = window
    }

}

extension NSWindow {
    /// At least as of macOS 14.4, a SwiftUI window's `identifier` matches the `id` that's set in SwiftUI.
    var isVirtualBuddyLibraryWindow: Bool { identifier?.rawValue == .vb_libraryWindowID }
}

#if DEBUG
// MARK: - Debugging Helpers

private extension VirtualBuddyAppDelegate {
    func runLaunchDebugTasks() {
        RunLoop.main.perform { [self] in
            MainActor.assumeIsolated {
                VirtualMachineSessionUIManager.shared.testImportVMIfEnabled(library: library)
            }
        }
    }
}
#endif
