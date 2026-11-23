// The viewer's own pieces on iOS: the stage (its backdrop, the photo, the picture flying in and out of its tile, and the
// details pulled up under the photo), the place and date in one glass capsule at the top, a Live Photo's LIVE badge, a
// stacked photo's badge, and the way Photos names a photo's day.

import SwiftUI

/// The photo and its details in one scroll, as on the Mac (AssetViewer) and as Photos has them: the pager full screen,
/// and the details below it. Scrolled up, the photo eases into the top of the screen, fitted there, until the details
/// rest under it; scrolled further, it goes up and away with them. Between the photo alone and the details at rest the
/// scroll stops at one or the other (ViewerDetailsStops), and a page the details are up on, swiped to, starts with them
/// at rest. The photo's place follows the scroll as it is drawn (`visualEffect`), never a frame behind it. At the top a
/// drag down is the page's, which closes the viewer; the scroll's own bounce there moves nothing, the photo staying
/// where it is. As the viewer opens and closes, a picture of the photo flies between its tile and its place over the
/// page, which waits hidden under it (ViewerHost); a drag down shrinks the photo and lets the grid show through, as
/// Photos' does. In a regular width (an iPad), as Photos has it there, the photo stays where it is and the details are
/// a panel at the trailing side under the top bar, which Info and ⌘I bring and take away.
struct ViewerStage: View {
    let state: ViewerState
    /// Changes as the model's months load or change, for the pager to ask for the neighbours again.
    let modelRevision: Int
    @State private var position = ScrollPosition(y: 0)
    /// The scroll's place, kept for the stops and the settling without drawing anything anew.
    @State private var scroll = ViewerStageScroll()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                panelStage
            } else {
                scrollStage
            }
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            state.detailsInPanel = sizeClass == .regular
        }
    }

    /// The photo alone, its details in a panel beside it.
    private var panelStage: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            let drag = state.closeDrag ?? .zero
            ZStack(alignment: .topTrailing) {
                backdrop(height: screen.height)
                ViewerPager(state: state, modelRevision: modelRevision,
                            imageRevision: state.session.metadata.imageRevision)
                    .scaleEffect(ViewerState.closeDragScale(drag, height: screen.height))
                    .offset(drag)
                    .frame(width: screen.width, height: screen.height)
                    .opacity(state.flight == nil ? 1 : 0)
                if state.showsDetails, state.isOpen {
                    // Under the top bar, and clear of the filmstrip at the foot.
                    let top = proxy.safeAreaInsets.top + 64
                    ViewerDetailsPanel(state: state, maxHeight: screen.height - top - proxy.safeAreaInsets.bottom - 72)
                        .padding(.top, top)
                        .padding(.trailing, 20)
                        .transition(.opacity)
                }
                if let flight = state.flight {
                    ViewerFlightPicture(flight: flight, origin: proxy.frame(in: .global).origin)
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.showsDetails)
        }
        .ignoresSafeArea()
        // Taken away, the details stop loading, as the scroll's settling has them stop on a phone.
        .onChange(of: state.showsDetails) { _, shows in
            if !shows { state.detailsSettled(at: 0, rest: 1) }
        }
    }

    /// Black with the controls hidden, as Photos leaves a photo, else the system's background; in as the viewer opens,
    /// out as it closes, and thinning as a drag down takes the photo away.
    private func backdrop(height: CGFloat) -> some View {
        let drag = state.closeDrag ?? .zero
        return Color(uiColor: state.chromeVisible || state.detailsActive ? .systemBackground : .black)
            .opacity(state.isOpen ? min(ViewerState.closeDragBackdrop(drag, height: height),
                                        ViewerState.pinchBackdrop(state.closePinch)) : 0)
            .animation(.easeInOut(duration: 0.2), value: state.chromeVisible || state.detailsActive)
    }

    /// The photo full screen and its details below it, in one scroll.
    private var scrollStage: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            let layout = ViewerDetailsLayout(screen: screen, aspectRatio: CGFloat(state.currentItem?.ratio ?? 1))
            // How far the scroll goes to bring the details to rest under the photo.
            let rest = max(1, screen.height - layout.photoHeight)
            let drag = state.closeDrag ?? .zero
            ZStack(alignment: .top) {
                backdrop(height: screen.height)
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ViewerPager(state: state, modelRevision: modelRevision,
                                    imageRevision: state.session.metadata.imageRevision)
                            .scaleEffect(ViewerState.closeDragScale(drag, height: screen.height))
                            .offset(drag)
                            .frame(width: screen.width, height: screen.height)
                            .visualEffect { content, geometry in
                                let scrolled = -geometry.frame(in: .scrollView).minY
                                let progress = min(max(scrolled / rest, 0), 1)
                                return content
                                    .scaleEffect(1 + (layout.photoScale - 1) * progress)
                                    .offset(y: min(scrolled, rest) + layout.photoOffset * progress)
                            }
                            // Under the flying picture until it lands.
                            .opacity(state.flight == nil ? 1 : 0)
                        // The bottom bar floats over the cards, which scroll clear of it at their end.
                        ViewerDetails(state: state, bottomClearance: max(proxy.safeAreaInsets.bottom, 96) + 16)
                            .frame(width: screen.width)
                            .frame(minHeight: screen.height - layout.photoHeight, alignment: .top)
                            .background(Color(uiColor: .systemBackground))
                            .opacity(state.isOpen ? 1 : 0)
                    }
                }
                .scrollPosition($position)
                .scrollTargetBehavior(ViewerDetailsStops(rest: rest, scroll: scroll))
                // A zoomed photo pans instead, and a drag down or a pinch closing the viewer holds the scroll still.
                .scrollDisabled(state.isZoomed || state.closeDrag != nil || state.closePinch != nil)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                    scroll.offset = offset
                    state.detailsScrolled(offset)
                }
                .onScrollPhaseChange { _, phase in
                    // Let go short of a stop: a quick spring takes it there (ViewerDetailsStops).
                    if phase != .interacting, let stop = scroll.pendingStop {
                        scroll.pendingStop = nil
                        withAnimation(.smooth(duration: 0.22)) { position.scrollTo(y: stop) }
                        return
                    }
                    if phase == .idle { state.detailsSettled(at: scroll.offset, rest: rest) }
                }
                // Info, the title, a tap on the photo, or zooming in: the scroll goes to the details or back.
                .onChange(of: state.showsDetails) { _, shows in
                    guard shows ? scroll.offset < rest - 1 : scroll.offset > 0.5 else { return }
                    withAnimation(ViewerState.detailsAnimation) { position.scrollTo(y: shows ? rest : 0) }
                }
                // The details up, the next photo's start at rest, under it as its shape has it.
                .onChange(of: state.currentID) {
                    guard state.showsDetails else { return }
                    withAnimation(ViewerState.detailsAnimation) { position.scrollTo(y: rest) }
                }
                if let flight = state.flight {
                    ViewerFlightPicture(flight: flight, origin: proxy.frame(in: .global).origin)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// The details in a panel at the trailing side, on an iPad, as Photos' Info: its title and Close at the top, the cards
/// scrolling under them, as tall as they are up to the room there is.
private struct ViewerDetailsPanel: View {
    let state: ViewerState
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Info")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark", role: .close) { state.hideDetails() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            ScrollView {
                ViewerDetails(state: state, bottomClearance: 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .frame(height: min(max(contentHeight, 120), max(120, maxHeight - 60)))
        }
        .frame(width: 380)
        .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Viewer Details Panel")
    }
}

/// Where the stage's scroll is, and the stop a finger let it go short of; kept for the stops, never drawn.
final class ViewerStageScroll: @unchecked Sendable {
    var offset: CGFloat = 0
    var pendingStop: CGFloat?
}

/// The scroll's stops between the photo alone and its details at rest: let go from the photo, it goes to the details
/// when it has come 40 points or is flicked up, else back; from the details at rest, back to the photo when pulled 60
/// points down or flicked down, else to rest; pushed past rest, it comes back to rest at most, and past that it is
/// free. Short of a stop, it halts where the finger let go and a quick spring takes it there (ViewerStage), as Photos'
/// does in about 0.25 s: the momentum's own glide there took 1.5 s.
struct ViewerDetailsStops: ScrollTargetBehavior {
    let rest: CGFloat
    let scroll: ViewerStageScroll

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Where the finger began, and its speed as it let go, in points a millisecond, as UIKit gives it.
        let start = context.originalTarget.rect.minY
        let ending = target.rect.minY
        let velocity = context.velocity.dy
        var stop: CGFloat?
        if start < rest - 1 {
            let up = (ending > 40 && velocity > -0.3) || velocity > 0.5
            stop = up ? rest : 0
        } else if ending < rest {
            let down = start <= rest + 1 && ((rest - ending > 60 && velocity < 0.3) || velocity < -0.6)
            stop = down ? 0 : rest
        }
        guard let stop, abs(stop - ending) > 1 else { return }
        target.rect.origin.y = scroll.offset
        scroll.pendingStop = stop
    }
}

/// A control in the viewer's own bars, drawn as the system's bar draws one in Liquid Glass: its symbol alone, in a glass
/// circle of `size` points that answers a touch.
struct ViewerBarCircle: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .medium))
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// One of the bottom bar's grouped controls (Favorite, Info, Edit): its symbol alone, its part of the group's capsule,
/// lit on its own under an iPad's pointer.
struct ViewerBarItem: ViewModifier {
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .medium))
            .buttonStyle(.plain)
            .frame(width: width, height: height)
            .contentShape(.rect)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
    }
}

/// The top bar's middle: the place over the day and time in a glass capsule, as Photos titles a photo; a tap brings
/// the details up or down.
struct ViewerTitleCapsule: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows or hides the details."))
        .accessibilityIdentifier("Photo Title")
        .opacity(title.isEmpty && subtitle.isEmpty ? 0 : 1)
    }
}

/// A Live Photo's badge under the top bar's leading edge, one switch for all Live Photos: LIVE, on yellow glass as the
/// Camera's Live is yellow when on, and a Live Photo moves briefly as a swipe brings it; OFF, and it stays still while
/// swiping. Either way a press plays it whole, and switching plays nothing. Where Reduce Motion or Auto-Play Video
/// Previews says no, it reads OFF and cannot switch. It waits with a spinner while a press waits for the motion, and
/// says so where the motion cannot be read. (Photos' badge is a menu that turns the one photo still, with Loop, Bounce
/// and Long Exposure, effects saved into the photo, which Immich has none of.)
struct ViewerLiveBadge: View {
    let state: ViewerState
    let item: AssetItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var videoAutoplay = UIAccessibility.isVideoAutoplayEnabled

    var body: some View {
        let systemSaysNo = reduceMotion || !videoAutoplay
        let on = state.livePhotosMove && !systemSaysNo
        let loading = state.liveLoading == item.id
        let unavailable = state.liveUnavailable.contains(item.id)
        Button { state.toggleLivePhotos() } label: {
            HStack(spacing: 5) {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: on && !unavailable ? "livephoto" : "livephoto.slash")
                }
                Text(on ? "LIVE" : "OFF")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(on ? AnyShapeStyle(.black) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.yellow).interactive() : .regular.interactive(), in: .capsule)
        .disabled(unavailable || systemSaysNo)
        .accessibilityLabel(Text("Live Photos"))
        .accessibilityValue(unavailable ? Text("Can't play") : systemSaysNo ? Text("Off in Settings")
                            : on ? Text("On") : Text("Off"))
        .accessibilityHint(Text("Switches whether Live Photos move as you swipe to them"))
        .accessibilityIdentifier("viewer.live")
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
            videoAutoplay = UIAccessibility.isVideoAutoplayEnabled
        }
    }
}

/// The LIVE badge has just switched all Live Photos on or off.
struct LiveNotice: Equatable {
    let on: Bool
    let id = UUID()
}

/// A moment's notice at the top's middle as the LIVE badge switches, as the Camera shows LIVE and LIVE OFF: the badge
/// is one switch for every Live Photo, which the notice makes plain.
struct ViewerLiveNotice: View {
    let state: ViewerState
    let notice: LiveNotice

    var body: some View {
        Text(notice.on ? "LIVE" : "LIVE OFF")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(notice.on ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(notice.on ? .regular.tint(.yellow) : .regular, in: .capsule)
            .accessibilityLabel(notice.on ? Text("Live Photos on") : Text("Live Photos off"))
            .task(id: notice.id) {
                UIAccessibility.post(notification: .announcement,
                                     argument: String(localized: notice.on ? "Live Photos on" : "Live Photos off"))
                try? await Task.sleep(for: .seconds(1.5))
                state.dismissLiveNotice(notice)
            }
    }
}

/// A stacked photo's badge under the top bar's trailing edge, where Photos puts its second badge: the stack's icon and
/// how many photos it holds; a tap opens the stack, its photos and its actions (ViewerStackSheet).
struct ViewerStackBadge: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                Text(count, format: .number)
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Text("Stack of \(count) Photos"))
        .accessibilityIdentifier("Stack")
    }
}

/// The days of a photo's title, in its own time, as Immich keeps it (read as UTC, ImmichDate).
enum ViewerDays {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// "Today", "Yesterday", the weekday within the week, the day and month within the year, else the full date, as
    /// Photos names a photo's day.
    static func name(_ date: Date, now: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let photoDay = calendar.dateComponents([.year, .month, .day], from: date)
        let today = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard let photoStart = calendar.date(from: photoDay), let todayStart = calendar.date(from: today),
              let days = calendar.dateComponents([.day], from: photoStart, to: todayStart).day else {
            return date.formatted(Date.FormatStyle(timeZone: utc).day().month(.wide).year())
        }
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2...6: return date.formatted(Date.FormatStyle(timeZone: utc).weekday(.wide))
        default:
            if photoDay.year == today.year { return date.formatted(Date.FormatStyle(timeZone: utc).day().month(.wide)) }
            return date.formatted(Date.FormatStyle(timeZone: utc).day().month(.wide).year())
        }
    }
}
