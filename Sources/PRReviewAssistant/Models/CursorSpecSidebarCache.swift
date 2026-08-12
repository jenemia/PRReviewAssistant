import Foundation

struct CursorSpecSidebarCache: Codable, Equatable, Sendable {
    static let maximumVisibleCount = 5
    static let maximumPinnedCount = 4

    private(set) var visibleNames: [String]
    private(set) var pinnedNames: [String]
    private(set) var recentlyActivatedNames: [String]
    private(set) var dismissedLatestSessionAt: [String: Date]
    private(set) var observedLatestSessionAt: [String: Date]

    init(
        visibleNames: [String] = [],
        pinnedNames: [String] = [],
        recentlyActivatedNames: [String] = [],
        dismissedLatestSessionAt: [String: Date] = [:],
        observedLatestSessionAt: [String: Date] = [:]
    ) {
        self.visibleNames = visibleNames
        self.pinnedNames = pinnedNames
        self.recentlyActivatedNames = recentlyActivatedNames
        self.dismissedLatestSessionAt = dismissedLatestSessionAt
        self.observedLatestSessionAt = observedLatestSessionAt
    }

    mutating func reconcile(latestSessionAtByName latestDates: [String: Date]) {
        let availableNames = Set(latestDates.keys)
        visibleNames = unique(visibleNames).filter(availableNames.contains)
        pinnedNames = unique(pinnedNames).filter { availableNames.contains($0) && visibleNames.contains($0) }
        recentlyActivatedNames = unique(recentlyActivatedNames).filter(availableNames.contains)

        let changedNames = latestDates.compactMap { name, latestDate -> String? in
            let wasUpdated = observedLatestSessionAt[name].map { latestDate > $0 } ?? true
            let isStillDismissed = dismissedLatestSessionAt[name].map { latestDate <= $0 } ?? false
            return wasUpdated && !isStillDismissed ? name : nil
        }

        for name in changedNames where !visibleNames.contains(name) {
            visibleNames.append(name)
        }
        for name in changedNames.sorted(by: { (latestDates[$0] ?? .distantPast) < (latestDates[$1] ?? .distantPast) }) {
            dismissedLatestSessionAt.removeValue(forKey: name)
            touch(name)
        }

        observedLatestSessionAt = latestDates
        dismissedLatestSessionAt = dismissedLatestSessionAt.filter { availableNames.contains($0.key) }
        orderAndTrim(latestDates: latestDates, protectedNames: Set(changedNames))
    }

    @discardableResult
    mutating func activate(_ name: String, latestSessionAtByName latestDates: [String: Date]) -> Bool {
        guard latestDates[name] != nil else { return false }
        dismissedLatestSessionAt.removeValue(forKey: name)
        if !visibleNames.contains(name) {
            visibleNames.append(name)
        }
        touch(name)
        observedLatestSessionAt[name] = latestDates[name]
        orderAndTrim(latestDates: latestDates, protectedNames: [name])
        return visibleNames.contains(name)
    }

    mutating func close(_ name: String, latestSessionAt: Date?) {
        visibleNames.removeAll { $0 == name }
        pinnedNames.removeAll { $0 == name }
        recentlyActivatedNames.removeAll { $0 == name }
        if let latestSessionAt {
            dismissedLatestSessionAt[name] = latestSessionAt
            observedLatestSessionAt[name] = latestSessionAt
        }
    }

    @discardableResult
    mutating func togglePinned(_ name: String, latestSessionAtByName latestDates: [String: Date]) -> Bool {
        guard visibleNames.contains(name) else { return false }
        if pinnedNames.contains(name) {
            pinnedNames.removeAll { $0 == name }
        } else {
            guard pinnedNames.count < Self.maximumPinnedCount else { return false }
            pinnedNames.append(name)
        }
        orderAndTrim(latestDates: latestDates, protectedNames: [name])
        return true
    }

    func isPinned(_ name: String) -> Bool {
        pinnedNames.contains(name)
    }

    func canPin(_ name: String) -> Bool {
        isPinned(name) || pinnedNames.count < Self.maximumPinnedCount
    }

    private mutating func orderAndTrim(latestDates: [String: Date], protectedNames: Set<String>) {
        let availableNames = Set(latestDates.keys)
        let pinned = unique(pinnedNames)
            .filter { availableNames.contains($0) && visibleNames.contains($0) }
            .prefix(Self.maximumPinnedCount)
        pinnedNames = Array(pinned)

        let pinnedSet = Set(pinnedNames)
        let sortedNonPinned = unique(visibleNames)
            .filter { availableNames.contains($0) && !pinnedSet.contains($0) }
            .sorted { lhs, rhs in
                let leftDate = latestDates[lhs] ?? .distantPast
                let rightDate = latestDates[rhs] ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        let capacity = max(0, Self.maximumVisibleCount - pinnedNames.count)
        let recencyOrder = recentlyActivatedNames + sortedNonPinned.filter { !recentlyActivatedNames.contains($0) }
        let protected = recencyOrder.filter { protectedNames.contains($0) && sortedNonPinned.contains($0) }
        let remaining = recencyOrder.filter { !protectedNames.contains($0) && sortedNonPinned.contains($0) }
        let admitted = Array((protected + remaining).prefix(capacity))
        let admittedSet = Set(admitted)
        let displayedNonPinned = sortedNonPinned.filter(admittedSet.contains)
        visibleNames = pinnedNames + displayedNonPinned
    }

    private mutating func touch(_ name: String) {
        recentlyActivatedNames.removeAll { $0 == name }
        recentlyActivatedNames.insert(name, at: 0)
    }

    private func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
