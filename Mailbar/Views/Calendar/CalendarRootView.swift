import SwiftUI

/// The calendar window's content: toolbar, the grid for the chosen view, and the detail panel for
/// the selected event. Laid out after the user's OWA week view.
struct CalendarRootView: View {
    @Bindable var store: CalendarStore

    @State private var showsDatePicker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.selectedEventID != nil {
                    Divider().opacity(0.6)
                    EventDetailPanel(store: store)
                        .frame(width: 330)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.22), value: store.selectedEventID)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 520)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Button { store.step(forward: false) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous")
                Button { store.step(forward: true) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button { showsDatePicker.toggle() } label: {
                HStack(spacing: 6) {
                    Text(store.title).font(.system(size: 19, weight: .regular))
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
                    .environment(\.calendar, store.calendar)
                    .padding(10)
            }

            if case .loading = store.phase {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Spacer(minLength: 10)

            if store.mail.accounts.accounts.count > 1 {
                Picker("", selection: Binding(get: { store.account?.id }, set: { store.accountID = $0 })) {
                    ForEach(store.mail.accounts.accounts) { account in
                        Text(account.displayName).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            HStack(spacing: 16) {
                ForEach(CalendarStore.Mode.allCases) { mode in
                    Button(mode.label) { store.mode = mode }
                        .buttonStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(store.mode == mode ? Color.accentColor : Color.primary)
                }
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16)
                Button("Today") { store.goToday() }
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                    .keyboardShortcut("t", modifiers: .command)
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh")
            }
        }
        .padding(.leading, 78)   // clear of the traffic lights in the transparent title bar
        .padding(.trailing, 18)
        .padding(.vertical, 10)
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
            case .day, .week, .workWeek:
                CalendarWeekView(store: store)
            }
        }
    }
}
