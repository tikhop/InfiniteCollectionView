import UIKit

// MARK: - InfiniteCollectionViewDelegate

@MainActor
public protocol InfiniteCollectionViewDelegate: UIScrollViewDelegate {
    func infiniteCollectionView(_ view: InfiniteCollectionView, didSelectCellAt index: Int)
    func infiniteCollectionView(_ view: InfiniteCollectionView, sizeForCellAt index: Int) -> CGSize
    func infiniteCollectionView(_ view: InfiniteCollectionView, cellForItemAt index: Int) -> InfiniteCollectionViewCell
    func infiniteCollectionViewDidChangePage(_ view: InfiniteCollectionView, page: Int)

    func infiniteCollectionView(_ view: InfiniteCollectionView, willDisplay cell: InfiniteCollectionViewCell, forItemAt index: Int)
    func infiniteCollectionView(_ view: InfiniteCollectionView, didEndDisplaying cell: InfiniteCollectionViewCell, forItemAt index: Int)

    func infiniteCollectionView(_ view: InfiniteCollectionView, willScrollTo cell: InfiniteCollectionViewCell, forItemAt index: Int)
}

@MainActor
public extension InfiniteCollectionViewDelegate {
    func infiniteCollectionView(_ view: InfiniteCollectionView, didSelectCellAt index: Int) { }
    func infiniteCollectionViewDidChangePage(_ view: InfiniteCollectionView, page: Int) { }
    func infiniteCollectionView(_ view: InfiniteCollectionView, willDisplay cell: InfiniteCollectionViewCell, forItemAt index: Int) { }
    func infiniteCollectionView(_ view: InfiniteCollectionView, didEndDisplaying cell: InfiniteCollectionViewCell, forItemAt index: Int) { }

    func infiniteCollectionView(_ view: InfiniteCollectionView, willScrollTo cell: InfiniteCollectionViewCell, forItemAt index: Int) { }
}

// MARK: - ScrollDirection

public enum ScrollDirection: Sendable {
    case vertical
    case horizontal
}

// MARK: - PlacementPosition

internal enum PlacementPosition {
    case after
    case before
}

// MARK: - ScrollPosition

public struct ScrollPosition: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let top = ScrollPosition(rawValue: 1 << 0)
    public static let centeredVertically = ScrollPosition(rawValue: 1 << 1)
    public static let bottom = ScrollPosition(rawValue: 1 << 2)
    public static let left = ScrollPosition(rawValue: 1 << 3)
    public static let centeredHorizontally = ScrollPosition(rawValue: 1 << 4)
    public static let right = ScrollPosition(rawValue: 1 << 5)

    public static let topLeft: ScrollPosition = [.top, .left]
    public static let topRight: ScrollPosition = [.top, .right]
    public static let bottomLeft: ScrollPosition = [.bottom, .left]
    public static let bottomRight: ScrollPosition = [.bottom, .right]
    public static let center: ScrollPosition = [.centeredVertically, .centeredHorizontally]
    public static let topCenter: ScrollPosition = [.top, .centeredHorizontally]
    public static let bottomCenter: ScrollPosition = [.bottom, .centeredHorizontally]
    public static let leftCenter: ScrollPosition = [.centeredVertically, .left]
    public static let rightCenter: ScrollPosition = [.centeredVertically, .right]
}

private let kDefaultContentSize: CGFloat = 50000

// MARK: - InfiniteScrollView

@MainActor
open class InfiniteCollectionView: UIScrollView {
    weak var infiniteDelegate: (any InfiniteCollectionViewDelegate)? {
        didSet {
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    public var spacing: CGFloat = 0
    public let direction: ScrollDirection

    private var currentPageIndex = 0
    private var _isPagingEnabled = false

    #if os(iOS)
    open override var isPagingEnabled: Bool {
        set {
            hasPerformedInitialCentering = false
            _isPagingEnabled = newValue
            decelerationRate = newValue ? .fast : .normal

            // Configure gesture recognizer for better pagination
            if newValue {
                panGestureRecognizer.maximumNumberOfTouches = 1
            }

            setNeedsLayout()
            layoutIfNeeded()
        }
        get {
            super.isPagingEnabled
        }
    }
    #endif

    open override var delegate: (any UIScrollViewDelegate)? {
        didSet {
            guard delegate != nil else { return }
            fatalError("Use infiniteDelegate instead")
        }
    }

    public internal(set) var visibleCells: [InfiniteCollectionViewCell] = []

    private var maxVisibleCells = 0

    private var cellIndexes: [InfiniteCollectionViewCell: Int] = [:]
    private var reusableCellPools: [String: Set<InfiniteCollectionViewCell>] = [:]
    private var registeredCellClasses: [String: InfiniteCollectionViewCell.Type] = [:]

    private let containerView = UIView()
    private let defaultContentSize: CGFloat = 50_000

    private var isHorizontal: Bool { direction == .horizontal }
    private var axisBounds: CGFloat { isHorizontal ? adjustedBounds().width : adjustedBounds().height }
    private var axisContentSize: CGFloat { isHorizontal ? contentSize.width : contentSize.height }
    private var axisOffset: CGFloat { isHorizontal ? contentOffset.x : contentOffset.y }
    private var crossAxisBounds: CGFloat { isHorizontal ? adjustedBounds().height : adjustedBounds().width }

    private var axisInsets: (start: CGFloat, end: CGFloat) {
        isHorizontal ? (adjustedContentInset.left, adjustedContentInset.right) : (adjustedContentInset.top, adjustedContentInset.bottom)
    }

    private var crossAxisInsets: (start: CGFloat, end: CGFloat) {
        isHorizontal ? (adjustedContentInset.top, adjustedContentInset.bottom) : (adjustedContentInset.left, adjustedContentInset.right)
    }

    private func setAxisOffset(_ offset: CGFloat) {
        if isHorizontal {
            contentOffset.x = offset
        } else {
            contentOffset.y = offset
        }
    }

    private var hasPerformedInitialCentering = false

    required public init?(coder aDecoder: NSCoder) {
        direction = .vertical
        super.init(coder: aDecoder)
        setupScrollView()
    }

    public override init(frame: CGRect) {
        direction = .vertical
        super.init(frame: frame)
        setupScrollView()
    }

    public init(frame: CGRect, direction: ScrollDirection) {
        self.direction = direction
        super.init(frame: frame)
        setupScrollView()
    }

    private func setupScrollView() {
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        super.delegate = self

        let size = CGSize(
            width: isHorizontal ? kDefaultContentSize : frame.width,
            height: isHorizontal ? frame.height : kDefaultContentSize
        )
        contentSize = size
        containerView.frame = CGRect(origin: .zero, size: size)
        addSubview(containerView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleContainerTap(_:)))
        tap.cancelsTouchesInView = false
        containerView.addGestureRecognizer(tap)
    }

    @objc
    private func handleContainerTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: containerView)

        // Find which cell was tapped
        for cell in visibleCells {
            if cell.frame.contains(location),
               let index = cellIndexes[cell],
               let delegate = infiniteDelegate {
                delegate.infiniteCollectionView(self, didSelectCellAt: index)
                break
            }
        }
    }

    // MARK: - Layout

    private func updateContentSizeIfNeeded() {
        let newContentSize = direction == .horizontal
            ? CGSize(width: contentSize.width, height: frame.height)
            : CGSize(width: frame.width, height: contentSize.height)

        if newContentSize != contentSize {
            contentSize = newContentSize
            containerView.frame = CGRect(origin: .zero, size: contentSize)
        }
    }

    // recenter content periodically to achieve impression of infinite scrolling
    private func recenterIfNecessary(force: Bool = false) {
        let insets = axisInsets

        // Calculate center offset accounting for insets
        let effectiveContentSize = axisContentSize - insets.start - insets.end
        let centerOffset = insets.start + (effectiveContentSize - axisBounds) / 2.0
        let distanceFromCenter = abs(axisOffset - centerOffset)

        guard force || distanceFromCenter > (effectiveContentSize / 4.0) else { return }

        let delta = centerOffset - axisOffset
        setAxisOffset(centerOffset)

        for cell in visibleCells {
            var c = containerView.convert(cell.center, to: self)
            if isHorizontal { c.x += delta } else { c.y += delta }
            cell.center = convert(c, to: containerView)
        }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()

        updateContentSizeIfNeeded()

        // Don't recenter during scrolling animations
        if !isTracking {
            recenterIfNecessary()
        }

        // tile content in visible bounds
        guard infiniteDelegate != nil,
              !registeredCellClasses.isEmpty else { return }

        // Adjust visible bounds to account for content insets
        var bounds = adjustedBounds()
        var visibleBounds = convert(bounds, to: containerView)
        tileCells(in: visibleBounds)

        // Initial centering when paging is enabled
        if _isPagingEnabled && !hasPerformedInitialCentering {
            hasPerformedInitialCentering = true

            centerCell(at: 0)

            // Use the same adjusted bounds calculation
            bounds = adjustedBounds()
            visibleBounds = convert(bounds, to: containerView)
            tileCells(in: visibleBounds)

            // Set initial page
            currentPageIndex = 0
        }
    }

    open override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()

        hasPerformedInitialCentering = false
        recenterIfNecessary(force: true)

        // Force a layout update to reposition cells with new insets
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - Cell Registration and Reuse

    open func register(_ cellClass: InfiniteCollectionViewCell.Type, forCellWithReuseIdentifier identifier: String) {
        registeredCellClasses[identifier] = cellClass
    }

    open func dequeueReusableCell(withReuseIdentifier identifier: String, for index: Int) -> InfiniteCollectionViewCell {
        if var pool = reusableCellPools[identifier], let cell = pool.popFirst() {
            reusableCellPools[identifier] = pool
            cell.prepareForReuse()
            cellIndexes[cell] = index
            cell.isHidden = false
            return cell
        }

        guard let cellClass = registeredCellClasses[identifier] else {
            fatalError("Cell class not registered for identifier: \(identifier)")
        }

        let cell = cellClass.init()
        cell.setReuseIdentifier(identifier)
        cellIndexes[cell] = index
        containerView.addSubview(cell)
        return cell
    }

    private func enqueueCell(_ cell: InfiniteCollectionViewCell) {
        guard let identifier = cell.reuseIdentifier else { return }

        cellIndexes.removeValue(forKey: cell)

        if let cells = reusableCellPools[identifier], cells.count >= maxVisibleCells {
            cell.removeFromSuperview()
        } else {
            cell.isHidden = true
            reusableCellPools[identifier, default: []].insert(cell)
        }
    }

    // MARK: - Cell Tiling

    private func createCell(at index: Int) -> InfiniteCollectionViewCell? {
        guard let delegate = infiniteDelegate else { return nil }

        let cell = delegate.infiniteCollectionView(self, cellForItemAt: index)
        cellIndexes[cell] = index

        return cell
    }

    private func centerCell(at index: Int) {
        guard let cell = visibleCells.first(where: { cellIndexes[$0] == index }) else { return }

        let cellCenterInScrollView = containerView.convert(cell.center, to: self)
        let viewportCenter = axisBounds / 2
        let cellCenterComponent = axisComponent(of: cellCenterInScrollView)
        let targetOffset = cellCenterComponent - viewportCenter

        setAxisOffset(targetOffset)
    }

    private func placeNewCell(at position: PlacementPosition, edge: CGFloat, index: Int) -> InfiniteCollectionViewCell? {
        guard let delegate = infiniteDelegate,
              let cell = createCell(at: index) else { return nil }

        let cellSize = delegate.infiniteCollectionView(self, sizeForCellAt: index)

        if position == .after {
            visibleCells.append(cell)
        } else {
            visibleCells.insert(cell, at: 0)
        }

        let isAfter = position == .after
        var frame = CGRect.zero
        frame.size = cellSize

        let cellAxisSize = axisComponent(of: cellSize)
        let start = isAfter ? edge + spacing : edge - cellAxisSize - spacing

        let crossAxisCellSize = crossAxisComponent(of: cellSize)
        let crossAxisInsets = crossAxisInsets
        let availableCrossAxis = crossAxisBounds - crossAxisInsets.start - crossAxisInsets.end
        let crossAxisPosition = crossAxisInsets.start + (availableCrossAxis - crossAxisCellSize) / 2

        frame.origin = isHorizontal
            ? CGPoint(x: start, y: crossAxisPosition)
            : CGPoint(x: crossAxisPosition, y: start)

        cell.frame = frame

        return cell
    }

    internal func tileCells(in visibleBounds: CGRect) {
        let minVisible = isHorizontal ? visibleBounds.minX : visibleBounds.minY
        let maxVisible = isHorizontal ? visibleBounds.maxX : visibleBounds.maxY

        // Ensure at least one cell exists
        if visibleCells.isEmpty {
            let index = 0
            guard let cell = placeNewCell(at: .after, edge: minVisible - spacing, index: index) else {
                return
            }

            infiniteDelegate?.infiniteCollectionView(self, willDisplay: cell, forItemAt: index)
        }

        var lastCell: InfiniteCollectionViewCell! = visibleCells.last
        while lastCell != nil {
            let edge = lastCell.maxEdge(for: direction)
            guard edge + spacing < maxVisible else { break }

            if let lastIndexPath = cellIndexes[lastCell] {
                let nextIndexPath = index(for: .after, and: lastIndexPath)
                lastCell = placeNewCell(at: .after, edge: edge, index: nextIndexPath)
                infiniteDelegate?.infiniteCollectionView(self, willDisplay: lastCell, forItemAt: nextIndexPath)
            } else {
                break
            }
        }

        var firstCell: InfiniteCollectionViewCell! = visibleCells.first
        while firstCell != nil {
            let edge = firstCell.minEdge(for: direction)
            guard edge - spacing > minVisible else { break }

            if let firstIndexPath = cellIndexes[firstCell] {
                let prevIndexPath = index(for: .before, and: firstIndexPath)
                firstCell = placeNewCell(at: .before, edge: edge, index: prevIndexPath)
                infiniteDelegate?.infiniteCollectionView(self, willDisplay: firstCell, forItemAt: prevIndexPath)
            } else {
                break
            }
        }

        // Add small epsilon to handle floating point precision issues
        let epsilon: CGFloat = 0.001

        while let lastCell = visibleCells.last,
              lastCell.origin(for: direction) >= maxVisible - epsilon {
            let index = cellIndexes[lastCell]!

            enqueueCell(lastCell)
            visibleCells.removeLast()

            infiniteDelegate?.infiniteCollectionView(self, didEndDisplaying: lastCell, forItemAt: index)
        }

        while let firstCell = visibleCells.first,
              firstCell.maxEdge(for: direction) <= minVisible + epsilon {
            let index = cellIndexes[firstCell]!

            enqueueCell(firstCell)
            visibleCells.removeFirst()

            infiniteDelegate?.infiniteCollectionView(self, didEndDisplaying: firstCell, forItemAt: index)
        }

        maxVisibleCells = max(visibleCells.count, maxVisibleCells)
    }

    // MARK: - Reload Data

    open func reloadData() {
        guard let cell = visibleCells.first,
                let cellIndexPath = cellIndexes[cell] else {
            return
        }

        for cell in visibleCells {
            if let idx = cellIndexes[cell] {
                infiniteDelegate?.infiniteCollectionView(self, didEndDisplaying: cell, forItemAt: idx)
            }

            enqueueCell(cell)
        }

        visibleCells.removeAll()
        cellIndexes.removeAll()

        let adjustedBounds = adjustedBounds()
        let visibleBounds = convert(adjustedBounds, to: containerView)
        let minVisible = isHorizontal ? visibleBounds.minX : visibleBounds.minY

        guard let _ = placeNewCell(at: .after, edge: minVisible - spacing, index: cellIndexPath) else {
            return
        }

        tileCells(in: visibleBounds)
    }

    open func invalidateLayout() {
        guard let delegate = infiniteDelegate,
              !visibleCells.isEmpty else { return }

        // Update content size for new bounds
        updateContentSizeIfNeeded()

        // Find anchor cell and collect new sizes in a single pass
        let viewportCenter = axisBounds / 2
        let currentCenter = axisOffset + viewportCenter

        var anchorCell: InfiniteCollectionViewCell?
        var anchorRelativePosition: CGFloat = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        var cellsToReposition: [(cell: InfiniteCollectionViewCell, index: Int, newSize: CGSize)] = []

        for cell in visibleCells {
            guard let index = cellIndexes[cell] else { continue }

            // Get new size for this cell
            let newSize = delegate.infiniteCollectionView(self, sizeForCellAt: index)
            cellsToReposition.append((cell: cell, index: index, newSize: newSize))

            // Check if this is the anchor cell (centermost)
            let cellCenterInScrollView = containerView.convert(cell.center, to: self)
            let cellCenter = axisComponent(of: cellCenterInScrollView)
            let distance = abs(cellCenter - currentCenter)

            if distance < closestDistance && !_isPagingEnabled {
                closestDistance = distance
                anchorCell = cell
                // Store relative position of anchor cell center to current viewport center
                anchorRelativePosition = cellCenter - currentCenter
            } else if _isPagingEnabled && index == currentPageIndex {
                anchorCell = cell
                anchorRelativePosition = cellCenter - currentCenter
            }
        }

        // Sort cells by their index to maintain order
        cellsToReposition.sort { $0.index < $1.index }

        // Find the anchor cell in sorted array and calculate starting edge
        var currentEdge: CGFloat = 0

        if let anchorCell,
           let anchorIndex = cellsToReposition.firstIndex(where: { $0.cell === anchorCell }) {
            // Calculate where the anchor cell should be positioned
            let anchorNewSize = cellsToReposition[anchorIndex].newSize
            let anchorAxisSize = axisComponent(of: anchorNewSize)

            // For cells that fill or exceed the viewport, center them
            let viewportSize = axisBounds
            let targetAnchorStart: CGFloat

            if anchorAxisSize >= viewportSize || _isPagingEnabled {
                // Cell fills or exceeds viewport - center it in the viewport
                targetAnchorStart = axisOffset + (viewportSize - anchorAxisSize) / 2
            } else {
                // Normal positioning for smaller cells
                let targetAnchorCenter = currentCenter + anchorRelativePosition
                targetAnchorStart = targetAnchorCenter - anchorAxisSize / 2
            }

            // Position cells before anchor (going backwards)
            currentEdge = targetAnchorStart
            for i in (0..<anchorIndex).reversed() {
                let item = cellsToReposition[i]
                let cellAxisSize = axisComponent(of: item.newSize)
                currentEdge -= (cellAxisSize + spacing)
                updateCellFrame(item.cell, at: currentEdge, with: item.newSize)
            }

            // Position anchor cell
            updateCellFrame(anchorCell, at: targetAnchorStart, with: anchorNewSize)

            // Position cells after anchor (going forward)
            currentEdge = targetAnchorStart + anchorAxisSize
            for i in (anchorIndex + 1)..<cellsToReposition.count {
                let item = cellsToReposition[i]
                currentEdge += spacing
                updateCellFrame(item.cell, at: currentEdge, with: item.newSize)
                currentEdge += axisComponent(of: item.newSize)
            }

        } else if let firstCell = cellsToReposition.first {
            // No anchor cell found, start from first visible cell position
            currentEdge = firstCell.cell.origin(for: direction)

            for item in cellsToReposition {
                updateCellFrame(item.cell, at: currentEdge, with: item.newSize)
                currentEdge += axisComponent(of: item.newSize) + spacing
            }
        }

        // Re-tile to add or remove cells as needed
        let visibleBounds = convert(adjustedBounds(), to: containerView)
        tileCells(in: visibleBounds)

        // Force recenter if needed
        recenterIfNecessary()
    }

    private func updateCellFrame(_ cell: InfiniteCollectionViewCell, at position: CGFloat, with size: CGSize) {
        var frame = CGRect.zero
        frame.size = size

        let crossAxisCellSize = crossAxisComponent(of: size)
        let crossAxisInsets = crossAxisInsets
        let availableCrossAxis = crossAxisBounds - crossAxisInsets.start - crossAxisInsets.end
        let crossAxisPosition = crossAxisInsets.start + (availableCrossAxis - crossAxisCellSize) / 2

        frame.origin = isHorizontal
            ? CGPoint(x: position, y: crossAxisPosition)
            : CGPoint(x: crossAxisPosition, y: position)

        cell.frame = frame
    }

    internal func index(for placement: PlacementPosition, and pivotIndex: Int) -> Int {
        switch placement {
        case .before:
            pivotIndex - 1
        case .after:
            pivotIndex + 1
        }
    }

    private func axisComponent(of point: CGPoint) -> CGFloat {
        isHorizontal ? point.x : point.y
    }

    private func axisComponent(of size: CGSize) -> CGFloat {
        isHorizontal ? size.width : size.height
    }

    private func crossAxisComponent(of size: CGSize) -> CGFloat {
        isHorizontal ? size.height : size.width
    }
}

extension InfiniteCollectionView {
    public func index(for cell: InfiniteCollectionViewCell) -> Int? {
        cellIndexes[cell]
    }

    public func scrollToItem(
        at index: Int,
        at scrollPosition: ScrollPosition,
        animated: Bool
    ) {
        guard let delegate = infiniteDelegate else { return }

        // Check if target cell already exists
        if let existingCell = visibleCells.first(where: { cellIndexes[$0] == index }) {
            currentPageIndex = index
            scrollToCell(existingCell, at: scrollPosition, animated: animated)
            return
        }

        // Find the current center cell
        let bounds = bounds
        let viewportCenter = axisBounds / 2
        let currentCenter = axisOffset + viewportCenter

        var closestCell: InfiniteCollectionViewCell?
        var closestDistance = CGFloat.greatestFiniteMagnitude

        for cell in visibleCells {
            let cellCenterInScrollView = containerView.convert(cell.center, to: self)
            let cellCenter = axisComponent(of: cellCenterInScrollView)

            let distance = abs(cellCenter - currentCenter)
            if distance < closestDistance {
                closestDistance = distance
                closestCell = cell
            }
        }

        guard let currentCell = closestCell,
              let cellIndex = cellIndexes[currentCell] else {
            // No visible cells
            return
        }

        // Calculate the offset based on cell sizes between current and target
        let delta = index - cellIndex
        if delta == 0 {
            scrollToCell(currentCell, at: scrollPosition, animated: animated)
            return
        }

        // Calculate total size of cells between current and target
        var totalSize: CGFloat = 0
        let step = delta > 0 ? 1 : -1

        // When going forward: count cells from current+1 to target-1
        // When going backward: count cells from current-1 to target+1
        let startIndex = cellIndex + step
        let endIndex = index

        for i in stride(from: startIndex, to: endIndex, by: step) {
            let cellIndex = i
            let cellSize = delegate.infiniteCollectionView(self, sizeForCellAt: cellIndex)
            totalSize += axisComponent(of: cellSize) + spacing
        }

        if abs(delta) > 0 {
            totalSize += spacing
        }

        // Calculate target position based on current cell position
        let currentCellFrame = containerView.convert(currentCell.frame, to: self)
        let targetCellSize = delegate.infiniteCollectionView(self, sizeForCellAt: index)
        var targetFrame = CGRect.zero
        targetFrame.size = targetCellSize

        if isHorizontal {
            if delta > 0 {
                // Going forward: target is to the right
                targetFrame.origin.x = currentCellFrame.maxX + totalSize
            } else {
                // Going backward: target is to the left
                targetFrame.origin.x = currentCellFrame.minX - totalSize - targetCellSize.width
            }
            // Account for content insets when centering vertically
            let availableHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
            targetFrame.origin.y = adjustedContentInset.top + (availableHeight - targetCellSize.height) / 2
        } else {
            if delta > 0 {
                // Going down: target is below
                targetFrame.origin.y = currentCellFrame.maxY + totalSize
            } else {
                // Going up: target is above
                targetFrame.origin.y = currentCellFrame.minY - totalSize - targetCellSize.height
            }
            // Account for content insets when centering horizontally
            let availableWidth = bounds.width - adjustedContentInset.left - adjustedContentInset.right
            targetFrame.origin.x = adjustedContentInset.left + (availableWidth - targetCellSize.width) / 2
        }

        currentPageIndex = index

        // Calculate scroll offset for the target position
        let targetOffset: CGPoint = calculateTargetOffset(from: targetFrame, and: scrollPosition)
        setContentOffset(targetOffset, animated: animated)
    }

    private func scrollToCell(_ cell: InfiniteCollectionViewCell, at scrollPosition: ScrollPosition, animated: Bool) {
        let cellFrame = containerView.convert(cell.frame, to: self)
        let targetOffset: CGPoint = calculateTargetOffset(from: cellFrame, and: scrollPosition)
        setContentOffset(targetOffset, animated: animated)
    }

    private func calculateTargetOffset(from targetFrame: CGRect, and scrollPosition: ScrollPosition) -> CGPoint {
        let bounds = adjustedBounds()

        var targetOffset = contentOffset

        if isHorizontal {
            if scrollPosition.contains(.left) {
                targetOffset.x = targetFrame.minX - adjustedContentInset.left
            } else if scrollPosition.contains(.centeredHorizontally) {
                targetOffset.x = targetFrame.midX - bounds.width / 2
            } else if scrollPosition.contains(.right) {
                targetOffset.x = targetFrame.maxX - bounds.width - adjustedContentInset.left
            }
        } else {
            if scrollPosition.contains(.top) {
                targetOffset.y = targetFrame.minY - adjustedContentInset.top
            } else if scrollPosition.contains(.centeredVertically) {
                targetOffset.y = targetFrame.midY - bounds.height / 2
            } else if scrollPosition.contains(.bottom) {
                targetOffset.y = targetFrame.maxY - bounds.height - adjustedContentInset.top
            }
        }

        return targetOffset
    }

    private func adjustedBounds() -> CGRect {
        var adjustedBounds = bounds
        adjustedBounds.origin.x += adjustedContentInset.left
        adjustedBounds.origin.y += adjustedContentInset.top
        adjustedBounds.size.width -= (adjustedContentInset.left + adjustedContentInset.right)
        adjustedBounds.size.height -= (adjustedContentInset.top + adjustedContentInset.bottom)
        return adjustedBounds
    }
}

// MARK: UIScrollViewDelegate

extension InfiniteCollectionView: UIScrollViewDelegate {
    // MARK: - Pagination

    private func handlePagination(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) -> Int? {
        guard !visibleCells.isEmpty else { return nil }

        let velocityComponent = axisComponent(of: velocity)
        let currentOffset = axisOffset
        let viewportCenter = axisBounds / 2
        let currentCenter = currentOffset + viewportCenter

        // Find all cells and their positions
        let cellPositions: [(cell: InfiniteCollectionViewCell, center: CGFloat, index: Int)] = visibleCells
            .compactMap { cell in
                guard let index = cellIndexes[cell] else { return nil }
                let cellFrame = containerView.convert(cell.frame, to: self)
                let center = isHorizontal ? cellFrame.midX : cellFrame.midY
                return (cell, center, index)
            }
            .sorted { $0.center < $1.center }

        guard !cellPositions.isEmpty else { return nil }

        // Find current cell (closest to current center)
        let currentCell = cellPositions.min(by: {
            abs($0.center - currentCenter) < abs($1.center - currentCenter)
        })

        guard let current = currentCell else { return nil }

        // Determine target index based on velocity
        let targetIndex: Int

        if velocityComponent > 0 {
            // Scrolling forward
            targetIndex = currentPageIndex + 1
        } else if velocityComponent < 0 {
            // Scrolling backward
            targetIndex = currentPageIndex - 1
        } else {
            // No velocity - stay on current cell
            targetIndex = current.index
        }


        // Get uniform cell size (all cells have same size when paging)
        let cellSize = current.cell.frame.size
        let cellDimension = axisComponent(of: cellSize)
        let pageSize = cellDimension + spacing

        // Calculate target position
        let delta = targetIndex - current.index
        let targetCenter = current.center + (CGFloat(delta) * pageSize)
        let targetOffset = targetCenter - axisBounds / 2

        targetContentOffset.pointee = isHorizontal
            ? CGPoint(x: targetOffset, y: contentOffset.y)
            : CGPoint(x: contentOffset.x, y: targetOffset)

        return targetIndex
    }


    // MARK: - Scrolling

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewDidScroll?(scrollView)
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewDidZoom?(scrollView)
    }

    // MARK: - Dragging

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewWillBeginDragging?(scrollView)
    }

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if _isPagingEnabled {
            let newPage = handlePagination(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset) ?? currentPageIndex

            if newPage != currentPageIndex {
                currentPageIndex = newPage
                infiniteDelegate?.infiniteCollectionViewDidChangePage(self, page: newPage)
            }

            var proposedCell: InfiniteCollectionViewCell?
            var proposedCellIndex: Int?

            for element in cellIndexes {
                if newPage == element.value {
                    proposedCell = element.key
                    proposedCellIndex = element.value
                    break
                }
            }

            if let proposedCell, let proposedCellIndex {
                infiniteDelegate?.infiniteCollectionView(self, willScrollTo: proposedCell, forItemAt: proposedCellIndex)
            }
        }

        infiniteDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        infiniteDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
    }

    // MARK: - Decelerating

    public func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewWillBeginDecelerating?(scrollView)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewDidEndDecelerating?(scrollView)
    }

    // MARK: - Animation

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // Recenter after animation completes
        recenterIfNecessary()

        infiniteDelegate?.scrollViewDidEndScrollingAnimation?(scrollView)
    }

    // MARK: - Zooming

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        infiniteDelegate?.viewForZooming?(in: scrollView)
    }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        infiniteDelegate?.scrollViewWillBeginZooming?(scrollView, with: view)
    }

    public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        infiniteDelegate?.scrollViewDidEndZooming?(scrollView, with: view, atScale: scale)
    }

    // MARK: - Scroll To Top

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        infiniteDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewDidScrollToTop?(scrollView)
    }

    // MARK: - Index Display

    public func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        infiniteDelegate?.scrollViewDidChangeAdjustedContentInset?(scrollView)
    }
}

extension UIView {
    @inlinable
    func origin(for direction: ScrollDirection) -> CGFloat {
        direction == .horizontal ? frame.origin.x : frame.origin.y
    }

    @inlinable
    func minEdge(for direction: ScrollDirection) -> CGFloat {
        direction == .horizontal ? frame.minX : frame.minY
    }

    @inlinable
    func maxEdge(for direction: ScrollDirection) -> CGFloat {
        direction == .horizontal ? frame.maxX : frame.maxY
    }
}
