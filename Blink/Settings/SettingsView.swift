import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Schedule") {
                durationRow(
                    "Work interval",
                    value: binding(\.workInterval, scale: 60),
                    range: AppSettings.workIntervalRange.scaled(by: 1 / 60),
                    step: 1,
                    unit: "min"
                )
                durationRow(
                    "Break duration",
                    value: binding(\.breakDuration),
                    range: AppSettings.breakDurationRange,
                    step: 5,
                    unit: "sec"
                )
                durationRow(
                    "Pre-break warning",
                    value: binding(\.preBreakLead),
                    range: AppSettings.preBreakLeadRange,
                    step: 5,
                    unit: "sec"
                )
            }

            Section("Active hours") {
                Toggle("Only remind me between certain hours", isOn: $settings.limitToActiveHours)
                if settings.limitToActiveHours {
                    DatePicker(
                        "From",
                        selection: minuteBinding(\.activeStartMinute),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "Until",
                        selection: minuteBinding(\.activeEndMinute),
                        displayedComponents: .hourAndMinute
                    )
                    if settings.activeEndMinute <= settings.activeStartMinute {
                        Text("This window runs overnight into the next day.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Only remind me on certain days", isOn: $settings.limitToActiveDays)
                if settings.limitToActiveDays {
                    LabeledContent("Days") {
                        HStack(spacing: 4) {
                            ForEach(Self.orderedWeekdays, id: \.self) { weekday in
                                Toggle(Self.shortName(for: weekday), isOn: dayBinding(weekday))
                                    .toggleStyle(.button)
                                    .accessibilityLabel(Self.fullName(for: weekday))
                            }
                        }
                    }
                }
            }

            Section("Break appearance") {
                LabeledContent("Screen dim") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.dimLevel, in: AppSettings.dimLevelRange, step: 0.05)
                            .frame(width: 160)
                        Text(settings.dimLevel, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Smart skips") {
                durationRow(
                    "Idle reset after",
                    value: binding(\.idleResetThreshold, scale: 60),
                    range: AppSettings.idleResetRange.scaled(by: 1 / 60),
                    step: 1,
                    unit: "min"
                )
                Toggle("Skip breaks while the camera or microphone is in use", isOn: $settings.skipDuringCapture)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard newValue != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.set(newValue)
                        } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                Toggle("Play sound at break start and end", isOn: $settings.playSounds)
                Toggle("Show time until break in menu bar", isOn: $settings.showTimeRemainingInMenuBar)
                Toggle("Show debug menu", isOn: $settings.showDebugMenu)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private func durationRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 160)
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    /// `DatePicker` works in `Date`s, while the setting is a minute of the day;
    /// an arbitrary reference day carries the time across.
    private func minuteBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = settings[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: Self.referenceDay
                ) ?? Self.referenceDay
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settings.activeDays.contains(weekday) },
            set: { isOn in
                var days = settings.activeDays
                if isOn {
                    days.insert(weekday)
                } else {
                    // Clearing the last day would silence Blink outright.
                    guard days.count > 1 else { return }
                    days.remove(weekday)
                }
                settings.activeDays = days
            }
        )
    }

    private static let referenceDay = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))

    /// Weekday numbers in the user's locale order (Sunday- or Monday-first).
    private static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private static func shortName(for weekday: Int) -> String {
        Calendar.current.veryShortWeekdaySymbols[weekday - 1]
    }

    private static func fullName(for weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    /// Binding onto a settings duration, optionally rescaled (e.g. seconds ⇄ minutes).
    private func binding(_ keyPath: ReferenceWritableKeyPath<AppSettings, TimeInterval>, scale: Double = 1) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] / scale },
            set: { settings[keyPath: keyPath] = $0 * scale }
        )
    }
}

private extension ClosedRange<Double> {
    func scaled(by factor: Double) -> ClosedRange<Double> {
        (lowerBound * factor)...(upperBound * factor)
    }
}

#Preview {
    SettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "preview")!))
}
