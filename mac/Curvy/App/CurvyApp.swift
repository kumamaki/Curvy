import Sparkle
import SwiftData
import SwiftUI
import UserNotifications

@main
struct CurvyApp: App {
    @State private var session = SessionStore()
    @State private var messages: MessageStore
    @State private var identityRegistry: IdentityRegistry
    @State private var notificationDelegate = NotificationDelegate()
    private let modelContainer: ModelContainer
    // Must be a stored `@State` — Sparkle stops the updater if this is released.
    @State private var updateMonitor = UpdateMonitor()

    init() {
        // Debug and Release builds share the bundle ID, so without an
        // explicit store name they'd share the same SwiftData file.
        // That contaminates Debug with Release-room messages (and vice
        // versa) — visually the wrong room, even though polling/posting
        // is correctly gated by `RoomConfig.issueNumber`. Naming the
        // store gives each build its own file at the default location.
        #if DEBUG
        let modelConfig = ModelConfiguration("CurvyCache-Debug")
        #else
        // Unnamed = SwiftData's default store filename. Keep this as-is
        // even if we rename Debug — renaming Release would orphan
        // friends' existing local caches and force a one-time reseed
        // from Issue #1's comment history on next launch.
        let modelConfig = ModelConfiguration()
        #endif

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: Schema([CachedMessage.self, CachedIdentity.self, CachedConversation.self]),
                migrationPlan: CachedMessageMigrationPlan.self,
                configurations: [modelConfig]
            )
        } catch {
            fatalError("Could not create ModelContainer for Curvy schema: \(error)")
        }
        self.modelContainer = container
        // Autosave fires a runloop timer that calls DefaultStore.save →
        // performAndWait on the MOC queue. After long inactivity (Mac sleep,
        // scene backgrounded, error backoff stretched to 300s) the dirty set
        // accumulates from BlobFetcher.materialize's unsaved `imageCachedAt`
        // bumps, and one autosave tick eventually wedges inside
        // DefaultSnapshot.encode → swift_dynamicCast and never returns,
        // parking the main thread in performAndWait. We already call
        // modelContext.save() explicitly at every meaningful boundary, so
        // autosave is duplicative.
        container.mainContext.autosaveEnabled = false
        let registry = IdentityRegistry(modelContext: container.mainContext)
        self._identityRegistry = State(initialValue: registry)
        self._messages = State(initialValue: MessageStore(
            modelContext: container.mainContext,
            identityRegistry: registry
        ))
    }

    var body: some Scene {
        WindowGroup("Curvy") {
            RootView()
                .environment(session)
                .environment(messages)
                .environment(identityRegistry)
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
                        let identity = session.identity(displayName: messages.displayName)
                        messages.start(
                            invite: invite,
                            identity: identity,
                            privateKey: session.myPrivateKey
                        )
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

