import SwiftUI

/// Settings section for bridge-side scheduled tasks ("weekdays at 9: run the
/// tests"). They fire on the computer's clock and behave like any other turn —
/// completion push, approval pushes if grok asks.
/// The same section as its own screen. Schedules used to be reachable only by
/// scrolling Settings, which is a strange place to keep the thing that runs your
/// work while you are asleep.
struct SchedulesSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SchedulesSection(showsHeading: false)
                    .environmentObject(app)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Grok.gutter).padding(.vertical, 20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .navigationTitle(Text("Schedules"))
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(Grok.sans(16, .semibold)).tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SchedulesSection: View {
    /// False when the screen presenting this already carries the name, so the section
    /// does not say it twice.
    var showsHeading = true
    @EnvironmentObject var app: AppState
    @State private var schedules: [BridgeSchedule]?
    @State private var adding = false
    @State private var errorText: String?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading { Eyebrow("SCHEDULED TASKS") }

            if let schedules, !schedules.isEmpty {
                ForEach(schedules) { s in row(s) }
            } else if schedules != nil {
                Text("Run a prompt automatically — every morning, weekdays, whenever.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textDim).lineSpacing(2)
            } else if loadFailed {
                // "nil forever" looked like schedules had been deleted; say what happened.
                Text("Couldn't load schedules — the bridge may need an update.")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
            } else if app.client != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Loading…").font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                }
                .accessibilityElement(children: .combine)
            }
            if let errorText {
                Text(errorText).font(Grok.sans(14)).foregroundStyle(Grok.danger)
            }

            Button { Haptics.tap(); adding = true } label: {
                Label("Add a scheduled task", systemImage: "clock.badge.plus")
            }
            .buttonStyle(PillButton(kind: .subtle))
            .disabled(app.sessions.isEmpty)
            if app.sessions.isEmpty {
                Text("Create a session first — a schedule runs inside one.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            }
            Text("Runs on your computer's clock, even with this phone off. You'll get a push when it finishes.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
        .task { await load() }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            ScheduleEditorSheet().environmentObject(app)
        }
    }

    private func row(_ s: BridgeSchedule) -> some View {
        let sessionName = app.sessions.first(where: { $0.id == s.sessionId })?.displayName
            ?? String(localized: "session")
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.prompt).font(Grok.sans(15)).foregroundStyle(Grok.text).lineLimit(2)
                Text("\(s.timeLabel) · \(s.daysLabel) · \(sessionName)")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            }
            Spacer(minLength: 8)
            Toggle(s.prompt, isOn: Binding(
                get: { s.enabled },
                set: { on in Task { await setEnabled(s, on) } }
            )).labelsHidden().tint(.white)
            Button {
                Task { await remove(s) }
            } label: {
                Image(systemName: "minus.circle").font(.caption)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(Grok.textDim)
            .accessibilityLabel(Text("Remove schedule"))
        }
        .padding(.horizontal, Grok.pad).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            schedules = try await client.listSchedules()
            loadFailed = false
        } catch {
            loadFailed = schedules == nil    // keep showing a stale list over an error
        }
    }

    private func setEnabled(_ s: BridgeSchedule, _ on: Bool) async {
        guard let client = app.client else { return }
        do {
            try await client.setScheduleEnabled(s.id, enabled: on)
            if let i = schedules?.firstIndex(where: { $0.id == s.id }) { schedules?[i].enabled = on }
        } catch { errorText = String(localized: "Couldn't update that schedule.") }
    }

    private func remove(_ s: BridgeSchedule) async {
        guard let client = app.client else { return }
        do {
            try await client.deleteSchedule(s.id)
            schedules?.removeAll { $0.id == s.id }
        } catch { errorText = String(localized: "Couldn't delete that schedule.") }
    }
}

/// Compose a new scheduled task: which session, what prompt, when.
struct ScheduleEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sessionId: String?
    @State private var prompt = ""
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]   // 0=Sun … 6=Sat
    @State private var saving = false
    @State private var errorText: String?

    private var selectedSession: SessionInfo? {
        app.sessions.first(where: { $0.id == sessionId }) ?? app.sessions.first
    }
    private var daySymbols: [String] { Calendar.current.veryShortWeekdaySymbols }   // Sun-first
    private var dayNames: [String] { Calendar.current.weekdaySymbols }              // Sun-first, for VoiceOver

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("SESSION")
                        Menu {
                            ForEach(app.sessions) { s in
                                Button(s.displayName) { sessionId = s.id }
                            }
                        } label: {
                            HStack {
                                // Two cases, not one coalesced String: a String reaches
                                // Text through the verbatim initializer, so the
                                // placeholder would have stayed English everywhere.
                                (selectedSession.map { Text($0.displayName) } ?? Text("choose…"))
                                    .font(Grok.sans(16)).foregroundStyle(Grok.text).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11)).foregroundStyle(Grok.textFaint)
                            }
                            .padding(.horizontal, Grok.pad).padding(.vertical, 12)
                            .background(Grok.raised)
                            .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                        }
                        Text("The task runs in this session — its folder, effort, and approval settings apply.")
                            .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("PROMPT")
                        FieldBox {
                            TextField("", text: $prompt,
                                      prompt: Text("pull main, run the tests, summarize failures…").foregroundColor(Grok.textFaint),
                                      axis: .vertical)
                                .font(Grok.sans(16)).foregroundStyle(Grok.text).lineLimit(2...5)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("WHEN")
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.wheel)
                            .colorScheme(.dark)
                            .frame(maxWidth: .infinity)
                        // The circles stay 34pt and the gap between them becomes the
                        // slack in a 44pt target, so a mis-tap no longer picks the
                        // wrong day. The targets flex instead of being a fixed 44pt
                        // each: seven rigid ones are 308pt, wider than the card has
                        // under Display Zoom, and short of it on a large phone.
                        // VoiceOver read the initials, which is two "S" and two "T"
                        // with no way to tell what is already on.
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { d in
                                Button {
                                    if weekdays.contains(d) { weekdays.remove(d) } else { weekdays.insert(d) }
                                } label: {
                                    Text(daySymbols.indices.contains(d) ? daySymbols[d] : "?")
                                        .font(Grok.sans(14, .semibold))
                                        .frame(width: 34, height: 34)
                                        .background(weekdays.contains(d) ? Color.white : Color.clear)
                                        .foregroundStyle(weekdays.contains(d) ? .black : Grok.textDim)
                                        .overlay(Circle().stroke(weekdays.contains(d) ? Color.clear : Grok.hairline, lineWidth: 1))
                                        .clipShape(Circle())
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(dayNames.indices.contains(d) ? dayNames[d] : ""))
                                .accessibilityAddTraits(weekdays.contains(d) ? [.isSelected] : [])
                            }
                        }
                        (weekdays.isEmpty
                            ? Text("Every day")
                            : Text("Uses your computer's clock and time zone."))
                            .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
                    }

                    if let errorText {
                        Text(errorText).font(Grok.sans(14)).foregroundStyle(Grok.danger)
                    }

                    Button { Task { await save() } } label: {
                        HStack(spacing: 10) {
                            if saving { ProgressView().controlSize(.small).tint(.white) }
                            (saving ? Text("SAVING") : Text("SAVE SCHEDULE")).latinTracking(1.3)
                        }
                    }
                    .buttonStyle(PillButton(kind: .prominent))
                    .disabled(saving || prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedSession == nil)
                }
                .padding(.horizontal, Grok.gutter).padding(.vertical, 20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New schedule")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Grok.textDim)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() async {
        guard let client = app.client, let session = selectedSession else { return }
        saving = true
        errorText = nil
        defer { saving = false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        do {
            try await client.createSchedule(sessionId: session.id,
                                            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                            hour: comps.hour ?? 9, minute: comps.minute ?? 0,
                                            weekdays: Array(weekdays).sorted())
            Haptics.success()
            dismiss()
        } catch {
            errorText = String(localized: "Couldn't save — check the connection.")
        }
    }
}
