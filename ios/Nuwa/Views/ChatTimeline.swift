import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct ChatTimelineAppearance {
    let fontSize: Double
    let locale: AppLocale
    let isGenerating: Bool
    let editingMessageID: UUID?
    let editDraft: String
}

struct ChatTimeline<Row: View>: View {
    @Binding var isAtBottom: Bool
    let messages: [ChatMessage]
    let versions: [UUID: MessageVersionInfo]
    let appearance: ChatTimelineAppearance
    let topCommand: Int
    let animateBoundaryJumps: Bool
    let latestLabel: String
    @ViewBuilder let row: (ChatMessage) -> Row

    @State private var latestCommand = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineCollection(
            isAtBottom: $isAtBottom,
            messages: messages,
            versions: versions,
            appearance: appearance,
            colorScheme: colorScheme,
            topCommand: topCommand,
            latestCommand: latestCommand,
            animateBoundaryJumps: animateBoundaryJumps && !reduceMotion,
            row: row
        )
        .overlay(alignment: .bottomTrailing) {
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
                .padding(.bottom, 12)
            }
        }
    }
}

private struct TimelineCollection<Row: View>: UIViewRepresentable {
    @Binding var isAtBottom: Bool
    let messages: [ChatMessage]
    let versions: [UUID: MessageVersionInfo]
    let appearance: ChatTimelineAppearance
    let colorScheme: ColorScheme
    let topCommand: Int
    let latestCommand: Int
    let animateBoundaryJumps: Bool
    let row: (ChatMessage) -> Row

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TimelineCollectionView {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 18
            section.contentInsets = NSDirectionalEdgeInsets(top: 22, leading: 0, bottom: 17, trailing: 0)
            return section
        }
        let view = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .never
        view.selfSizingInvalidation = .enabledIncludingConstraints
        view.allowsSelection = false
        if #available(iOS 26, *) {
            view.topEdgeEffect.isHidden = true
            view.bottomEdgeEffect.isHidden = true
        }
        context.coordinator.connect(view)
        return view
    }

    func updateUIView(_ view: TimelineCollectionView, context: Context) {
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

            for case let cell as TimelineCell<Row> in view.visibleCells {
                if let id = cell.key?.message.id { configure(cell, id: id) }
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
                guard let self, let view, view.followsLatest == following, input.isAtBottom != following else { return }
                input.isAtBottom = following
            }
        }
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
        contentView.clipsToBounds = true
        contentConfiguration = UIHostingConfiguration {
            row
                .environment(\.colorScheme, key.colorScheme)
                .id(key.message.id)
        }
        .margins(.all, 0)
    }
}

private final class TimelineCollectionView: UICollectionView {
    var followsLatest = true
    private var pinnedToTop = false
    private var animatingBoundary = false
    private var laidOutSize = CGSize.zero
    private var focusAnchor: (IndexPath, CGFloat)?
    private weak var touchedInput: UIView?
    private lazy var focusProbe = TimelineFocusProbe { [weak self] input in
        guard let self, !followsLatest else { return }
        focusAnchor = readingPosition(in: bounds)
        touchedInput = input
    }

    private var bottomOffset: CGFloat { max(0, contentSize.height - bounds.height) }
    var isNearBottom: Bool { contentOffset.y >= bottomOffset - 40 }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusProbe.view?.removeGestureRecognizer(focusProbe)
        window?.addGestureRecognizer(focusProbe)
    }

    func beginDragging() {
        pinnedToTop = false
        animatingBoundary = false
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
        let sizeChanged = previousSize != bounds.size
        var readingAnchor: (IndexPath, CGFloat)?
        if sizeChanged, !followsLatest, !pinnedToTop, !isDragging, previousSize.height > 0 {
            let oldViewport = CGRect(origin: contentOffset, size: previousSize)
            // Focusing an editor can move the scroll offset before the keyboard resizes the view.
            if previousSize.width == bounds.width, previousSize.height > bounds.height,
               touchedInput?.isFirstResponder == true, let focusAnchor {
                readingAnchor = focusAnchor
            } else {
                readingAnchor = readingPosition(in: oldViewport)
            }
        }
        if sizeChanged { clearFocusAnchor() }
        laidOutSize = bounds.size
        super.layoutSubviews()
        if (followsLatest || pinnedToTop) && !isDragging && !isTracking && !isDecelerating && (!animatingBoundary || sizeChanged) {
            animatingBoundary = false
            setOffset(pinnedToTop ? 0 : bottomOffset)
        } else if let (indexPath, relativeY) = readingAnchor,
                  let frame = collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame {
            setOffset(max(0, min(bottomOffset, frame.minY - relativeY)))
        }
    }

    func jump(toBottom: Bool, animated: Bool) {
        clearFocusAnchor()
        followsLatest = toBottom
        pinnedToTop = !toBottom
        let y = toBottom ? bottomOffset : 0
        let distance = abs(contentOffset.y - y)
        animatingBoundary = animated && distance > 1 && distance <= bounds.height
        setContentOffset(CGPoint(x: 0, y: y), animated: animatingBoundary)
        setNeedsLayout()
    }

    private func setOffset(_ y: CGFloat) {
        guard abs(contentOffset.y - y) > 0.5 else { return }
        setContentOffset(CGPoint(x: 0, y: y), animated: false)
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
