import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/chat_composer_shell.dart';

class ChatComposerPanel extends StatelessWidget {
  const ChatComposerPanel({
    super.key,
    required this.scale,
    required this.backgroundColor,
    required this.composerInset,
    required this.showEmojiPicker,
    required this.isEditing,
    required this.stablePanelHeight,
    required this.onShowEmojiPickerModal,
    required this.onClipboardPasteShortcut,
    required this.onInputContextMenuOpened,
    required this.onTextChanged,
    required this.onSend,
    required this.messageController,
    required this.inputFocusNode,
    required this.inputScrollController,
    required this.buildDoorbellComposerButton,
    required this.isComposerMultiline,
    required this.editPreview,
    required this.replyPreview,
    required this.sendToManyQuickAction,
    required this.unifiedActionsBar,
    required this.inlineEmojiPickerBuilder,
    this.actionsBelowInput = false,
  });

  final double scale;
  final Color backgroundColor;
  final double composerInset;
  final bool showEmojiPicker;
  final bool isEditing;
  final double stablePanelHeight;
  final VoidCallback onShowEmojiPickerModal;
  final VoidCallback onClipboardPasteShortcut;
  final VoidCallback onInputContextMenuOpened;
  final void Function(String) onTextChanged;
  final VoidCallback onSend;
  final TextEditingController messageController;
  final FocusNode inputFocusNode;
  final ScrollController inputScrollController;
  final Widget Function({
    required bool showLabel,
    required double iconSize,
    required EdgeInsets padding,
  })
  buildDoorbellComposerButton;
  final bool Function(String, TextStyle, double) isComposerMultiline;
  final Widget editPreview;
  final Widget replyPreview;
  final Widget sendToManyQuickAction;
  final Widget unifiedActionsBar;
  final Widget Function(double) inlineEmojiPickerBuilder;

  /// When true (desktop/web layout) the action buttons render *below* the
  /// message input to mirror the web composer. Mobile keeps them above.
  final bool actionsBelowInput;

  @override
  Widget build(BuildContext context) {
    final messageTextStyle = TextStyle(
      color: Colors.white,
      fontSize: 20 * scale,
      fontFamily: 'Roboto',
      height: 1.2,
    );

    // Build the input subtree ONCE per ChatComposerPanel build. It is held
    // stable through ValueListenableBuilder.child so selection-drag changes
    // (which mutate TextEditingValue.selection on every pointer move) do
    // not rebuild the EditableText subtree mid-gesture.
    final Widget stableInput = _ComposerInput(
      scale: scale,
      messageController: messageController,
      inputFocusNode: inputFocusNode,
      inputScrollController: inputScrollController,
      messageTextStyle: messageTextStyle,
      onClipboardPasteShortcut: onClipboardPasteShortcut,
      onInputContextMenuOpened: onInputContextMenuOpened,
      onTextChanged: onTextChanged,
    );

    return RepaintBoundary(
      child: ChatComposerShell(
        composerInset: composerInset,
        backgroundColor: backgroundColor,
        padding: EdgeInsets.only(
          left: 8 * scale,
          right: 12 * scale,
          top: 6,
          bottom: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            editPreview,
            replyPreview,
            sendToManyQuickAction,
            // Mobile: actions above the input. Desktop: below (see end of Column).
            if (!actionsBelowInput && !showEmojiPicker) unifiedActionsBar,
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: messageController,
              child: stableInput,
              builder: (context, value, child) {
                const sendButtonColor = Color(0xFF6D28D9);
                final hasDraftText =
                    value.text.trim().isNotEmpty &&
                    !_isStampOnlyDraft(value.text);

                return RepaintBoundary(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Reserves below mirror the REAL widths of the surrounding
                      // controls so the multi-line estimate flips exactly when
                      // the text genuinely wraps — not a few chars early, which
                      // used to make the composer "jump" to its expanded layout
                      // before a second line existed.
                      final emojiSlotWidth = 38.0 * scale; // left emoji button
                      final sendButtonReserve =
                          72.0 * scale; // Send btn + margin
                      final doorbellReserve = hasDraftText
                          ? (44.0 * scale) // icon-only mic/doorbell
                          : (104.0 * scale); // doorbell with label
                      final estimatedTextMaxWidth = math.max(
                        120.0,
                        constraints.maxWidth -
                            sendButtonReserve -
                            emojiSlotWidth -
                            doorbellReserve,
                      );

                      final isComposerExpanded = isComposerMultiline(
                        value.text,
                        messageTextStyle,
                        estimatedTextMaxWidth,
                      );

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Container(
                              constraints: BoxConstraints(
                                minHeight: 44 * scale,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E2430),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Row(
                                crossAxisAlignment: isComposerExpanded
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.center,
                                children: [
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom: isComposerExpanded ? 10 : 0,
                                    ),
                                    child: _buildComposerIconButton(
                                      onPressed: onShowEmojiPickerModal,
                                      icon: showEmojiPicker
                                          ? Icons.keyboard_outlined
                                          : Icons
                                                .sentiment_satisfied_alt_outlined,
                                      iconSize: 24 * scale,
                                      padding: EdgeInsets.all(6 * scale),
                                      tooltip: showEmojiPicker
                                          ? 'Keyboard'
                                          : 'Emoji',
                                    ),
                                  ),
                                  Expanded(child: child!),
                                  Padding(
                                    padding: EdgeInsets.only(
                                      right: 6 * scale,
                                      bottom: isComposerExpanded ? 10 : 0,
                                    ),
                                    child: buildDoorbellComposerButton(
                                      showLabel: !hasDraftText,
                                      iconSize: 24 * scale,
                                      padding: EdgeInsets.all(6 * scale),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Container(
                            margin: EdgeInsets.only(
                              left: 6,
                              bottom: isComposerExpanded ? 10 : 0,
                            ),
                            child: ElevatedButton(
                              onPressed: onSend,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: sendButtonColor,
                                foregroundColor: Colors.white,
                                overlayColor: Colors.white.withValues(
                                  alpha: 0.22,
                                ),
                                padding: EdgeInsets.symmetric(
                                  horizontal: 11 * scale,
                                  vertical: 10 * scale,
                                ),
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              child: Text(
                                isEditing ? 'Save' : 'Send',
                                style: TextStyle(
                                  fontSize: 13.5 * scale,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
            // Desktop: actions below the input to mirror the web composer.
            if (actionsBelowInput && !showEmojiPicker) unifiedActionsBar,
            if (showEmojiPicker) inlineEmojiPickerBuilder(stablePanelHeight),
          ],
        ),
      ),
    );
  }

  bool _isStampOnlyDraft(String text) {
    return text.trim().isEmpty;
  }

  Widget _buildComposerIconButton({
    required VoidCallback onPressed,
    required IconData icon,
    required double iconSize,
    required EdgeInsets padding,
    required String tooltip,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: iconSize, color: Colors.white),
      padding: padding,
      tooltip: tooltip,
    );
  }
}

/// Stable input subtree. Kept out of the ValueListenableBuilder rebuild path
/// so selection-drag (which fires TextEditingValue notifications on every
/// pointer move) does not rebuild the EditableText and cancel the active
/// drag gesture.
class _ComposerInput extends StatelessWidget {
  const _ComposerInput({
    required this.scale,
    required this.messageController,
    required this.inputFocusNode,
    required this.inputScrollController,
    required this.messageTextStyle,
    required this.onClipboardPasteShortcut,
    required this.onInputContextMenuOpened,
    required this.onTextChanged,
  });

  final double scale;
  final TextEditingController messageController;
  final FocusNode inputFocusNode;
  final ScrollController inputScrollController;
  final TextStyle messageTextStyle;
  final VoidCallback onClipboardPasteShortcut;
  final VoidCallback onInputContextMenuOpened;
  final void Function(String) onTextChanged;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Color(0xFF25D366),
          selectionHandleColor: Color(0xFF25D366),
          selectionColor: Color(0x6637D67A),
        ),
      ),
      child: Scrollbar(
        controller: inputScrollController,
        thumbVisibility: false,
        thickness: 3,
        radius: const Radius.circular(2),
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                _ComposerPasteImageIntent(),
            SingleActivator(LogicalKeyboardKey.keyV, control: true):
                _ComposerPasteImageIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _ComposerPasteImageIntent:
                  CallbackAction<_ComposerPasteImageIntent>(
                    onInvoke: (intent) {
                      onClipboardPasteShortcut();
                      return null;
                    },
                  ),
            },
            child: TextField(
              key: const ValueKey('message_input'),
              controller: messageController,
              focusNode: inputFocusNode,
              scrollController: inputScrollController,
              onTapOutside: (_) {},
              contextMenuBuilder: (context, editableTextState) {
                onInputContextMenuOpened();
                final buttonItems = editableTextState.contextMenuButtonItems;
                final customItems = <ContextMenuButtonItem>[
                  ContextMenuButtonItem(
                    label: 'Paste',
                    onPressed: () {
                      ContextMenuController.removeAny();
                      onClipboardPasteShortcut();
                    },
                  ),
                  ...buttonItems,
                ];

                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editableTextState.contextMenuAnchors,
                  buttonItems: customItems,
                );
              },
              dragStartBehavior: DragStartBehavior.start,
              cursorColor: const Color(0xFF25D366),
              cursorHeight: 26 * scale,
              cursorWidth: 2.6,
              scrollPadding: EdgeInsets.only(bottom: 220 * scale),
              style: messageTextStyle,
              decoration: InputDecoration(
                hintText: 'Message...',
                hintMaxLines: 1,
                hintStyle: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 19 * scale,
                  fontFamily: 'Roboto',
                  height: 1.2,
                ),
                border: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.only(
                  left: 0,
                  right: 4,
                  top: 10,
                  bottom: 10,
                ),
                isDense: true,
              ),
              onChanged: onTextChanged,
              textAlign: TextAlign.start,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              enableInteractiveSelection: true,
              // Keep the keyboard's suggestion strip and voice-input mic
              // available (Gboard hides both when enableSuggestions is false).
              // The word-replacement-on-tap bug that prompted disabling these is
              // already prevented elsewhere: every TextEditingValue we set
              // clears the composing region (composing: TextRange.empty).
              autocorrect: true,
              enableSuggestions: true,
              stylusHandwritingEnabled: false,
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerPasteImageIntent extends Intent {
  const _ComposerPasteImageIntent();
}
