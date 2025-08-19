import UIKit

open class InfiniteCollectionViewCell: UIView {
    public let contentView: UIView

    private(set) var reuseIdentifier: String?

    public override init(frame: CGRect) {
        contentView = UIView()
        super.init(frame: frame)
        setupContentView()
    }

    required public init?(coder: NSCoder) {
        contentView = UIView()
        super.init(coder: coder)
        setupContentView()
    }

    required convenience public init() {
        self.init(frame: .zero)
    }

    private func setupContentView() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    open func prepareForReuse() {
        // Override in subclasses to reset cell state
    }

    internal func setReuseIdentifier(_ identifier: String) {
        reuseIdentifier = identifier
    }
}
