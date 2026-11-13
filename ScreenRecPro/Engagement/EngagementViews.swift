import SwiftUI

/// Compact stats strip on the Video tab, plus the daily bonus card.
/// Hidden for a brand-new user (Android's EngagementStrip).
struct EngagementStrip: View {
    let onOpenAchievements: () -> Void
    @ObservedObject private var engagement = Engagement.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        let s = engagement.stats
        VStack(spacing: 8) {
            if engagement.dailyBonusAvailable && !store.hasPro {
                Button { engagement.claimDailyBonus() } label: {
                    HStack(spacing: 12) {
                        Text("🎁").font(.title)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("daily_bonus_title")).font(.subheadline.bold())
                            Text(s.streak >= 3 ? L("daily_bonus_streak", s.streak) : L("daily_bonus_body"))
                                .font(.caption).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Text(L("claim")).font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.white.opacity(0.25), in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            if s.recordings > 0 {
                Button(action: onOpenAchievements) {
                    HStack {
                        stat("🔥", "\(s.streak)", L("stat_streak"))
                        stat("🎬", "\(s.recordings)", L("stat_recordings"))
                        stat("⏱️", Format.duration(s.totalMs), L("stat_total_time"))
                        stat("🏆", "\(s.achievements)/\(s.achievementsTotal)", L("stat_awards"))
                    }
                    .padding(.vertical, 8)
                    .card()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .id(engagement.revision)
    }

    private func stat(_ emoji: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(emoji) \(value)").font(.subheadline.bold()).foregroundStyle(Brand.text)
            Text(label).font(.caption2).foregroundStyle(Brand.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Trophy grid. Locked entries stay visible — a list of things you could earn
/// is a reason to come back.
struct AchievementsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engagement = Engagement.shared
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                let s = engagement.stats
                HStack {
                    VStack { Text("🔥 \(s.streak)").font(.title2.bold()); Text(L("streak_days", s.streak)).font(.caption) }
                        .frame(maxWidth: .infinity)
                    VStack { Text("🏅").font(.title2); Text(L("best_streak", s.bestStreak)).font(.caption) }
                        .frame(maxWidth: .infinity)
                }
                .padding()
                .card()
                .padding()

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Engagement.all) { a in
                        let unlocked = engagement.isUnlocked(a.id)
                        VStack(spacing: 6) {
                            Text(a.emoji).font(.system(size: 36))
                                .grayscale(unlocked ? 0 : 1)
                                .opacity(unlocked ? 1 : 0.35)
                            Text(L(a.titleKey)).font(.caption.bold()).multilineTextAlignment(.center)
                            Text(L(a.descKey)).font(.caption2).foregroundStyle(Brand.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 130)
                        .card()
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle(L("achievements"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("close")) { dismiss() } } }
        }
    }
}

/// Floating toast card for achievement / streak / bonus events.
struct EngagementEventHost: View {
    @ObservedObject private var engagement = Engagement.shared

    var body: some View {
        Group {
            if let event = engagement.event {
                HStack(spacing: 12) {
                    Text(emoji(event)).font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(event)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                        Text(message(event)).font(.headline).foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(radius: 10, y: 6)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { engagement.event = nil }
                .task(id: event) {
                    try? await Task.sleep(nanoseconds: 3_200_000_000)
                    withAnimation { engagement.event = nil }
                }
            }
        }
        .animation(.spring(), value: engagement.event)
    }

    private func emoji(_ e: Engagement.Event) -> String {
        switch e {
        case .achievementUnlocked(let a): return a.emoji
        case .streakExtended: return "🔥"
        case .dailyBonus: return "🎁"
        }
    }

    private func title(_ e: Engagement.Event) -> String {
        switch e {
        case .achievementUnlocked: return L("achievement_unlocked")
        case .streakExtended: return L("streak_extended")
        case .dailyBonus: return L("bonus_claimed")
        }
    }

    private func message(_ e: Engagement.Event) -> String {
        switch e {
        case .achievementUnlocked(let a): return L(a.titleKey)
        case .streakExtended(let d): return L("streak_days", d)
        case .dailyBonus(let h): return L("bonus_hours", h)
        }
    }
}
