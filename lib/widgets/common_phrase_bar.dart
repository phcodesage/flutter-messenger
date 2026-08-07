import 'package:flutter/material.dart';
import '../models/common_phrase.dart';

/// Widget to display common phrase chips
/// Shows above the input area, sized like a ring doorbell (compact/small)
class CommonPhraseBar extends StatelessWidget {
  final List<CommonPhrase> phrases;
  final bool hidden;
  final Future<void> Function(CommonPhrase) onChipTap;
  final double scale;

  const CommonPhraseBar({
    Key? key,
    required this.phrases,
    required this.hidden,
    required this.onChipTap,
    this.scale = 1.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (hidden || phrases.isEmpty) {
      return const SizedBox.shrink();
    }

    String _formatPhraseForChip(String phrase) {
      final words = phrase
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList(growable: false);
      if (words.length <= 3) return phrase.trim();

      final splitIndex = (words.length / 2).ceil();
      final firstLine = words.take(splitIndex).join(' ');
      final secondLine = words.skip(splitIndex).join(' ');
      return '$firstLine\n$secondLine';
    }

    // Keep three room-scoped quick replies visible in the chat composer.
    final visiblePhrases = phrases.take(3).toList();
    
    // Calculate total text length to distribute space dynamically
    final totalLength = visiblePhrases.fold(0, (sum, p) => sum + p.phrase.length);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 6 * scale, vertical: 6 * scale),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        spacing: 4 * scale,
        children: List.generate(
          visiblePhrases.length,
          (index) {
            final chip = visiblePhrases[index];
            
            // Calculate flex based on phrase length (relative to total).
            // Minimum flex of 1, scaled up to 4.
            final flexValue =
              ((chip.phrase.length / totalLength) * 2).ceil().clamp(1, 4);
            
            return Expanded(
              flex: flexValue,
              child: GestureDetector(
                onTap: () => onChipTap(chip),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 6 * scale,
                    vertical: 4 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6D28D9),
                    borderRadius: BorderRadius.circular(16 * scale),
                    border: Border.all(
                      color: const Color(0xFF7C3AED),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    _formatPhraseForChip(chip.phrase),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    softWrap: true,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12 * scale,
                      fontFamily: 'Roboto',
                      fontWeight: FontWeight.w500,
                      height: 0.95,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
