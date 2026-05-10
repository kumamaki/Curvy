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
    // Must be a stored `@State` — Sparkle stops the updater if this is released.
    @State private var updateMonitor = UpdateMonitor()

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Schema([CachedMessage.self]),
                migrationPlan: CachedMessageMigrationPlan.self,
                configurations: [ModelConfiguration()]
            )
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
                .environment(updateMonitor)
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
                    async let _ = Notifier.live.requestAuthorization()
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
                    updateMonitor.checkForUpdates()
                }
            }
            CommandGroup(before: .appTermination) {
                Divider()
                Button("Sign Out") {
                    session.signOut()
                }
                .disabled(session.currentInvite == nil)
            }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 720)
    }
}

