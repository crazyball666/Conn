#if canImport(UIKit)
    import ConnUI
    import UIKit

    /// A frozen, native text surface for review and selection. The live terminal remains
    /// attached underneath and continues parsing bytes while this view owns touch input.
    public final class TerminalReviewTextView: UIView, UIEditMenuInteractionDelegate,
        UIGestureRecognizerDelegate, UITextViewDelegate
    {
        public let textView = UITextView(frame: .zero)
        public var onClose: (() -> Void)?
        var clipboardWriter: (String) -> Void = { UIPasteboard.general.string = $0 }

        private var editMenuInteraction: UIEditMenuInteraction!

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
                textView.selectedRange = TerminalReviewSelectionPolicy.wordRange(
                    in: snapshot.text,
                    utf16Offset: selectingUTF16Offset
                )
                textView.scrollRangeToVisible(textView.selectedRange)
                _ = textView.becomeFirstResponder()
                DispatchQueue.main.async { [weak self] in self?.presentEditMenu() }
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
            // UIKit only renders its draggable selection handles reliably while the text
            // view owns first-responder status. Keep it editable at the UIKit level so the
            // existing terminal keyboard remains mounted, then reject every mutation below.
            textView.isEditable = true
            textView.isSelectable = true
            textView.delegate = self
            textView.keyboardType = .default
            textView.autocapitalizationType = .none
            textView.autocorrectionType = .no
            textView.spellCheckingType = .no
            textView.smartQuotesType = .no
            textView.smartDashesType = .no
            textView.smartInsertDeleteType = .no
            textView.inputAssistantItem.leadingBarButtonGroups = []
            textView.inputAssistantItem.trailingBarButtonGroups = []
            textView.alwaysBounceVertical = true
            textView.showsVerticalScrollIndicator = true
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
            textView.adjustsFontForContentSizeCategory = false
            addSubview(textView)

            editMenuInteraction = UIEditMenuInteraction(delegate: self)
            addInteraction(editMenuInteraction)

            let outsideTap = UITapGestureRecognizer(target: self, action: #selector(handleReviewTap(_:)))
            outsideTap.cancelsTouchesInView = false
            outsideTap.delegate = self
            textView.addGestureRecognizer(outsideTap)

            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        public func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            _ = (interaction, configuration, suggestedActions)
            let copy = UIAction(title: L("复制"), image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.performEditAction(.copy)
            }
            let selectAll = UIAction(title: L("全选"), image: UIImage(systemName: "selection.pin.in.out")) {
                [weak self] _ in self?.performEditAction(.selectAll)
            }
            let done = UIAction(title: L("完成"), image: UIImage(systemName: "checkmark")) {
                [weak self] _ in self?.performEditAction(.done)
            }
            return UIMenu(options: .displayInline, children: [copy, selectAll, done])
        }

        func performEditAction(_ action: TerminalReviewEditAction) {
            switch TerminalReviewSelectionPolicy.effect(
                for: action,
                text: textView.text,
                selectedRange: textView.selectedRange
            ) {
            case let .copy(text, dismisses):
                clipboardWriter(text)
                if dismisses { onClose?() }
            case let .selection(range):
                textView.selectedRange = range
                textView.scrollRangeToVisible(range)
                DispatchQueue.main.async { [weak self] in self?.presentEditMenu() }
            case .dismiss:
                onClose?()
            case .none:
                break
            }
        }

        func dismissIfOutsideSelection(atUTF16Offset offset: Int) {
            let range = textView.selectedRange
            guard range.location != NSNotFound, range.length > 0 else { return }
            guard !NSLocationInRange(offset, range) else { return }
            onClose?()
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            _ = (gestureRecognizer, otherGestureRecognizer)
            return true
        }

        public func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            _ = (textView, range, text)
            return false
        }

        private func presentEditMenu() {
            guard window != nil,
                  let selectedTextRange = textView.selectedTextRange,
                  !selectedTextRange.isEmpty
            else { return }
            let selectionRect = textView.firstRect(for: selectedTextRange)
            let sourcePoint = convert(
                CGPoint(x: selectionRect.midX, y: selectionRect.maxY),
                from: textView
            )
            editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: sourcePoint
            ))
        }

        @objc private func handleReviewTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let point = gesture.location(in: textView)
            guard let position = textView.closestPosition(to: point) else { return }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            dismissIfOutsideSelection(atUTF16Offset: offset)
        }
    }
#endif
