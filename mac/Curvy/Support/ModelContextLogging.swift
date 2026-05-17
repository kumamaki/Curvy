import Foundation
import SwiftData

/// Diagnostic helper around `ModelContext.save()`. Logs the dirty-set size
/// (inserted/changed/deleted) plus elapsed milliseconds via `AppLog.store`,
/// and surfaces any thrown error instead of silently swallowing it.
///
/// Wired in while hunting the "freeze grows with idle time" bug —
/// every save site routes through this so `just logs store` shows
/// exactly which call accumulated work and how long the flush took.
@MainActor
extension ModelContext {
    func savePub(_ label: StaticString) {
        let inserted = insertedModelsArray.count
        let changed = changedModelsArray.count
        let deleted = deletedModelsArray.count
        let start = DispatchTime.now()
        do {
            try save()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            AppLog.store.pub("save[\(label)] ins=<\(inserted)> chg=<\(changed)> del=<\(deleted)> elapsed=<\(String(format: "%.1f", ms))ms>")
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            AppLog.store.error("save[\(label, privacy: .public)] FAILED ins=<\(inserted)> chg=<\(changed)> del=<\(deleted)> elapsed=<\(String(format: "%.1f", ms))ms> err=<\(String(describing: error), privacy: .public)>")
        }
    }
}
