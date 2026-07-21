import SwiftUI

/// Settings section for bridge-side scheduled tasks ("weekdays at 9: run the
/// tests"). They fire on the computer's clock and behave like any other turn —
/// completion push, approval pushes if grok asks.
struct SchedulesSection: View {
    @EnvironmentObject var app: AppState
    @State private var schedules: [BridgeSchedule]?
    @State private var adding = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("SCHEDULED TASKS")

            if let schedules, !schedules.isEmpty {
                ForEach(schedules) { s in row(s) }
            } else if schedules != nil {
                Text("Run a prompt automatically — every morning, weekdays, whenever.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
            }
            if let errorText {
                Text(errorText).font(Grok.mono(11)).foregroundStyle(Grok.danger)
            }

            Button { Haptics.tap(); adding = true } label: {
                Label("Add a scheduled task", systemImage: "clock.badge.plus")
            }
            .buttonStyle(PillButton(kind: .subtle))
            .disabled(app.sessions.isEmpty)
            if app.sessions.isEmpty {
                Text("Create a session first — a schedule runs inside one.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Text("Runs on your computer's clock, even with this phone off. You'll get a push when it finishes.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
        .task { await load() }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            ScheduleEditorSheet().environmentObject(app)
        }
    }

    private func row(_ s: BridgeSchedule) -> some View {
        let sessionName = app.sessions.first(where: { $0.id == s.sessionId })?.displayName ?? "session"
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.prompt).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(2)
                Text("\(s.timeLabel) · \(s.daysLabel) · \(sessionName)")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { s.enabled },
                set: { on in Task { await setEnabled(s, on) } }
            )).labelsHidden().tint(.white)
            Button {
                Task { await remove(s) }
            } label: {
                Image(systemName: "minus.circle").font(.caption)
            }.foregroundStyle(Grok.textDim).padding(.top, 7)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func load() async {
        guard let client = app.client else { return }
        schedules = (try? await client.listSchedules()) ?? schedules
    }

    private func setEnabled(_ s: BridgeSchedule, _ on: Bool) async {
        guard let client = app.client else { return }
        do {
            try await client.setScheduleEnabled(s.id, enabled: on)
            if let i = schedules?.firstIndex(where: { $0.id == s.id }) { schedules?[i].enabled = on }
        } catch { errorText = "Couldn't update that schedule." }
    }

    private func remove(_ s: BridgeSchedule) async {
        guard let client = app.client else { return }
        do {
            try await client.deleteSchedule(s.id)
            schedules?.removeAll { $0.id == s.id }
        } catch { errorText = "Couldn't delete that schedule." }
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
                                Text(selectedSession?.displayName ?? "choose…")
                                    .font(Grok.mono(13)).foregroundStyle(Grok.text)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11)).foregroundStyle(Grok.textFaint)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Grok.raised)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        Text("The task runs in this session — its folder, effort, and approval settings apply.")
                            .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("PROMPT")
                        FieldBox {
                            TextField("", text: $prompt,
                                      prompt: Text("pull main, run the tests, summarize failures…").foregroundColor(Grok.textFaint),
                                      axis: .vertical)
                                .font(Grok.mono(13)).foregroundStyle(Grok.text).lineLimit(2...5)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("WHEN")
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.wheel)
                            .colorScheme(.dark)
                            .frame(maxWidth: .infinity)
                        HStack(spacing: 8) {
                            ForEach(0..<7, id: \.self) { d in
                                Button {
                                    if weekdays.contains(d) { weekdays.remove(d) } else { weekdays.insert(d) }
                                } label: {
                                    Text(daySymbols.indices.contains(d) ? daySymbols[d] : "?")
                                        .font(Grok.mono(11, .semibold))
                                        .frame(width: 34, height: 34)
                                        .background(weekdays.contains(d) ? Color.white : Color.clear)
                                        .foregroundStyle(weekdays.contains(d) ? .black : Grok.textDim)
                                        .overlay(Circle().stroke(weekdays.contains(d) ? Color.clear : Grok.hairline, lineWidth: 1))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(weekdays.isEmpty ? "Every day" : "Uses your computer's clock and time zone.")
                            .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                    }

                    if let errorText {
                        Text(errorText).font(Grok.mono(11)).foregroundStyle(Grok.danger)
                    }

                    Button { Task { await save() } } label: {
                        HStack(spacing: 10) {
                            if saving { ProgressView().controlSize(.small).tint(.white) }
                            (saving ? Text("SAVING") : Text("SAVE SCHEDULE")).tracking(1.3)
                        }
                    }
                    .buttonStyle(PillButton(kind: .prominent))
                    .disabled(saving || prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedSession == nil)
                }
                .padding(20)
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
            errorText = "Couldn't save — check the connection."
        }
    }
}
