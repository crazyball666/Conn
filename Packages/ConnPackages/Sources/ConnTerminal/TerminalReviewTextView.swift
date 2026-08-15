#if canImport(UIKit)
    import UIKit

    /// A frozen, native text surface for review and selection. The live terminal remains
    /// attached underneath and continues parsing bytes while this view owns touch input.
    public final class TerminalReviewTextView: UIView {
        public let textView = UITextView(frame: .zero)
        public let closeButton = UIButton(type: .system)
        public var onClose: (() -> Void)?

        public override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        public required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        public func display(
            _ snapshot: TerminalReviewSnapshot,
            selectingUTF16Offset: Int?,
            font: UIFont,
            foregroundColor: UIColor,
            backgroundColor: UIColor
        ) {
            textView.font = font
            textView.textColor = foregroundColor
            textView.backgroundColor = backgroundColor
            self.backgroundColor = backgroundColor
            textView.text = snapshot.text

            if let selectingUTF16Offset {
                let length = min(max(textView.textStorage.length - selectingUTF16Offset, 0), 1)
                textView.selectedRange = NSRange(
                    location: min(max(selectingUTF16Offset, 0), textView.textStorage.length),
                    length: length
                )
                textView.scrollRangeToVisible(textView.selectedRange)
                DispatchQueue.main.async { [weak textView] in
                    _ = textView?.becomeFirstResponder()
                }
            } else if let visibleStart = snapshot.utf16Offset(
                line: snapshot.visibleLineRange.lowerBound,
                column: 0
            ) {
                let range = NSRange(location: visibleStart, length: 0)
                textView.selectedRange = range
                textView.scrollRangeToVisible(range)
            }
        }

        private func configure() {
            accessibilityIdentifier = "terminal.review"
            backgroundColor = .black

            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.accessibilityIdentifier = "terminal.review.text"
            textView.isEditable = false
            textView.isSelectable = true
            textView.alwaysBounceVertical = true
            textView.showsVerticalScrollIndicator = true
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainerInset = UIEdgeInsets(top: 44, left: 12, bottom: 16, right: 12)
            textView.adjustsFontForContentSizeCategory = false
            addSubview(textView)

            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: "xmark")
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.68)
            configuration.cornerStyle = .capsule
            closeButton.configuration = configuration
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.accessibilityIdentifier = "terminal.review.close"
            closeButton.accessibilityLabel = "关闭"
            closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
            addSubview(closeButton)

            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
                closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
                closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            ])
        }

        @objc private func close() {
            onClose?()
        }
    }
#endif
