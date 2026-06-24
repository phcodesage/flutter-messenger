import 'package:flutter/material.dart';

class ChatComposerShell extends StatelessWidget {
  const ChatComposerShell({
    super.key,
    required this.composerInset,
    required this.backgroundColor,
    required this.padding,
    required this.child,
    this.borderTopColor = const Color(0xFF3D3D3D),
    this.applyBottomSafeArea = true,
  });

  final double composerInset;
  final Color backgroundColor;
  final EdgeInsetsGeometry padding;
  final Color borderTopColor;
  final Widget child;

  /// When false, the bottom safe-area inset is NOT added here. Used while the
  /// emoji panel is open: that overlay already pads for the bottom safe area, so
  /// applying it here too would leave a duplicate band of empty space between
  /// the input and the emoji grid.
  final bool applyBottomSafeArea;

  @override
  Widget build(BuildContext context) {
    final targetInset = composerInset < 0 ? 0.0 : composerInset;

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: applyBottomSafeArea,
      minimum: EdgeInsets.only(bottom: targetInset),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor,
          border: Border(top: BorderSide(color: borderTopColor, width: 1)),
        ),
        child: child,
      ),
    );
  }
}
