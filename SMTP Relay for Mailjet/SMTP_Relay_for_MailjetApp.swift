import SwiftUI

@main
struct SMTP_Relay_for_MailjetApp: App {
    @State private var relayManager = RelayManager()
    @AppStorage("smtpPort") private var port = 2525
    @AppStorage("hideDockIcon") private var hideDockIcon = false

    var body: some Scene {
        Window("SMTP Relay for Mailjet", id: "main") {
            ContentView(relayManager: relayManager)
                .onAppear {
                    if hideDockIcon {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent(relayManager: relayManager, port: port)
        } label: {
            Image(systemName: relayManager.isRunning ? "envelope.fill" : "envelope")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    let relayManager: RelayManager
    let port: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if relayManager.isRunning {
            Text("Running on port \(port, format: .number.grouping(.never))")
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
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
