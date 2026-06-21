import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../utils/chat_scroll_physics.dart';

class ChatMessageList extends StatelessWidget {
  const ChatMessageList({
    super.key,
    required this.scale,
    required this.controller,
    required this.isLoading,
    required this.messages,
    required this.hasMoreMessages,
    required this.isLoadingMore,
    required this.onLoadMoreMessages,
    required this.itemBuilder,
    required this.emptyStateBuilder,
    this.loadingWidgetBuilder,
    this.bottomSpacer,
  });

  final double scale;
  final ScrollController controller;
  final bool isLoading;
  final List<Message> messages;
  final bool hasMoreMessages;
  final bool isLoadingMore;
  final VoidCallback onLoadMoreMessages;
  final Widget Function(BuildContext, int) itemBuilder;
  final Widget Function(BuildContext) emptyStateBuilder;
  final Widget Function(BuildContext)? loadingWidgetBuilder;

  /// Live keyboard inset (logical px). When provided, a reactive spacer of this
  /// height is inserted as the reverse list's first (bottom-most) item so the
  /// newest message rides up above the keyboard-overlaying composer. Only the
  /// spacer rebuilds when the inset changes — the list and its items do not.
  final ValueListenable<double>? bottomSpacer;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return loadingWidgetBuilder?.call(context) ?? _buildLoadingState();
    }

    if (messages.isEmpty) {
      return emptyStateBuilder(context);
    }

    return Stack(
      children: [
        RepaintBoundary(
          child: ListView.builder(
            controller: controller,
            reverse: true,
            padding: EdgeInsets.fromLTRB(
              16 * scale,
              16 * scale,
              16 * scale,
              4 * scale,
            ),
            physics: const ChatScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            // One viewport of pre-build buffer keeps fast scrolling smooth
            // without decoding ~2 extra screens of off-screen image bubbles
            // (the old height * 2 caused memory/decode pressure on
            // image-heavy chats).
            cacheExtent: MediaQuery.sizeOf(context).height,
            itemCount:
                messages.length +
                (hasMoreMessages ? 1 : 0) +
                (bottomSpacer != null ? 1 : 0),
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemBuilder: (context, index) {
              // Reverse list → index 0 is the bottom. The keyboard spacer sits
              // there so the newest message lifts above the composer.
              if (bottomSpacer != null) {
                if (index == 0) {
                  return ValueListenableBuilder<double>(
                    valueListenable: bottomSpacer!,
                    builder: (context, inset, _) => SizedBox(height: inset),
                  );
                }
                index -= 1;
              }
              if (index == messages.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: isLoadingMore
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Color(0xFF7C3AED),
                              ),
                            ),
                          )
                        : TextButton.icon(
                            onPressed: onLoadMoreMessages,
                            icon: const Icon(
                              Icons.history,
                              size: 16,
                              color: Color(0xFF7C3AED),
                            ),
                            label: const Text(
                              'Load more messages',
                              style: TextStyle(
                                color: Color(0xFF7C3AED),
                                fontSize: 13,
                              ),
                            ),
                          ),
                  ),
                );
              }
              return itemBuilder(context, index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      itemBuilder: (context, index) {
        final isMe = index % 2 == 0;
        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
              width: 180,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        );
      },
    );
  }
}
