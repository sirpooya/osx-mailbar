import SwiftUI

/// The popover's Today tab (M19): today as a one-day calendar, the same grid as the calendar
/// window's Day view (hour shading, event blocks in their category colours, the current-time
/// line), with a Join button on meetings that carry a link. An event opens in the calendar.
struct TodayDayView: View {
    @Bindable var store: MailStore
    let accountID: UUID
    let onOpenEvent: (CalendarEvent) -> Void
    let onOpenCalendar: () -> Void

    private let hourHeight: CGFloat = 44
    private static let gutter: CGFloat = 42

    private var events: [CalendarEvent] { store.dayEvents[accountID] ?? [] }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if !store.todayLoaded.contains(accountID) {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 200)
            } else {
                allDay
                timeline
            }
        }
        .task { await store.refreshToday?() }
    }

    /// Just the date (the user took out the "Nothing on your calendar" note and the Open Calendar
    /// link, 2026-09-25; an empty day reads as empty, and the tray menu opens the calendar).
    private var dayHeader: some View {
        HStack {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var allDay: some View {
        let allDayEvents = events.filter(\.isAllDay)
        if !allDayEvents.isEmpty {
            HStack(spacing: 4) {
                Text("all day").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(width: Self.gutter - 6, alignment: .trailing)
                ForEach(allDayEvents) { event in
                    EventBlock(event: event, isSelected: false, compact: true, tint: store.tint(for: event, in: accountID))
                        .frame(height: 20)
                        .onTapGesture { onOpenEvent(event) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
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
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .topLeading) {
                            HourBackground(isWorkDay: Keys.calendarWorkDays().contains(calendar.component(.weekday, from: Date())),
                                           workHours: Keys.calendarWorkHours(), hourHeight: hourHeight)
                            ForEach(EventLayout.place(events.filter { !$0.isAllDay }, on: Date(), calendar: calendar)) { placed in
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
                            NowLine(calendar: calendar, hourHeight: hourHeight, width: width)
                        }
                    }
                    .frame(height: hourHeight * 24)
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
            .frame(height: 440)
            .onAppear {
                // The current hour near the top, with the hour before it for context.
                let hour = max(calendar.component(.hour, from: Date()) - 1, 0)
                DispatchQueue.main.async { proxy.scrollTo("today-hour-\(hour)", anchor: .top) }
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
