import SwiftUI

@main
struct SMTP_Relay_for_MailjetApp: App {
    @State private var relayManager = RelayManager()
    @AppStorage("smtpPort") private var port = 2525
    @AppStorage("hideDockIcon") private var hideDockIcon = false

    var body: some Scene {
        WindowGroup {
            ContentView(relayManager: relayManager)
                .onAppear {
                    if hideDockIcon {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            menuContent
        } label: {
            Image(systemName: relayManager.isRunning ? "envelope.fill" : "envelope")
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuContent: some View {
        if relayManager.isRunning {
            Text("Running on port \(port)")
            Text("Relayed: \(relayManager.messagesRelayed) | Failed: \(relayManager.messagesFailed)")
            if !relayManager.retryQueue.isEmpty {
                Text("\(relayManager.retryQueue.count) pending retries")
            }
            Divider()
            Button("Stop Server") {
                relayManager.stopServer()
            }
        } else {
            Text("Server stopped")
            Divider()
            Button("Start Server") {
                relayManager.startServer(port: UInt16(clamping: port))
            }
        }

        Divider()

        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
