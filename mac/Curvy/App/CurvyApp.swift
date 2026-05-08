import Sparkle
import SwiftData
import SwiftUI
import UserNotifications

@main
struct CurvyApp: App {
    @State private var session = SessionStore()
    @State private var messages: MessageStore
    @State private var notificationDelegate = NotificationDelegate()
    private let modelContainer: ModelContainer
    // Sparkle: must be a stored `let` — discarding this stops the updater.
    // Unsigned builds (CI) can check and prompt but cannot auto-install
    // because the sandbox XPC handoff requires a signed host app.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: CachedMessage.self)
        } catch {
            fatalError("Could not create ModelContainer for CachedMessage: \(error)")
        }
        self.modelContainer = container
        self._messages = State(initialValue: MessageStore(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup("Curvy") {
            RootView()
                .environment(session)
                .environment(messages)
                .modelContainer(modelContainer)
                .tint(Color.curvyBrand)
                .frame(minWidth: 520, minHeight: 480)
                .task {
                    let center = UNUserNotificationCenter.current()
                    center.delegate = notificationDelegate
                    NotificationDelegate.registerCategories()
                    notificationDelegate.onReply = { [messages] text, replyTo in
                        try? await messages.send(text: text, replyTo: replyTo)
                    }
                    await session.bootstrap()
                }
                .task(id: session.currentInvite?.token) {
                    // Toggle polling whenever the active invite changes.
                    // Keying on the PAT is enough — friend rotations
                    // produce a new PAT, sign-out nils it out.
                    if let invite = session.currentInvite {
                        messages.start(invite: invite)
                    } else {
                        messages.stop()
                    }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.updater.checkForUpdates()
                }
            }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 720)
    }
}

