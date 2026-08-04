import SwiftUI

struct MenuBarView: View {
    let store: ReviewStore

    var body: some View {
        Text(store.unreadCount == 0 ? "확인하지 않은 새 항목이 없습니다" : "읽지 않은 PR \(store.unreadCount)개")
        Divider()
        ForEach(store.pullRequests.prefix(3)) { pullRequest in
            Button {
                store.markPullRequestRead(pullRequest)
            } label: {
                HStack(spacing: 7) {
                    if store.isUnread(pullRequest) { Circle().fill(.red).frame(width: 8, height: 8) }
                    Text("#\(pullRequest.number)  \(pullRequest.title)")
                        .lineLimit(1)
                }
            }
        }
        Divider()
        Button("업데이트 확인") {
            Task { await store.checkForAppUpdate() }
        }
        .disabled(store.isCheckingForAppUpdate || !store.updateRepositoryIsValid)
        if store.isCheckingForAppUpdate {
            Text("업데이트를 확인하는 중입니다…")
                .foregroundStyle(.secondary)
        }
        Button("새로 고침") { store.refresh() }
        Button("종료") { NSApplication.shared.terminate(nil) }
    }
}
