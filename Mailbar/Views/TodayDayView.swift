import SwiftUI

/// The popover's Today tab (M19): a one-day calendar, the same grid as the calendar window's Day
/// view (hour shading, event blocks in their category colours, the current-time line), with a
/// Join button on meetings that carry a link. An event opens in the calendar.
///
/// A two-finger sideways swipe goes through the days (the user's request, 2026-09-25), the same
/// way the calendar window pages: three days side by side follow the fingers (`PagerStrip`) and
/// settle on the next or back. It opens on today, and returns to today when the popover closes.
struct TodayDayView: View {
    @Bindable var store: MailStore
    let accountID: UUID
    let onOpenEvent: (CalendarEvent) -> Void
    let onOpenCalendar: () -> Void

    private let hourHeight: CGFloat = 44
    private static let gutter: CGFloat = 42
    private static let allDayRow: CGFloat = 22

    private var calendar: Calendar { Calendar.current }

    private func day(_ page: Int) -> Date { store.day(offset: store.dayOffset + page) }

    var body: some View {
        // As tall as the busiest of the three days, so the strip does not jump during a swipe.
        let allDayRows = (-1...1).map { page in
            (store.events(onDay: day(page), for: accountID) ?? []).filter(\.isAllDay).count
        }.max() ?? 0
        VStack(spacing: 0) {
            PagerStrip(pager: store.dayPager) { page in dayHeader(day(page)) }
                .frame(height: 30)
                .overlay(alignment: .trailing) { backToToday }
            if allDayRows > 0 {
                HStack(spacing: 0) {
                    Text("all day").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(width: Self.gutter - 6, alignment: .trailing)
                        .padding(.trailing, 6)
                    PagerStrip(pager: store.dayPager) { page in allDay(day(page)) }
                }
                .frame(height: CGFloat(allDayRows) * Self.allDayRow + 4)
                .padding(.trailing, 6)
            }
            timeline
        }
        .onAppear {
            store.dayPager.onCommit = { [store, accountID] forward in
                store.dayOffset += forward ? 1 : -1
                Task { await store.loadNearbyDays(for: accountID) }
            }
        }
        .task(id: accountID) {
            await store.refreshToday?()
            await store.loadNearbyDays(for: accountID)
        }
    }

    /// The date alone (the user took out the "Nothing on your calendar" note and the Open
    /// Calendar link, 2026-09-25; an empty day reads as empty, and the tray menu opens the
    /// calendar).
    private func dayHeader(_ day: Date) -> some View {
        HStack {
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 12, weight: .semibold))
            if store.events(onDay: day, for: accountID) == nil {
                ProgressView().controlSize(.mini)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    /// Away from today, one click comes back.
    @ViewBuilder
    private var backToToday: some View {
        if store.dayOffset != 0 {
            Button("Today") {
                store.dayOffset = 0
                Task { await store.loadNearbyDays(for: accountID) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .padding(.trailing, 10)
            .help("Back to today")
        }
    }

    private func allDay(_ day: Date) -> some View {
        VStack(spacing: 2) {
            ForEach((store.events(onDay: day, for: accountID) ?? []).filter(\.isAllDay)) { event in
                EventBlock(event: event, isSelected: false, compact: true, tint: store.tint(for: event, in: accountID))
                    .frame(height: Self.allDayRow - 2)
                    .onTapGesture { onOpenEvent(event) }
            }
        }
        .padding(.leading, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(CalendarWeekView.hourLabel(hour))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: Self.gutter - 8, height: hourHeight, alignment: .topLeading)
                                .padding(.leading, 8)
                                .offset(y: -6)
                                .id("today-hour-\(hour)")
                        }
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(1)
                    PagerStrip(pager: store.dayPager, measures: true) { page in dayColumn(day(page)) }
                        .frame(height: hourHeight * 24)
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
            // Fills what the popover gives the tab, the same height as the Inbox.
            .frame(maxHeight: .infinity)
            .onAppear {
                // The current hour near the top, with the hour before it for context.
                let hour = max(calendar.component(.hour, from: Date()) - 1, 0)
                DispatchQueue.main.async { proxy.scrollTo("today-hour-\(hour)", anchor: .top) }
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let events = (store.events(onDay: day, for: accountID) ?? []).filter { !$0.isAllDay }
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                HourBackground(isWorkDay: Keys.calendarWorkDays().contains(calendar.component(.weekday, from: day)),
                               workHours: Keys.calendarWorkHours(), hourHeight: hourHeight)
                ForEach(EventLayout.place(events, on: day, calendar: calendar)) { placed in
                    let x = CGFloat(placed.column) / CGFloat(placed.columns) * (width - 6) + 3
                    let w = (width - 6) / CGFloat(placed.columns) - 2
                    let h = max((placed.endHour - placed.startHour) * hourHeight - 2, 18)
                    EventBlock(event: placed.event, isSelected: false, compact: h < 34,
                               tint: store.tint(for: placed.event, in: accountID), height: h, width: max(w, 10))
                        .frame(width: max(w, 10), height: h)
                        .overlay(alignment: .topTrailing) { join(placed.event, blockHeight: h) }
                        .offset(x: x, y: placed.startHour * hourHeight)
                        .onTapGesture { onOpenEvent(placed.event) }
                }
                if calendar.isDateInToday(day) {
                    // Nudged in so its dot is not cut off by the strip's clipping.
                    NowLine(calendar: calendar, hourHeight: hourHeight, width: width - 4)
                        .padding(.leading, 4)
                }
            }
        }
    }

    /// Centred on the title's line, which sits in the block's top 22 points (a short block is all
    /// title line, so there it is centred in the block), never pinned to the bottom corner.
    @ViewBuilder
    private func join(_ event: CalendarEvent, blockHeight: CGFloat) -> some View {
        if let link = store.joinLinks[event.id], event.end > Date() {
            Button {
                NSWorkspace.shared.open(link)
            } label: {
                Label("Join", systemImage: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(height: min(18, blockHeight - 4))
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(link.host ?? "Join the meeting")
            .padding(.trailing, 4)
            .frame(height: min(blockHeight, 22))
        }
    }
}
