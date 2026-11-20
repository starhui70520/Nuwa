import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
final class TimelineStreamingCoordinator {
    var onLiveRowUpdated: (() -> Void)?
}

struct ChatTimelineAppearance {
    let fontSize: Double
    let locale: AppLocale
    let isGenerating: Bool
    let editingMessageID: UUID?
    let editDraft: String
    let disclosureOverrides: [UUID: Bool]
}

struct ChatTimeline<Row: View>: View {
    @Binding var isAtBottom: Bool
    let messages: [ChatMessage]
    let versions: [UUID: MessageVersionInfo]
    let appearance: ChatTimelineAppearance
    let topInset: CGFloat
    let bottomInset: CGFloat
    let usesSystemSafeAreaBars: Bool
    let topCommand: Int
    let disclosureAnchorID: UUID?
    let disclosureAnchorToken: Int
    let streamingCoordinator: TimelineStreamingCoordinator
    let animateBoundaryJumps: Bool
    let latestLabel: String
    @ViewBuilder let row: (ChatMessage) -> Row

    @State private var latestCommand = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            collectionView
                .ignoresSafeArea(.container, edges: .vertical)

            if !isAtBottom {
                Button {
                    isAtBottom = true
                    latestCommand += 1
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.nuwaLabelPrimary)
                        .frame(width: 36, height: 36)
                        .nuwaGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(latestLabel)
                .padding(.trailing, 16)
                .padding(.bottom, usesSystemSafeAreaBars ? 12 : bottomInset + 12)
            }
        }
    }

    @ViewBuilder
    private var collectionView: some View {
        let base = TimelineCollection(
            isAtBottom: $isAtBottom,
            messages: messages,
            versions: versions,
            appearance: appearance,
            colorScheme: colorScheme,
            topInset: topInset,
            bottomInset: bottomInset,
            usesSystemSafeAreaBars: usesSystemSafeAreaBars,
            topCommand: topCommand,
            latestCommand: latestCommand,
            disclosureAnchorID: disclosureAnchorID,
            disclosureAnchorToken: disclosureAnchorToken,
            streamingCoordinator: streamingCoordinator,
            animateBoundaryJumps: animateBoundaryJumps && !reduceMotion,
            row: row
        )
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), usesSystemSafeAreaBars {
            base.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            base
        }
        #else
        base
        #endif
    }
}

private struct TimelineCollection<Row: View>: UIViewRepresentable {
    @Binding var isAtBottom: Bool
    let messages: [ChatMessage]
    let versions: [UUID: MessageVersionInfo]
    let appearance: ChatTimelineAppearance
    let colorScheme: ColorScheme
    let topInset: CGFloat
    let bottomInset: CGFloat
    let usesSystemSafeAreaBars: Bool
    let topCommand: Int
    let latestCommand: Int
    let disclosureAnchorID: UUID?
    let disclosureAnchorToken: Int
    let streamingCoordinator: TimelineStreamingCoordinator
    let animateBoundaryJumps: Bool
    let row: (ChatMessage) -> Row

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TimelineCollectionView {
        let layout = TimelineLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 18
            section.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 0, bottom: 16, trailing: 0)
            return section
        }
        let view = TimelineCollectionView(frame: .zero, timelineLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.selfSizingInvalidation = .enabledIncludingConstraints
        view.allowsSelection = false
        view.usesSystemSafeAreaBars = usesSystemSafeAreaBars

        if #available(iOS 26, *), usesSystemSafeAreaBars {
            view.contentInsetAdjustmentBehavior = .scrollableAxes
            view.topEdgeEffect.isHidden = false
            view.topEdgeEffect.style = .soft
            view.bottomEdgeEffect.isHidden = false
            view.bottomEdgeEffect.style = .soft
        } else {
            view.contentInsetAdjustmentBehavior = .never
            if #available(iOS 26, *) {
                view.topEdgeEffect.isHidden = true
                view.bottomEdgeEffect.isHidden = true
            }
            view.applyInsets(top: topInset, bottom: bottomInset)
        }

        streamingCoordinator.onLiveRowUpdated = { [weak view] in
            view?.syncStreamingLayout()
        }
        context.coordinator.connect(view)
        return view
    }

    func updateUIView(_ view: TimelineCollectionView, context: Context) {
        streamingCoordinator.onLiveRowUpdated = { [weak view] in
            view?.syncStreamingLayout()
        }
        context.coordinator.update(self, view: view)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        private var input: TimelineCollection
        private var messages: [UUID: ChatMessage] = [:]
        private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>?

        init(_ input: TimelineCollection) {
            self.input = input
        }

        func connect(_ view: TimelineCollectionView) {
            view.delegate = self
            view.onDisclosureSettled = { [weak self, weak view] following in
                guard let self, let view else { return }
                self.publish(following, from: view)
            }
            let registration = UICollectionView.CellRegistration<TimelineCell<Row>, UUID> { [weak self] cell, _, id in
                self?.configure(cell, id: id)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, indexPath, id in
                view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
        }

        func update(_ updated: TimelineCollection, view: TimelineCollectionView) {
            let previous = input
            input = updated
            guard let dataSource else { return }

            if !updated.usesSystemSafeAreaBars {
                view.applyInsets(top: updated.topInset, bottom: updated.bottomInset)
            }

            let isStreamingReply = updated.appearance.isGenerating && updated.messages.last?.isStreaming == true
            view.setStreamingState(active: isStreamingReply, lastIndex: updated.messages.count - 1)

            // When user taps a disclosure (已思考), pin that cell's top edge BEFORE reconfiguring so it NEVER jumps!
            let disclosureToggled = previous.disclosureAnchorToken != updated.disclosureAnchorToken
            if disclosureToggled,
               let anchorID = updated.disclosureAnchorID,
               let anchorIP = dataSource.indexPath(for: anchorID) {
                view.captureDisclosureAnchor(for: anchorIP)
            }

            if previous.messages != updated.messages || messages.isEmpty {
                messages = Dictionary(updated.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let ids = updated.messages.map(\.id)
                if dataSource.snapshot().itemIdentifiers != ids {
                    var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
                    snapshot.appendSections([0])
                    snapshot.appendItems(ids)
                    dataSource.apply(snapshot, animatingDifferences: false)
                }
                view.setNeedsLayout()
            }

            if disclosureToggled {
                UIView.performWithoutAnimation {
                    for case let cell as TimelineCell<Row> in view.visibleCells {
                        if let id = cell.key?.message.id { configure(cell, id: id) }
                    }
                    view.setNeedsLayout()
                    view.layoutIfNeeded()
                }
                if !view.isNearBottom {
                    publish(false, from: view)
                }
            } else {
                for case let cell as TimelineCell<Row> in view.visibleCells {
                    if let id = cell.key?.message.id { configure(cell, id: id) }
                }
            }

            if previous.topCommand != updated.topCommand {
                view.jump(toBottom: false, animated: updated.animateBoundaryJumps)
                publish(false, from: view)
            } else if previous.latestCommand != updated.latestCommand {
                view.jump(toBottom: true, animated: updated.animateBoundaryJumps)
            }
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard let cell = cell as? TimelineCell<Row>, let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            configure(cell, id: id)
        }

        private func configure(_ cell: TimelineCell<Row>, id: UUID) {
            guard let message = messages[id] else { return }
            let appearance = input.appearance
            let key = TimelineCellKey(
                message: message,
                version: input.versions[id],
                fontSize: appearance.fontSize,
                locale: appearance.locale,
                isGenerating: appearance.isGenerating,
                isLast: input.messages.last?.id == id,
                editDraft: appearance.editingMessageID == id ? appearance.editDraft : nil,
                disclosureExpanded: appearance.disclosureOverrides[id],
                colorScheme: input.colorScheme
            )
            guard cell.key != key else { return }
            cell.update(key: key, row: input.row(message))
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            (scrollView as? TimelineCollectionView)?.beginDragging()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? TimelineCollectionView, view.isDragging || view.isDecelerating else { return }
            updateFollowing(view)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
            if !willDecelerate, let view = scrollView as? TimelineCollectionView { updateFollowing(view) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let view = scrollView as? TimelineCollectionView { updateFollowing(view) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            (scrollView as? TimelineCollectionView)?.finishBoundaryAnimation()
        }

        private func updateFollowing(_ view: TimelineCollectionView) {
            let following = view.isNearBottom
            guard view.followsLatest != following else { return }
            view.followsLatest = following
            publish(following, from: view)
        }

        private func publish(_ following: Bool, from view: TimelineCollectionView) {
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                if !view.hasDisclosureAnchor && view.followsLatest != following {
                    view.followsLatest = following
                }
                if input.isAtBottom != following {
                    input.isAtBottom = following
                }
            }
        }
    }
}

/// Suppresses UIKit's automatic self-sizing `contentOffsetAdjustment` on the live streaming cell
/// so UIKit never fights our lock-to-bottom offset or shoves scrolled-up reading position.
private final class TimelineLayout: UICollectionViewCompositionalLayout {
    var suppressLastItemOffsetAdjustment = false
    var lastItemIndex = -1

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        if suppressLastItemOffsetAdjustment,
           preferredAttributes.representedElementCategory == .cell,
           preferredAttributes.indexPath.item == lastItemIndex {
            context.contentOffsetAdjustment = .zero
        }
        return context
    }
}

private struct TimelineCellKey: Equatable {
    let message: ChatMessage
    let version: MessageVersionInfo?
    let fontSize: Double
    let locale: AppLocale
    let isGenerating: Bool
    let isLast: Bool
    let editDraft: String?
    let disclosureExpanded: Bool?
    let colorScheme: ColorScheme
}

private final class TimelineCell<Row: View>: UICollectionViewCell {
    private(set) var key: TimelineCellKey?

    override func prepareForReuse() {
        super.prepareForReuse()
        key = nil
        contentConfiguration = nil
    }

    func update(key: TimelineCellKey, row: Row) {
        self.key = key
        contentView.clipsToBounds = false
        contentConfiguration = UIHostingConfiguration {
            row
                .environment(\.colorScheme, key.colorScheme)
                .id(key.message.id)
        }
        .margins(.all, 0)
    }
}

private final class TimelineCollectionView: UICollectionView {
    private let timelineLayout: TimelineLayout

    var followsLatest = true
    var usesSystemSafeAreaBars = false
    var onDisclosureSettled: ((Bool) -> Void)?
    private var isStreaming = false
    private var lastItemIndex = -1
    private var isSyncingStreaming = false
    private var pinnedToTop = false
    private var animatingBoundary = false
    private var laidOutSize = CGSize.zero
    private var lastAdjustedInset = UIEdgeInsets.zero
    private var chromeTopInset: CGFloat = 0
    private var chromeBottomInset: CGFloat = 0
    private var focusAnchor: (IndexPath, CGFloat)?
    private var disclosureAnchor: (IndexPath, CGFloat)?
    var hasDisclosureAnchor: Bool { disclosureAnchor != nil }
    private var disclosureAnchorGeneration = 0
    private weak var touchedInput: UIView?
    private lazy var focusProbe = TimelineFocusProbe { [weak self] input in
        guard let self, !followsLatest else { return }
        focusAnchor = readingPosition(in: visibleViewport)
        touchedInput = input
    }

    init(frame: CGRect, timelineLayout: TimelineLayout) {
        self.timelineLayout = timelineLayout
        super.init(frame: frame, collectionViewLayout: timelineLayout)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var effectiveInset: UIEdgeInsets { adjustedContentInset }
    private var topOffset: CGFloat { -effectiveInset.top }
    private var bottomOffset: CGFloat { max(topOffset, contentSize.height + effectiveInset.bottom - bounds.height) }
    private var visibleViewport: CGRect {
        CGRect(
            x: contentOffset.x,
            y: contentOffset.y + effectiveInset.top,
            width: bounds.width,
            height: max(0, bounds.height - effectiveInset.top - effectiveInset.bottom)
        )
    }
    var isNearBottom: Bool { contentOffset.y >= bottomOffset - 40 }

    func setStreamingState(active: Bool, lastIndex: Int) {
        isStreaming = active
        lastItemIndex = lastIndex
        timelineLayout.suppressLastItemOffsetAdjustment = active
        timelineLayout.lastItemIndex = lastIndex
    }

    /// Synchronously resolves self-sizing + bottom offset in a single non-animated CATransaction
    /// so live streaming text NEVER shakes or flashes up/down by half a line.
    func syncStreamingLayout() {
        guard !isSyncingStreaming,
              disclosureAnchor == nil,
              !isDragging, !isTracking, !isDecelerating
        else { return }
        isSyncingStreaming = true
        defer { isSyncingStreaming = false }

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if lastItemIndex >= 0,
               let cell = cellForItem(at: IndexPath(item: lastItemIndex, section: 0)) {
                cell.invalidateIntrinsicContentSize()
            }
            setNeedsLayout()
            layoutIfNeeded()
            if followsLatest && !animatingBoundary {
                setOffsetImmediate(bottomOffset)
            }
            CATransaction.commit()
        }
    }

    func applyInsets(top: CGFloat, bottom: CGFloat) {
        guard !usesSystemSafeAreaBars else { return }
        chromeTopInset = max(0, top)
        chromeBottomInset = max(0, bottom)
        refreshManualInsets()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        if !usesSystemSafeAreaBars {
            refreshManualInsets()
        }
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        guard usesSystemSafeAreaBars else { return }
        if disclosureAnchor == nil && !isDragging && !isTracking && !isDecelerating {
            if followsLatest {
                setOffsetImmediate(bottomOffset)
            } else if pinnedToTop {
                setOffsetImmediate(topOffset)
            }
        }
    }

    private func refreshManualInsets() {
        let next = UIEdgeInsets(
            top: safeAreaInsets.top + chromeTopInset,
            left: 0,
            bottom: safeAreaInsets.bottom + chromeBottomInset,
            right: 0
        )
        guard abs(contentInset.top - next.top) > 0.5 || abs(contentInset.bottom - next.bottom) > 0.5 else {
            return
        }
        let anchor = (!followsLatest && !pinnedToTop && !isDragging && disclosureAnchor == nil && laidOutSize.height > 0)
            ? readingPosition(in: visibleViewport)
            : nil
        contentInset = next
        verticalScrollIndicatorInsets = next
        if disclosureAnchor == nil {
            if followsLatest && !isDragging && !isTracking && !isDecelerating {
                setOffsetImmediate(bottomOffset)
            } else if pinnedToTop && !isDragging && !isTracking && !isDecelerating {
                setOffsetImmediate(topOffset)
            } else if let (ip, relativeY) = anchor,
                      let frame = collectionViewLayout.layoutAttributesForItem(at: ip)?.frame {
                setOffsetImmediate(max(topOffset, min(bottomOffset, frame.minY - effectiveInset.top - relativeY)))
            }
        }
    }

    /// Captures the exact visual top edge of the cell whose thinking disclosure is toggling,
    /// and holds that anchor across all self-sizing passes until layout settles.
    func captureDisclosureAnchor(for indexPath: IndexPath) {
        pinnedToTop = false
        animatingBoundary = false
        followsLatest = false
        clearFocusAnchor()

        let currentFrame = cellForItem(at: indexPath)?.frame
            ?? collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame
        if let currentFrame {
            disclosureAnchor = (indexPath, currentFrame.minY - contentOffset.y)
            disclosureAnchorGeneration += 1
            let gen = disclosureAnchorGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.disclosureAnchorGeneration == gen else { return }
                self.disclosureAnchor = nil
                if !self.isDragging && !self.isTracking && !self.isDecelerating {
                    let nearBottom = self.isNearBottom
                    self.followsLatest = nearBottom
                    self.onDisclosureSettled?(nearBottom)
                }
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusProbe.view?.removeGestureRecognizer(focusProbe)
        window?.addGestureRecognizer(focusProbe)
    }

    func beginDragging() {
        pinnedToTop = false
        animatingBoundary = false
        disclosureAnchor = nil
        disclosureAnchorGeneration += 1
        clearFocusAnchor()
    }

    func finishBoundaryAnimation() {
        animatingBoundary = false
        setNeedsLayout()
    }

    private func clearFocusAnchor() {
        focusAnchor = nil
        touchedInput = nil
    }

    override func layoutSubviews() {
        let previousSize = laidOutSize
        let previousInset = lastAdjustedInset
        let sizeChanged = previousSize != bounds.size
        var readingAnchor: (IndexPath, CGFloat)?
        if disclosureAnchor == nil, sizeChanged, !followsLatest, !pinnedToTop, !isDragging, previousSize.height > 0 {
            let oldViewport = CGRect(
                x: contentOffset.x,
                y: contentOffset.y + previousInset.top,
                width: previousSize.width,
                height: max(0, previousSize.height - previousInset.top - previousInset.bottom)
            )
            if previousSize.width == bounds.width, previousSize.height > bounds.height,
               touchedInput?.isFirstResponder == true, let focusAnchor {
                readingAnchor = focusAnchor
            } else {
                readingAnchor = readingPosition(in: oldViewport)
            }
        }
        if sizeChanged { clearFocusAnchor() }
        laidOutSize = bounds.size
        lastAdjustedInset = effectiveInset

        if isStreaming && disclosureAnchor == nil && !sizeChanged && !isDragging && !isTracking && !isDecelerating {
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                super.layoutSubviews()
                if (followsLatest || pinnedToTop) && !animatingBoundary {
                    setOffsetImmediate(pinnedToTop ? topOffset : bottomOffset)
                }
                CATransaction.commit()
            }
            return
        }

        super.layoutSubviews()

        if let (anchorIP, relativeToOffset) = disclosureAnchor, !isDragging && !isTracking {
            if let frame = collectionViewLayout.layoutAttributesForItem(at: anchorIP)?.frame {
                setOffsetImmediate(max(topOffset, min(bottomOffset, frame.minY - relativeToOffset)))
            }
        } else if (followsLatest || pinnedToTop) && !isDragging && !isTracking && !isDecelerating && (!animatingBoundary || sizeChanged) {
            animatingBoundary = false
            setOffsetImmediate(pinnedToTop ? topOffset : bottomOffset)
        } else if let (indexPath, relativeY) = readingAnchor,
                  let frame = collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame {
            setOffsetImmediate(max(topOffset, min(bottomOffset, frame.minY - effectiveInset.top - relativeY)))
        }
    }

    func jump(toBottom: Bool, animated: Bool) {
        clearFocusAnchor()
        disclosureAnchor = nil
        disclosureAnchorGeneration += 1
        followsLatest = toBottom
        pinnedToTop = !toBottom
        let y = toBottom ? bottomOffset : topOffset
        let distance = abs(contentOffset.y - y)
        animatingBoundary = animated && distance > 1 && distance <= bounds.height
        setContentOffset(CGPoint(x: 0, y: y), animated: animatingBoundary)
        setNeedsLayout()
    }

    private func setOffsetImmediate(_ y: CGFloat) {
        guard abs(contentOffset.y - y) > 0.5 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentOffset = CGPoint(x: 0, y: y)
        CATransaction.commit()
    }

    private func readingPosition(in viewport: CGRect) -> (IndexPath, CGFloat)? {
        guard let cell = visibleCells.filter({ $0.frame.intersects(viewport) }).min(by: { $0.frame.minY < $1.frame.minY }),
              let indexPath = indexPath(for: cell) else { return nil }
        return (indexPath, cell.frame.minY - viewport.minY)
    }
}

private final class TimelineFocusProbe: UIGestureRecognizer {
    let onFocus: (UIView) -> Void

    init(onFocus: @escaping (UIView) -> Void) {
        self.onFocus = onFocus
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        var ancestor = touches.first?.view
        while let view = ancestor {
            if view is UITextField || (view as? UITextView)?.isEditable == true {
                if !view.isFirstResponder { onFocus(view) }
                break
            }
            ancestor = view.superview
        }
        state = .failed
    }
}
