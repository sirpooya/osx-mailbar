import AppKit
import SwiftUI

/// The event form's field look, one for every box: 28 points tall (the user asked for taller
/// fields), a rounded border that turns the accent colour while the field is being edited.
struct FieldBox<Content: View>: View {
    var focused = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.16),
                              lineWidth: focused ? 2 : 1))
    }
}

/// An `NSDatePicker` without its own bezel, so it can sit inside a `FieldBox` with the calendar
/// button beside the date, inside the same box (the user's call). A SwiftUI `DatePicker` in the
/// field style always draws its own border.
struct PlainDatePicker: NSViewRepresentable {
    @Binding var date: Date
    let elements: NSDatePicker.ElementFlags

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = SteppingDatePicker()
        // Shift with Up or Down moves a time by 10 minutes (the user's call, 2026-09-25).
        if elements.contains(.hourMinute) {
            picker.shiftStep = 10 * 60
            // 09:00, never " 9:00", so times line up at the left (the user's call). No locale
            // pads a 12-hour hour, and the picker takes no format of its own: 24-hour it is.
            picker.locale = Locale(identifier: "en_GB")
        }
        // Dates read year/month/day, 2026/09/25 (the user's call). NSDatePicker takes its order
        // only from a locale, and this one writes exactly that, always in the Gregorian calendar.
        if elements.contains(.yearMonthDay) {
            picker.locale = Locale(identifier: "en_ZA")
            picker.calendar = Calendar(identifier: .gregorian)
        }
        picker.datePickerStyle = .textField
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        picker.font = .systemFont(ofSize: 13)
        picker.datePickerElements = elements
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.dateValue = date
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

/// A date picker whose Shift with Up or Down arrow takes a bigger step. The picker does not say
/// which part (hour or minute) is selected, so the step is the same for either.
final class SteppingDatePicker: NSDatePicker {
    var shiftStep: TimeInterval?

    override func keyDown(with event: NSEvent) {
        let up: UInt16 = 126, down: UInt16 = 125
        if let step = shiftStep, event.modifierFlags.contains(.shift), event.keyCode == up || event.keyCode == down {
            dateValue = dateValue.addingTimeInterval(event.keyCode == up ? step : -step)
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }
}

extension PlainDatePicker {
    /// The picker draws its text a few points in from its own edge and a point above centre;
    /// `leading` pulls it back so it starts where a text field's text starts, level with the
    /// label (measured on screen, 2026-09-25). A one-digit hour still leads with the picker's
    /// own padding space, as every Mac time field does.
    func fieldInset(_ leading: CGFloat) -> some View {
        padding(.leading, leading).offset(y: 1)
    }
}

/// A system popup button at a set width, so Repeat, Reminder and Show as line up as one column
/// (the user's call). SwiftUI's menu `Picker` sizes itself to its text and ignores the frame.
struct PopUpMenu: NSViewRepresentable {
    struct Item: Equatable {
        let id: String
        let title: String
        var image: NSImage? = nil
        var separatorBefore = false
    }

    let items: [Item]
    let selected: String
    let width: CGFloat
    /// Items that do something rather than stay chosen ("Other..."): the popup goes back to the
    /// current choice after one is picked.
    var actions: Set<String> = []
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.selected = selected
        coordinator.actions = actions
        if coordinator.items != items {
            coordinator.items = items
            button.removeAllItems()
            for item in items {
                if item.separatorBefore { button.menu?.addItem(.separator()) }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.image = item.image
                menuItem.representedObject = item.id
                button.menu?.addItem(menuItem)
            }
        }
        coordinator.select(selected, in: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var items: [Item] = []
        var selected = ""
        var actions: Set<String> = []
        var onSelect: (String) -> Void = { _ in }

        func select(_ id: String, in button: NSPopUpButton) {
            if let item = button.itemArray.first(where: { $0.representedObject as? String == id }) {
                button.select(item)
            }
        }

        @objc func picked(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            if actions.contains(id) { select(selected, in: sender) }
            onSelect(id)
        }
    }
}

/// OWA's "Select repeat pattern", reached from Repeat's Other: how often (every N days, weeks,
/// months), on which weekdays for a weekly one, and a line saying it in words.
struct RepeatPatternEditor: View {
    let start: Date
    let workDays: Set<Int>
    let onSave: (RepeatPattern) -> Void
    let onCancel: () -> Void

    @State private var pattern: RepeatPattern

    init(pattern: RepeatPattern?, start: Date, workDays: Set<Int>,
         onSave: @escaping (RepeatPattern) -> Void, onCancel: @escaping () -> Void) {
        self.start = start
        self.workDays = workDays
        self.onSave = onSave
        self.onCancel = onCancel
        var initial = pattern ?? RepeatPattern(kind: .weekly)
        if initial.kind == .weekly, initial.weekdays.isEmpty {
            initial.weekdays = [Calendar.current.component(.weekday, from: start)]
        }
        _pattern = State(initialValue: initial)
    }

    private var unit: String {
        switch pattern.kind {
        case .daily: return pattern.interval == 1 ? "day" : "days"
        case .weekly: return pattern.interval == 1 ? "week" : "weeks"
        case .monthlyDay, .monthlyWeek: return pattern.interval == 1 ? "month" : "months"
        case .yearly: return "year"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repeat").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Text("Occurs").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                // Outlook's four: Daily, Weekly, Monthly, Yearly; Monthly then asks which way.
                PopUpMenu(items: [.init(id: "daily", title: "Daily"), .init(id: "weekly", title: "Weekly"),
                                  .init(id: "monthly", title: "Monthly"), .init(id: "yearly", title: "Yearly")],
                          selected: occursID, width: 150) { id in
                    switch id {
                    case "daily": pattern.kind = .daily
                    case "weekly":
                        pattern.kind = .weekly
                        if pattern.weekdays.isEmpty { pattern.weekdays = [Calendar.current.component(.weekday, from: start)] }
                    case "monthly": if pattern.kind != .monthlyWeek { pattern.kind = .monthlyDay }
                    default: pattern.kind = .yearly
                    }
                }
            }
            if pattern.kind == .monthlyDay || pattern.kind == .monthlyWeek {
                HStack(spacing: 8) {
                    Text("On").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Picker("", selection: $pattern.kind) {
                        Text(RepeatPattern.kindName(.monthlyDay, start: start).replacingOccurrences(of: "Monthly, on ", with: ""))
                            .tag(RepeatPattern.Kind.monthlyDay)
                        Text(RepeatPattern.kindName(.monthlyWeek, start: start).replacingOccurrences(of: "Monthly, on ", with: ""))
                            .tag(RepeatPattern.Kind.monthlyWeek)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            if pattern.kind != .yearly {
                HStack(spacing: 8) {
                    Text("Every").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    FieldBox {
                        TextField("", value: $pattern.interval, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                    .frame(width: 54)
                    Stepper("", value: $pattern.interval, in: 1...99).labelsHidden()
                    Text(unit)
                }
            }
            if pattern.kind == .weekly {
                HStack(spacing: 5) {
                    Text("On").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    ForEach(weekOrder, id: \.self) { weekday in
                        let on = pattern.weekdays.contains(weekday)
                        Button {
                            if on, pattern.weekdays.count > 1 { pattern.weekdays.remove(weekday) } else { pattern.weekdays.insert(weekday) }
                        } label: {
                            Text(String(RepeatPattern.dayNames[weekday - 1].prefix(2)))
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 28, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                                .foregroundStyle(on ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help(RepeatPattern.dayNames[weekday - 1])
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            Text(pattern.label(start: start, workDays: workDays))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var result = pattern
                    result.interval = min(max(result.interval, 1), 99)
                    onSave(result)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var occursID: String {
        switch pattern.kind {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthlyDay, .monthlyWeek: return "monthly"
        case .yearly: return "yearly"
        }
    }

    private var weekOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}
