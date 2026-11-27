import SwiftUI
import UIKit

// The photo grid on the TV, on UIKit's collection view, as tvOS's own grids are: SwiftUI's lazy grids leave the focus
// engine to work out which of hundreds of focusable tiles cover which on every move (UIKit's `_UIFocusRegionEvaluator`),
// which stalls an older Apple TV, and they cannot draw the focused tile above the neighbours drawn after it. Each cell
// holds the SwiftUI tile (TVGridTile), the months are the sections under their names, and a month not read yet holds
// its count of places until it comes near. The focused tile lifts above its neighbours with a thin white outline, the
// outline alone on an older box (TVDevice). A click opens the viewer; a press and hold, the photo's menu (TVPhotoMenuEntry),
// whose questions the page asks (TVViewerCover); the viewer zooms out of and back into the tiles, which the grid finds,
// scrolls to and focuses for it (TVTileFrames).

/// A grid's photos: a timeline's months, each under its name, or a list's photos, read page by page.
@MainActor
enum TVPhotoGridContent {
    case timeline(TVTimelineModel)
    case results(TVResultsModel)

    struct Section {
        let id: String
        let title: String?
        let count: Int
        let items: [TVItem]?
    }

    var sections: [Section] {
        switch self {
        case .timeline(let model):
            model.months.map { Section(id: $0.id, title: TVFormat.month($0.id), count: $0.count, items: $0.items) }
        case .results(let model):
            [Section(id: "results", title: nil, count: model.items.count, items: model.items)]
        }
    }

    /// Where its photos stand: loading, read, or failed with the reason.
    var phase: TVResultsModel.Phase {
        switch self {
        case .timeline(let model):
            switch model.phase {
            case .loading: .loading
            case .loaded: .loaded
            case .failed(let message): .failed(message)
            }
        case .results(let model): model.phase
        }
    }

    var revision: Int {
        switch self {
        case .timeline(let model): model.revision
        case .results(let model): model.revision
        }
    }

    var identity: ObjectIdentifier {
        switch self {
        case .timeline(let model): ObjectIdentifier(model)
        case .results(let model): ObjectIdentifier(model)
        }
    }

    /// A month's photos, as it comes near; the next page of a list, as its end does.
    func read(section: Int, client: ImmichClient?) {
        switch self {
        case .timeline(let model):
            guard model.months.indices.contains(section) else { return }
            let id = model.months[section].id
            Task { await model.read(id, client: client) }
        case .results(let model):
            Task { await model.loadMore() }
        }
    }

    func viewing(section: Int, item: Int, client: ImmichClient?) -> TVViewing {
        switch self {
        case .timeline(let model):
            model.viewing(month: section, photo: item, client: client)
        case .results(let model):
            TVViewing(items: model.items, index: item) { [model] in
                await model.loadMore()
                return model.items
            }
        }
    }
}

struct TVPhotoGrid: UIViewRepresentable {
    let content: TVPhotoGridContent
    /// The content's count of changes, read here so SwiftUI updates the grid as the photos change.
    let revision: Int
    let open: (TVViewing) -> Void
    @Environment(TVModel.self) private var tv
    @Environment(\.tvTileFrames) private var frames
    @Environment(\.tvPhotoRequests) private var requests
    @Environment(\.tvPhotoPlace) private var place

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.tv = tv
        coordinator.place = place
        coordinator.requests = requests
        coordinator.open = open
        coordinator.serve(frames)
        coordinator.show(content, revision: revision)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var tv: TVModel?
        var place = TVPhotoPlace.library
        weak var requests: TVPhotoRequests?
        var open: (TVViewing) -> Void = { _ in }
        private weak var view: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>?
        private var content: TVPhotoGridContent?
        private var shown: (identity: ObjectIdentifier, revision: Int)?
        private var sections: [TVPhotoGridContent.Section] = []
        private var items: [String: TVItem] = [:]
        /// A tile's side, which the layout works out from the grid's width.
        private var side: CGFloat = 280
        /// The tile the focus goes to next (the photo the viewer showed last).
        private var focusTarget: IndexPath?

        func makeView() -> UICollectionView {
            let view = UICollectionView(frame: .zero, collectionViewLayout: layout())
            view.backgroundColor = .clear
            // A lifted tile at the grid's edge is drawn whole.
            view.clipsToBounds = false
            view.remembersLastFocusedIndexPath = true
            view.contentInset.bottom = 80
            view.delegate = self
            view.prefetchDataSource = self
            // What the remote's tests find the photos by (VersoTVUITests).
            view.accessibilityIdentifier = "Photos"
            let cell = UICollectionView.CellRegistration<TVPhotoCell, String> { [weak self] cell, _, key in
                self?.configure(cell, key)
            }
            let header = UICollectionView.SupplementaryRegistration<TVMonthHeader>(elementKind: UICollectionView.elementKindSectionHeader) {
                [weak self] header, _, path in
                header.label.text = self?.sections.indices.contains(path.section) == true ? self?.sections[path.section].title : nil
            }
            let dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { view, path, key in
                view.dequeueConfiguredReusableCell(using: cell, for: path, item: key)
            }
            dataSource.supplementaryViewProvider = { view, _, path in
                view.dequeueConfiguredReusableSupplementary(using: header, for: path)
            }
            self.dataSource = dataSource
            self.view = view
            return view
        }

        /// Six square tiles to a row, eight points apart, each month under its name.
        private func layout() -> UICollectionViewCompositionalLayout {
            UICollectionViewCompositionalLayout { [weak self] index, environment in
                let columns = TVMetrics.tileColumns, spacing = TVMetrics.tileSpacing
                let width = environment.container.effectiveContentSize.width
                let side = ((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
                self?.side = side
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                    repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = spacing
                section.contentInsets = .init(top: 0, leading: 0, bottom: 40, trailing: 0)
                if let self, self.sections.indices.contains(index), self.sections[index].title != nil {
                    section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(64)),
                        elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
                }
                return section
            }
        }

        /// The content's photos into the grid, where they changed: a new content (another filter) anew, its months not
        /// read yet as places of its own, so they are read again.
        func show(_ content: TVPhotoGridContent, revision: Int) {
            guard let dataSource, shown?.identity != content.identity || shown?.revision != revision else { return }
            shown = (content.identity, revision)
            self.content = content
            sections = content.sections
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            var fresh: [String: TVItem] = [:]
            var changed: [String] = []
            let placeholders = "\(content.identity.hashValue)"
            for section in sections {
                snapshot.appendSections([section.id])
                if let photos = section.items {
                    let keys = photos.map { "p:" + $0.id }
                    for (key, photo) in zip(keys, photos) {
                        fresh[key] = photo
                        if let before = items[key], before != photo { changed.append(key) }
                    }
                    snapshot.appendItems(keys, toSection: section.id)
                } else {
                    snapshot.appendItems((0..<section.count).map { "h:\(placeholders):\(section.id):\($0)" }, toSection: section.id)
                }
            }
            items = fresh
            snapshot.reconfigureItems(changed)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in self?.readVisible() }
        }

        private func configure(_ cell: TVPhotoCell, _ key: String) {
            let side = side
            if let item = items[key], let tv {
                cell.contentConfiguration = UIHostingConfiguration { TVGridTile(item: item, side: side).environment(tv) }
                    .margins(.all, 0)
                    .background { Color.clear }
            } else {
                cell.contentConfiguration = UIHostingConfiguration { Rectangle().fill(.quaternary) }.margins(.all, 0)
            }
        }

        /// The months on screen not read yet, read.
        private func readVisible() {
            guard let view, let dataSource else { return }
            let unread = Set(view.indexPathsForVisibleItems.filter { dataSource.itemIdentifier(for: $0)?.hasPrefix("h:") == true }.map(\.section))
            for section in unread { content?.read(section: section, client: tv?.client) }
        }

        // MARK: The viewer's zoom, its scrolling and focus

        /// Where the viewer finds a tile, scrolls to it and puts the focus on it as it closes.
        func serve(_ frames: TVTileFrames?) {
            guard let frames else { return }
            frames.locate = { [weak self] id in self?.frame(of: id) }
            frames.scroll = { [weak self] id in
                guard let self, let path = self.path(of: id) else { return }
                self.view?.scrollToItem(at: path, at: .centeredVertically, animated: false)
            }
            frames.scrollToSection = { [weak self] id in
                guard let self, let section = self.sections.firstIndex(where: { $0.id == id }), self.sections[section].count > 0 else { return }
                self.view?.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: false)
            }
            frames.focus = { [weak self] id in
                guard let self, let path = self.path(of: id), let view = self.view else { return }
                self.focusTarget = path
                view.setNeedsFocusUpdate()
                view.updateFocusIfNeeded()
            }
        }

        private func path(of id: String) -> IndexPath? { dataSource?.indexPath(for: "p:" + id) }

        private func frame(of id: String) -> CGRect? {
            guard let view, let path = path(of: id), let attributes = view.layoutAttributesForItem(at: path) else { return nil }
            return view.convert(attributes.frame, to: nil)
        }

        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            defer { focusTarget = nil }
            return focusTarget
        }

        // MARK: Reading on, opening, the menu

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt path: IndexPath) {
            guard let key = dataSource?.itemIdentifier(for: path) else { return }
            if key.hasPrefix("h:") { content?.read(section: path.section, client: tv?.client) }
            // A list reads its next page as its end comes near.
            if case .results = content, path.item >= (sections.first?.count ?? 0) - TVMetrics.tileColumns * 3 {
                content?.read(section: 0, client: tv?.client)
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt paths: [IndexPath]) {
            guard let dataSource else { return }
            var unread = Set<Int>()
            for path in paths {
                guard let key = dataSource.itemIdentifier(for: path) else { continue }
                if key.hasPrefix("h:") {
                    unread.insert(path.section)
                } else if let item = items[key], let images = tv?.images {
                    // The pictures of the rows the focus moves towards, decoded before they show.
                    Task { _ = await images.tileThumbnail(item.id, size: .preview, pixels: TVGridTile.pixels) }
                }
            }
            for section in unread { content?.read(section: section, client: tv?.client) }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
            guard let content, dataSource?.itemIdentifier(for: path)?.hasPrefix("p:") == true else { return }
            open(content.viewing(section: path.section, item: path.item, client: tv?.client))
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt paths: [IndexPath],
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let path = paths.first, let key = dataSource?.itemIdentifier(for: path), let item = items[key], let tv,
                  let requests else { return nil }
            let entries = TVPhotoMenuEntry.entries(for: item, place: place, model: tv)
            guard !entries.isEmpty else { return nil }
            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(children: entries.map { entry in
                    UIAction(title: entry.title, image: UIImage(systemName: entry.systemImage),
                             attributes: entry.destructive ? .destructive : []) { _ in requests.choose(entry, for: item) }
                })
            })
        }
    }
}

/// A tile's cell: above its neighbours while focused, with a thin white outline at its square edge, lifted with a soft
/// shadow on a newer box, the outline alone on an older one (TVDevice). UIKit's own focus look (a dark rounded platter)
/// is cleared, and the outline is a view of its own over the tile, not the content's border, which the platter's
/// rounding showed through at the corners.
final class TVPhotoCell: UICollectionViewCell {
    private let outline = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 14)
        layer.shadowRadius = 24
        outline.isUserInteractionEnabled = false
        outline.backgroundColor = .clear
        outline.layer.borderColor = UIColor.white.cgColor
        outline.layer.borderWidth = 3
        outline.isHidden = true
        outline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outline)
        NSLayoutConstraint.activate([
            outline.leadingAnchor.constraint(equalTo: leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: trailingAnchor),
            outline.topAnchor.constraint(equalTo: topAnchor),
            outline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        // Whatever the state, no platter of UIKit's behind the tile.
        backgroundConfiguration = .clear()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        layer.zPosition = focused ? 1 : 0
        bringSubviewToFront(outline)
        outline.isHidden = !focused
        guard !TVDevice.simpler else { return }
        coordinator.addCoordinatedAnimations { [self] in
            transform = focused ? CGAffineTransform(scaleX: 1.07, y: 1.07) : .identity
            layer.shadowOpacity = focused ? 0.5 : 0
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer.zPosition = 0
        transform = .identity
        layer.shadowOpacity = 0
        outline.isHidden = true
    }
}

/// A month's name over its photos, as the iPhone's grid has it.
final class TVMonthHeader: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let title3 = UIFont.preferredFont(forTextStyle: .title3)
        label.font = UIFont.systemFont(ofSize: title3.pointSize, weight: .bold)
        label.textColor = .label
        label.accessibilityTraits = .header
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }
}
