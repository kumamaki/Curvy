import SwiftData
import SwiftUI

@main
struct CurvyApp: App {
    @State private var session = SessionStore()
    @State private var messages: MessageStore
    private let modelContainer: ModelContainer

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
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 720)
    }
}

