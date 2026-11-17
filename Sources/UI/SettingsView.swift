import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences
    let sendTest: () -> Void

    var body: some View {
        Form {
            Section("How quick to speak up") {
                Picker("Sensitivity", selection: $prefs.sensitivity) {
                    ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(prefs.sensitivity.explanation).font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Send notifications", isOn: $prefs.notificationsOn)
                Toggle("Quiet hours", isOn: $prefs.quietHoursOn)
                if prefs.quietHoursOn {
                    HStack {
                        Picker("From", selection: $prefs.quietStart) { hours }
                        Picker("to", selection: $prefs.quietEnd) { hours }
                    }
                }
                Button("Send a test notification", action: sendTest)
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
                Text("Slop Cleaner only closes things by itself for the Automate rules you turn on, and warns you 5 minutes before. Everything else waits for you to press a button.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Not suggested again") {
                if prefs.ignored.isEmpty {
                    Text("Nothing yet. Use “Don't suggest this again” on a card to add it here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.ignored.sorted { $0.value < $1.value }, id: \.key) { id, label in
                        HStack {
                            Text(label)
                            Spacer()
                            Button("Allow again") { prefs.unignore(id) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
    }

    @ViewBuilder private var hours: some View {
        ForEach(0..<24, id: \.self) { h in
            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
                .formatted(date: .omitted, time: .shortened)).tag(h)
        }
    }
}
