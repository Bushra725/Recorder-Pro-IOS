import Foundation
import StoreKit
import UIKit

/// Port of Android's `engagement/Engagement.kt`: streaks, nine achievements,
/// a small daily PRO bonus, and the review prompt.
@MainActor
final class Engagement: ObservableObject {
    static let shared = Engagement()

    enum Event: Equatable {
        case achievementUnlocked(Achievement)
        case streakExtended(Int)
        case dailyBonus(Int)
    }

    struct Achievement: Identifiable, Equatable {
        let id: String
        let titleKey: String
        let descKey: String
        let emoji: String
    }

    static let all: [Achievement] = [
        Achievement(id: "first_take", titleKey: "ach_first_take", descKey: "ach_first_take_d", emoji: "🎬"),
        Achievement(id: "five_takes", titleKey: "ach_five_takes", descKey: "ach_five_takes_d", emoji: "🎞️"),
        Achievement(id: "twenty_takes", titleKey: "ach_twenty_takes", descKey: "ach_twenty_takes_d", emoji: "📽️"),
        Achievement(id: "hour_total", titleKey: "ach_hour_total", descKey: "ach_hour_total_d", emoji: "⏱️"),
        Achievement(id: "long_take", titleKey: "ach_long_take", descKey: "ach_long_take_d", emoji: "🏃"),
        Achievement(id: "streak_3", titleKey: "ach_streak_3", descKey: "ach_streak_3_d", emoji: "🔥"),
        Achievement(id: "streak_7", titleKey: "ach_streak_7", descKey: "ach_streak_7_d", emoji: "⚡"),
        Achievement(id: "editor", titleKey: "ach_editor", descKey: "ach_editor_d", emoji: "✂️"),
        Achievement(id: "ai_editor", titleKey: "ach_ai_editor", descKey: "ach_ai_editor_d", emoji: "✨")
    ]

    @Published var event: Event?
    @Published private(set) var revision = 0

    private let prefs = Prefs.shared

    func isUnlocked(_ id: String) -> Bool { prefs.achievements.contains(id) }

    private func unlock(_ id: String) {
        guard !prefs.achievements.contains(id) else { return }
        prefs.achievements = prefs.achievements.union([id])
        if let a = Self.all.first(where: { $0.id == id }) {
            SoundFx.reward()
            event = .achievementUnlocked(a)
        }
        revision += 1
    }

    // MARK: - Calendar days, compared as yyyyMMdd on the local calendar

    private static func day(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private var today: Int { Self.day(Date()) }
    private var yesterday: Int { Self.day(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()) }

    // MARK: - Hooks

    func onRecordingFinished(durationMs: Int64) {
        prefs.totalRecordings += 1
        prefs.totalRecordedMs += durationMs

        let t = today
        if prefs.lastActiveDay == t {
            // already counted today
        } else if prefs.lastActiveDay == yesterday {
            prefs.streakDays += 1
            prefs.lastActiveDay = t
            prefs.bestStreakDays = max(prefs.bestStreakDays, prefs.streakDays)
            event = .streakExtended(prefs.streakDays)
        } else {
            prefs.streakDays = 1
            prefs.lastActiveDay = t
            prefs.bestStreakDays = max(prefs.bestStreakDays, 1)
        }

        if prefs.totalRecordings >= 1 { unlock("first_take") }
        if prefs.totalRecordings >= 5 { unlock("five_takes") }
        if prefs.totalRecordings >= 20 { unlock("twenty_takes") }
        if prefs.totalRecordedMs >= 3_600_000 { unlock("hour_total") }
        if durationMs >= 600_000 { unlock("long_take") }
        if prefs.streakDays >= 3 { unlock("streak_3") }
        if prefs.streakDays >= 7 { unlock("streak_7") }
        revision += 1
    }

    func onEditCompleted() {
        prefs.editsCompleted += 1
        unlock("editor")
    }

    func onAiEditCompleted() { unlock("ai_editor") }

    // MARK: - Daily bonus

    var dailyBonusAvailable: Bool {
        !prefs.isPro && prefs.lastDailyClaimDay != today
    }

    var dailyBonusHours: Int {
        prefs.streakDays >= 7 ? 6 : prefs.streakDays >= 3 ? 4 : 2
    }

    @discardableResult
    func claimDailyBonus() -> Int {
        guard dailyBonusAvailable else { return 0 }
        let hours = dailyBonusHours
        prefs.lastDailyClaimDay = today
        Store.shared.grantUnlock(seconds: TimeInterval(hours * 3600))
        SoundFx.reward()
        event = .dailyBonus(hours)
        revision += 1
        return hours
    }

    // MARK: - Review prompt
    //
    // Android shows its own 5-star dialog. App Review does not allow a custom
    // pre-prompt that routes only happy users to the store (guideline 5.6.1),
    // so iOS uses the system prompt, once, after the app has been useful:
    // 5 saved recordings and at least one achievement — the same bar Android's
    // README sets.

    func maybeRequestReview() {
        guard !prefs.reviewRequested,
              prefs.totalRecordings >= 5,
              !prefs.achievements.isEmpty,
              let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        prefs.reviewRequested = true
        SKStoreReviewController.requestReview(in: scene)
    }

    // MARK: - Summary

    struct Stats {
        let recordings: Int
        let totalMs: Int64
        let streak: Int
        let bestStreak: Int
        let achievements: Int
        let achievementsTotal: Int
    }

    var stats: Stats {
        Stats(recordings: prefs.totalRecordings, totalMs: prefs.totalRecordedMs,
              streak: prefs.streakDays, bestStreak: prefs.bestStreakDays,
              achievements: prefs.achievements.count, achievementsTotal: Self.all.count)
    }
}
