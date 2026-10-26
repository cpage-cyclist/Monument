import SwiftUI
import RunGuideCore

/// Three-second log: RPE, feel and a one-line note, with optional wellness fields.
/// Saves RPE/feel/note to the activity and wellness to that day in Intervals.
struct QuickLogView: View {
    let activity: ActivitySummary
    /// When set, the sheet was opened from the "how did it feel?" prompt and offers "Not now".
    var fromPrompt = false
    var onSaved: () -> Void = {}

    @EnvironmentObject private var library: ActivityLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("quickLogShowWellness") private var showWellness = false

    @State private var rpe: Double = 5
    @State private var feel: Int?
    @State private var note = ""
    @State private var carbs = ""
    @State private var sleep = ""
    @State private var soreness: Int?
    @State private var weight = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Int(rpe))")
                                .font(.num(size: 44))
                            Text(Self.rpeWord(Int(rpe)))
                                .font(.brand(.title3))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $rpe, in: 1...10, step: 1)
                            .accessibilityLabel("RPE")
                            .accessibilityValue("\(Int(rpe)), \(Self.rpeWord(Int(rpe)))")
                    }
                } header: {
                    Text("RPE")
                }

                Section("Feel") {
                    HStack(spacing: 6) {
                        // Intervals' scale: 1 strong … 5 weak.
                        ForEach(1...5, id: \.self) { value in
                            Button {
                                feel = (feel == value) ? nil : value
                            } label: {
                                Text(SummaryGrid.feelLabel(value))
                                    .font(.brand(.subheadline, weight: feel == value ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(feel == value ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill),
                                                in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Carbs")
                        Spacer()
                        TextField("g/h", text: $carbs)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("g/h").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(carbsFooter)
                }

                Section {
                    TextField("One-line note (optional)", text: $note)
                        .submitLabel(.done)
                } footer: {
                    Text("Added under the activity's existing notes.")
                }

                Section {
                    Toggle("Wellness", isOn: $showWellness.animation())
                    if showWellness {
                        HStack {
                            Text("Sleep")
                            Spacer()
                            TextField("hours", text: $sleep)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                        Picker("Soreness", selection: $soreness) {
                            Text("–").tag(Int?.none)
                            // Intervals' scale: 1 low … 4 extreme.
                            Text("Low").tag(Int?.some(1))
                            Text("Avg").tag(Int?.some(2))
                            Text("High").tag(Int?.some(3))
                            Text("Extreme").tag(Int?.some(4))
                        }
                        HStack {
                            Text("Weight")
                            Spacer()
                            TextField("kg", text: $weight)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }
                } footer: {
                    if showWellness { Text("Saved to \(dayText) in Intervals. Leave blank to skip.") }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.brand(.footnote))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(activity.name ?? "Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(fromPrompt ? "Not now" : "Cancel") {
                        if fromPrompt { library.dismissLogPrompt(for: activity) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                if let existing = activity.rpe { rpe = Double(min(max(existing, 1), 10)) }
                feel = activity.feel
                if let rate = activity.carbsPerHour { carbs = String(Int(rate.rounded())) }
            }
        }
        .presentationDetents(showWellness ? [.large] : [.medium, .large])
    }

    private var carbsFooter: String {
        guard let rate = Self.number(carbs),
              let total = ActivityLog.carbs(perHour: rate, movingTime: activity.movingTime),
              let t = activity.movingTime else {
            return "Optional. Saved to Intervals as total grams over the moving time."
        }
        return "≈ \(Int(total)) g over \(Format.clock(t)) moving, saved to Intervals."
    }

    private var dayText: String {
        guard let date = activity.startDate else { return "that day" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        let wellness = showWellness
            ? WellnessLog(sleepHours: Self.number(sleep), soreness: soreness, weightKg: Self.number(weight))
            : WellnessLog()
        do {
            try await library.log(activity, rpe: Int(rpe), feel: feel, note: note,
                                  carbsPerHour: Self.number(carbs), wellness: wellness)
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Accepts "7.5" or "7,5".
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    static func rpeWord(_ rpe: Int) -> String {
        switch rpe {
        case ...2: return "Very easy"
        case 3...4: return "Easy"
        case 5...6: return "Moderate"
        case 7...8: return "Hard"
        case 9: return "Very hard"
        default: return "Max"
        }
    }
}

/// The "how did it feel?" card at the top of Activities.
struct LogPromptCard: View {
    let activity: ActivitySummary
    let onLog: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.pencil")
                .font(.brand(.title3))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("How did \(activity.name ?? "it") feel?")
                    .font(.brand(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Text("Add RPE and feel")
                    .font(.brand(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Log", action: onLog)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not now")
        }
    }
}
