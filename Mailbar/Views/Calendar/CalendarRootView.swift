import SwiftUI

/// The calendar window's content: toolbar, the grid for the chosen view, and the detail panel for
/// the selected event. Laid out after the user's OWA week view.
struct CalendarRootView: View {
    @Bindable var store: CalendarStore

    @State private var showsDatePicker = false

    /// Below this the detail panel floats over the grid as a card instead of taking a column.
    private static let sidePanelMinimum: CGFloat = 900
    static let minimumSize = NSSize(width: 520, height: 420)
    /// Narrower than this, a week no longer reads, so the calendar switches to Day; wider again,
    /// back to Week (the user's rule, 2026-09-25).
    static let dayViewBelow: CGFloat = 580

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.sidePanelMinimum
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.6)
                if let notice = store.notice {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(notice)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.08))
                    .transition(.opacity)
                }
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if wide, store.selectedEventID != nil {
                            Divider().opacity(0.6)
                            EventDetailPanel(store: store)
                                .frame(width: 330)
                                .transition(.move(edge: .trailing))
                        }
                    }
                    if !wide, store.selectedEventID != nil {
                        // A narrow window keeps every day visible: the event's details float over
                        // the grid, as Calendar's pop-over does, rather than squeezing the week.
                        EventDetailPanel(store: store)
                            .frame(width: min(330, proxy.size.width - 32))
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                            .padding(12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.22), value: store.selectedEventID)
                .clipped()
            }
            .onAppear { widthChanged(from: nil, to: proxy.size.width) }
            .onChange(of: proxy.size.width) { old, new in widthChanged(from: old, to: new) }
        }
        .background(CalendarSurface.background)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .animation(.snappy(duration: 0.2), value: store.notice)
        .sheet(isPresented: Binding(get: { store.editor != nil }, set: { if !$0 { store.editor = nil } })) {
            if let draft = store.editor {
                EventEditorView(store: store, original: draft)
            }
        }
    }

    /// Switches only when the width CROSSES the line, so a view picked by hand sticks until the
    /// window is resized across it again: Day in a wide window stays Day, and so on.
    private func widthChanged(from old: CGFloat?, to new: CGFloat) {
        let isNarrow = new < Self.dayViewBelow
        // Opening the window: the width decides outright, so a Day left over from a narrow
        // window opens as Week in a wide one.
        guard let old else {
            if isNarrow { store.mode = .day } else if store.mode == .day { store.mode = .week }
            return
        }
        let wasNarrow: Bool? = old < Self.dayViewBelow
        guard wasNarrow != isNarrow else { return }
        if isNarrow, store.mode != .day {
            store.mode = .day
        } else if !isNarrow, wasNarrow == true, store.mode == .day {
            store.mode = .week
        }
    }

    // MARK: - Toolbar

    /// Shrinks in steps as the window narrows, as Calendar's does: first the title shortens, then
    /// the views become a small segmented control and the account picker an icon menu.
    private var toolbar: some View {
        HStack(spacing: 12) {
            titleButton
            if case .loading = store.phase {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer(minLength: 8)
            // The controls take their room before the title, so the title shortens first and the
            // controls stay one size across Day, Week and Month: when the title went first, Week's
            // long title squeezed them compact and Day's short one let them grow back, so the
            // switcher jumped under the pointer on every change (the user's recording, 2026-09-26).
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
            .layoutPriority(1)
            // No refresh button: the stream (M11) and coming back to the window keep the calendar
            // current (the user's call, 2026-09-25). Cmd+R still works, unseen.
            Button("") { Task { await store.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
                .frame(width: 0)
        }
        // The title's first letter on the grid's left line: the hour gutter's edge in Day and Week,
        // the first column's text in Month. The traffic lights sit on the row above.
        .padding(.leading, store.mode == .month ? 8 : CalendarWeekView.gutterWidth)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
    }

    private var titleButton: some View {
        Button { showsDatePicker.toggle() } label: {
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    Text(store.title).font(.system(size: 19))
                    Text(store.shortTitle).font(.system(size: 17))
                    Text(store.tinyTitle).font(.system(size: 15))
                }
                .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDatePicker, arrowEdge: .bottom) {
            DatePicker("", selection: Binding(get: { store.anchor },
                                              set: { store.anchor = $0; showsDatePicker = false }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                // No focus ring: taking focus as the popover opened drew a blue frame round the
                // whole month, so it looked selected (2026-09-25).
                .focusEffectDisabled()
                .environment(\.calendar, store.calendar)
                .padding(10)
        }
    }

    @ViewBuilder
    private func controls(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            if store.mail.accounts.accounts.count > 1 {
                if compact {
                    Menu {
                        ForEach(store.mail.accounts.accounts) { account in
                            Button(account.displayName) { store.accountID = account.id }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(store.account?.displayName ?? "Account")
                } else {
                    // A grey capsule like New Event and Today beside it (the user's call); the
                    // stock popup's square corners stood out in the row.
                    Menu {
                        Picker("", selection: Binding(get: { store.account?.id }, set: { store.accountID = $0 })) {
                            ForEach(store.mail.accounts.accounts) { account in
                                Text(account.displayName).tag(Optional(account.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 6) {
                            Text(store.account?.displayName ?? "Account").lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(CalendarControl.fill))
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Account")
                }
            }

            // New event, as Apple's Calendar puts its "+" in the toolbar.
            // A capsule with its word, like Today beside it (the user's call); the plus stays.
            Button { store.startNewEvent() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("New Event").font(.system(size: 13))
                }
                .padding(.horizontal, compact ? 10 : 12)
                .frame(height: 26)
                .background(Capsule().fill(CalendarControl.fill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New Event  ⌘N")
            .disabled(store.account == nil)

            ModeSwitcher(selection: $store.mode, compact: compact)

            // Previous, Today, Next (the user's layout, 2026-09-25), as Apple's Calendar draws
            // them: two round buttons with a capsule between.
            HStack(spacing: 6) {
                Button { store.slide(forward: false) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(CalendarControl.fill))
                        .contentShape(Circle())
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous  ⌘←")
                Button { store.goToday() } label: {
                    Text("Today").font(.system(size: 13))
                        .padding(.horizontal, compact ? 10 : 12)
                        .frame(height: 26)
                        .background(Capsule().fill(CalendarControl.fill))
                        .contentShape(Capsule())
                }
                .keyboardShortcut("t", modifiers: .command)
                .help("Today  ⌘T")
                Button { store.slide(forward: true) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(CalendarControl.fill))
                        .contentShape(Circle())
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next  ⌘→")
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .failed(let message) where store.events.isEmpty:
            GenericFailureView(message: message) { Task { await store.refresh() } }
        default:
            switch store.mode {
            case .month:
                CalendarMonthView(store: store)
            case .day, .week:
                CalendarWeekView(store: store)
            }
        }
    }
}

/// The controls' grey, a neutral that follows light and dark like the rest of the calendar.
enum CalendarControl {
    static let fill = Color.primary.opacity(0.07)
}

/// Day, Week, Month in one capsule with the chosen one in a grey pill that slides between them,
/// as Apple's Calendar shows its views (the user's choice, 2026-09-25).
private struct ModeSwitcher: View {
    @Binding var selection: CalendarStore.Mode
    let compact: Bool

    @Namespace private var pill
    /// The segment the pill sits under. Its own state, moved inside `withAnimation`, so the pill
    /// slides while the calendar under it cuts straight to the new view, as Apple's does
    /// (animating the mode itself morphed every column and header between layouts).
    @State private var shown: CalendarStore.Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<CalendarStore.Mode>, compact: Bool) {
        _selection = selection
        self.compact = compact
        _shown = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        let current = shown
        HStack(spacing: 2) {
            ForEach(CalendarStore.Mode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: current == mode ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, compact ? 10 : 14)
                        .frame(height: 24)
                        .matchedGeometryEffect(id: mode, in: pill)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        // One pill that travels between the segments, rather than one per segment that appears
        // and disappears, so there is always a frame to animate from.
        .background {
            Capsule().fill(Color.primary.opacity(0.1))
                .matchedGeometryEffect(id: current, in: pill, isSource: false)
        }
        .onChange(of: selection) { _, mode in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { shown = mode }
        }
        .padding(3)
        .background(Capsule().fill(CalendarSurface.background))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }
}
