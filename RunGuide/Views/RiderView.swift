import SwiftUI
import RunGuideCore

/// The rider at a glance, top-trumps style, on one page with no scrolling: best power for the
/// chosen period (with medals where it ranks all time), thresholds, fitness, an estimated VO₂max
/// and the season so far. Below it, a launch pad into the rest of the app.
struct RiderView: View {
    @EnvironmentObject private var rider: RiderStore
    @EnvironmentObject private var library: ActivityLibrary
    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.switchTab) private var switchTab

    @AppStorage("riderPeriod") private var periodRaw = RiderPeriod.year.rawValue
    @State private var ranks: BestEffortRanks?
    @State private var showSettings = false
    @State private var showLibrary = false

    private var period: RiderPeriod { RiderPeriod(rawValue: periodRaw) ?? .year }

    var body: some View {
        NavigationStack {
            BrandScrollPage("Rider", onRefresh: { await refresh(force: true) }, showsFooter: false) {
                Picker("Period", selection: $periodRaw) {
                    ForEach(RiderPeriod.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } accessory: {
                HeaderButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
            } content: {
                if !settings.hasCredentials {
                    Button("Add your Intervals athlete ID and API key") { showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
                Card { card }
                launchPad
                if let error = rider.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.brand(.footnote)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rider")
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLibrary) { WorkoutLibraryView() }
            .task {
                guard settings.hasCredentials else { return }
                await refresh(force: false)
            }
        }
    }

    private func refresh(force: Bool) async {
        async let r: Void = rider.load(force: force)
        async let m = library.bestEffortRanks()
        let (_, medals) = await (r, m)
        ranks = medals
    }

    // MARK: - Card

    private var weight: Double? { rider.athlete?.weight ?? library.activities.first { $0.weight != nil }?.weight }
    private var source: ThresholdSource { settings.thresholdSource }
    private var other: ThresholdSource { source == .intervals ? .monument : .intervals }
    private var ftp: Double? { rider.ftp(source, intervalsFallback: library.latestFTP) }

    private func ftpText(_ s: ThresholdSource) -> String? {
        rider.ftp(s, intervalsFallback: library.latestFTP).map { "\(Int($0.rounded())) W" }
    }
    private func wPrimeText(_ s: ThresholdSource) -> String? {
        rider.wPrime(s).map { String(format: "%.1f kJ", $0 / 1000) }
    }
    private var efforts: [RiderEffort] { RiderCard.efforts(rider.curves[period.curve]) }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rider.athlete?.name ?? "Rider")
                        .font(.brand(.title2, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Best power · \(period.title.lowercased())")
                        .font(.brand(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ftpWkg.map { String(format: "%.2f", $0) } ?? "–.––")
                        .font(.hero(38))
                        .akiraSlant()
                        .foregroundStyle(Brand.wordmark)
                    Text(source == .monument ? "FTP W/kg · Monument" : "FTP W/kg")
                        .font(.brand(.caption2, weight: .medium)).foregroundStyle(.secondary)
                }
            }

            Hairline()

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(RiderCard.durations, id: \.self) { s in
                    tile(efforts.first { $0.seconds == s }, seconds: s)
                }
            }

            Hairline()

            HStack(alignment: .top) {
                stat("FTP", ftpText(source), also: ftpText(other).map { "\(other.label) \($0)" })
                stat("W′", wPrimeText(source), also: wPrimeText(other).map { "\(other.label) \($0)" })
                stat("CP", rider.monument.map { "\(Int($0.cp.rounded())) W" }, also: "Monument")
                stat("Pmax", rider.monument?.omni.map { "\(Int($0.pmax.rounded())) W" }, also: "Monument")
            }
            HStack(alignment: .top) {
                stat("Fitness", calendar.fitness?.ctl.map { "\(Int($0.rounded()))" })
                stat("Form", calendar.fitness?.form.map { v -> String in
                    let i = Int(v.rounded())
                    return i > 0 ? "+\(i)" : "\(i)"
                })
                stat("VO₂max est.", RiderCard.vo2max(fiveMinuteWatts: allTimeOrPeriod(300), weight: weight)
                    .map { String(format: "%.0f", $0) })
                stat("Weight", weight.map { String(format: "%.1f kg", $0) })
            }

            Hairline()

            VStack(alignment: .leading, spacing: 6) {
                Text("\(RiderStore.year) so far").font(.brand(.caption, weight: .bold)).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    stat("Hours", rider.totals.activities > 0 ? "\(Int((rider.totals.seconds / 3600).rounded()))" : nil)
                    stat("Ride km", rider.totals.rideMetres > 0
                         ? (rider.totals.rideMetres / 1000).formatted(.number.precision(.fractionLength(0))) : nil)
                    stat("Climbing", rider.totals.climbing > 0
                         ? rider.totals.climbing.formatted(.number.precision(.fractionLength(0))) + " m" : nil)
                    stat("Load", rider.totals.load > 0
                         ? rider.totals.load.formatted(.number.precision(.fractionLength(0))) : nil)
                }
            }
        }
    }

    private var ftpWkg: Double? {
        guard let ftp, let weight, weight > 0 else { return nil }
        return ftp / weight
    }

    /// The period's 5-minute best (VO₂max is estimated from the best you've shown in that span).
    private func allTimeOrPeriod(_ seconds: Int) -> Double? {
        efforts.first { $0.seconds == seconds }?.watts
    }

    /// A medal only where it says something: a 42-day best's place this year or all time, and a
    /// year best's place all time. All-time bests are records by definition.
    private func medal(for effort: RiderEffort) -> EffortMedal? {
        guard let id = effort.activity, let m = ranks?.medal(activity: id, seconds: effort.seconds) else { return nil }
        switch period {
        case .days42: return m
        case .year: return m.period == .allTime ? m : nil
        case .allTime: return nil
        }
    }

    private func tile(_ effort: RiderEffort?, seconds: Int) -> some View {
        let label = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.brand(.caption, weight: .bold)).foregroundStyle(.secondary)
                if let effort, let m = medal(for: effort) { MedalBadge(medal: m) }
                Spacer(minLength: 0)
            }
            Text(effort.map { "\(Int($0.watts.rounded()))" } ?? "–")
                .font(.num(.title, weight: .bold))
            + Text(effort == nil ? "" : " W").font(.brand(.subheadline, weight: .medium))
            Text(effort?.wattsPerKg(weight).map { String(format: "%.2f W/kg", $0) } ?? " ")
                .font(.num(.footnote))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: String?, also: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.brand(.caption2)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value ?? "–").font(.num(.subheadline, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let also {
                Text(also).font(.num(.caption2)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Launch pad

    private var launchPad: some View {
        HStack(spacing: 8) {
            pad("Calendar", "calendar") { switchTab(.calendar) }
            pad("Activities", "chart.xyaxis.line") { switchTab(.activities) }
            pad("Record", "record.circle") { switchTab(.record) }
            pad("Library", "books.vertical") { showLibrary = true }
            pad("Settings", "gearshape") { showSettings = true }
        }
    }

    private func pad(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19))
                Text(title).font(.brand(.caption2, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(Brand.wordmark)
            .overlay { Rectangle().strokeBorder(Brand.hairline, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
