import SwiftUI

/// Left-rail conversation picker. Shows the main room at the top and
/// each known peer below. Selecting an entry sets `navigation.active-
/// ConversationID`; the detail pane re-renders against the matching
/// `ConversationPoller`.
///
/// Collapsed by default — see `Navigation.sidebarVisibility`. The
/// roster comes from `IdentityRegistry`, which means peers only show
/// up after their `.identity` announcement has been pulled out of the
/// main room. Cold-launch users see only "Room" until at least one
/// poll cycle completes.
struct ConversationSidebar: View {
    @Environment(Navigation.self) private var navigation
    @Environment(SessionStore.self) private var session
    @Environment(IdentityRegistry.self) private var identityRegistry
    @Environment(MessageStore.self) private var store

    var body: some View {
        List(selection: Binding<String?>(
            get: { navigation.activeConversationID },
            set: { newValue in
                if let newValue {
                    navigation.activeConversationID = newValue
                }
            }
        )) {
            Section {
                row(
                    conversationID: ConversationID.room,
                    title: "Curviez",
                    subtitle: nil,
                    systemImage: "bubble.left.and.bubble.right.fill",
                    unread: store.poller(for: ConversationID.room)?.unreadCount ?? 0
                )
                .tag(ConversationID.room)
            } header: {
                Text("Group")
            }

            let myUserID = session.myUserID
            let peers = identityRegistry.roster(excluding: myUserID)
            if !peers.isEmpty, let myUserID {
                Section {
                    ForEach(peers, id: \.userID) { peer in
                        let convID = ConversationID.dm(myUserID, peer.userID)
                        row(
                            conversationID: convID,
                            title: peer.displayName,
                            subtitle: nil,
                            systemImage: "person.crop.circle.fill",
                            unread: store.poller(for: convID)?.unreadCount ?? 0
                        )
                        .tag(convID)
                    }
                } header: {
                    Text("Direct messages")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Curvy")
    }

    private func row(
        conversationID: String,
        title: String,
        subtitle: String?,
        systemImage: String,
        unread: Int
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.curvyBrand)
                    )
            }
        }
        .contentShape(Rectangle())
    }
}

