import 'dart:async';

import 'package:flutter/material.dart';

import '../models/common_phrase.dart';
import '../services/common_phrases_api.dart';

/// Max number of mobile-pinned phrases shown on the quick bar.
const int kMobileMaxPins = 3;

/// Shows the Common Phrases management bottom sheet (add / generate / pin /
/// delete). Shared by 1-on-1 and group chat. [onChanged] is invoked after the
/// sheet closes (and whenever pins change) so the caller can refresh its bar.
Future<void> showCommonPhrasesSheet(
  BuildContext context, {
  required CommonPhrasesApi api,
  required VoidCallback onChanged,
}) async {
  final TextEditingController phraseInputController = TextEditingController();
  List<CommonPhrase> allPhrases = [];
  bool isLoading = true;
  bool isSaving = false;
  bool isGenerating = false;
  bool isPinning = false;
  String? errorText;
  bool showPinnedTab = false; // false = Unpinned, true = Pinned

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    requestFocus: false,
    useSafeArea: true,
    backgroundColor: const Color(0xFF161625),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (modalContext) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> loadPhrases() async {
            try {
              setModalState(() {
                isLoading = true;
                errorText = null;
              });
              final fetched = await api.fetch(limit: 20);
              fetched.sort((a, b) {
                if (a.isPinnedMobile && b.isPinnedMobile) {
                  return (a.pinOrderMobile ?? 99).compareTo(
                    b.pinOrderMobile ?? 99,
                  );
                }
                if (a.isPinnedMobile) return -1;
                if (b.isPinnedMobile) return 1;
                return b.usageCount.compareTo(a.usageCount);
              });
              if (ctx.mounted) {
                setModalState(() {
                  allPhrases = fetched;
                  isLoading = false;
                });
              }
            } catch (e) {
              if (ctx.mounted) {
                setModalState(() {
                  isLoading = false;
                  errorText = 'Failed to load phrases';
                });
              }
            }
          }

          if (isLoading && allPhrases.isEmpty) loadPhrases();

          final pinned = allPhrases.where((p) => p.isPinnedMobile).toList();
          final unpinned = allPhrases.where((p) => !p.isPinnedMobile).toList();
          final displayed = showPinnedTab ? pinned : unpinned;

          Future<void> addPhrase() async {
            final text = phraseInputController.text.trim();
            if (text.isEmpty) return;
            setModalState(() {
              isSaving = true;
              errorText = null;
            });
            try {
              final saved = await api.savePhrase(text);
              phraseInputController.clear();
              if (ctx.mounted) {
                setModalState(() {
                  allPhrases = [saved, ...allPhrases];
                  isSaving = false;
                });
              }
              await loadPhrases();
              onChanged();
            } catch (e) {
              if (ctx.mounted) {
                setModalState(() => errorText = 'Failed to save phrase');
              }
            } finally {
              if (ctx.mounted) setModalState(() => isSaving = false);
            }
          }

          Future<void> deletePhrase(CommonPhrase phrase) async {
            int? id = phrase.id;
            if (id == null) {
              try {
                final saved = await api.savePhrase(phrase.phrase);
                id = saved.id;
              } catch (_) {}
            }
            if (id == null) return;
            try {
              await api.deletePhrase(id);
              await loadPhrases();
              onChanged();
            } catch (e) {
              if (ctx.mounted) {
                setModalState(() => errorText = 'Failed to delete phrase');
              }
            }
          }

          Future<void> generateWithAi() async {
            setModalState(() {
              isGenerating = true;
              errorText = null;
            });
            try {
              final generated = await api.generatePhrase();
              if (ctx.mounted) {
                phraseInputController.value = TextEditingValue(
                  text: generated,
                  selection: TextSelection.collapsed(offset: generated.length),
                );
                setModalState(() => isGenerating = false);
              }
            } catch (e) {
              if (ctx.mounted) {
                setModalState(() {
                  isGenerating = false;
                  final msg = e.toString().replaceFirst('Exception: ', '');
                  errorText = 'AI error: $msg';
                });
              }
            }
          }

          Future<void> togglePin(CommonPhrase phrase) async {
            int? id = phrase.id;
            if (id == null) {
              try {
                setModalState(() => isPinning = true);
                final saved = await api.savePhrase(phrase.phrase);
                id = saved.id;
              } catch (e) {
                if (ctx.mounted) {
                  setModalState(() {
                    isPinning = false;
                    errorText = 'Could not save phrase';
                  });
                }
                return;
              }
            }
            if (id == null) return;
            setModalState(() {
              isPinning = true;
              errorText = null;
            });
            try {
              if (phrase.isPinnedMobile) {
                await api.unpinPhrase(id);
              } else {
                if (pinned.length >= kMobileMaxPins) {
                  setModalState(() {
                    isPinning = false;
                    errorText =
                        'Max $kMobileMaxPins pins on mobile — unpin one first';
                  });
                  return;
                }
                await api.pinPhrase(id);
              }
              await loadPhrases();
              onChanged();
            } catch (e) {
              if (ctx.mounted) {
                setModalState(
                  () => errorText =
                      e.toString().replaceFirst('Exception: ', ''),
                );
              }
            } finally {
              if (ctx.mounted) setModalState(() => isPinning = false);
            }
          }

          Widget buildPhraseRow(CommonPhrase phrase) {
            final isPinnedMobile = phrase.isPinnedMobile;
            final isPinnedWeb = phrase.isPinnedWeb;
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF202036),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isPinnedMobile
                      ? const Color(0xFF6D28D9).withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.07),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                dense: true,
                leading: GestureDetector(
                  onTap: isPinning ? null : () => togglePin(phrase),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isPinnedMobile
                          ? const Color(0xFF6D28D9)
                          : const Color(0xFF2A2A47),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPinnedMobile
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      size: 16,
                      color: isPinnedMobile
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                title: Text(
                  phrase.phrase,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Text(
                        phrase.isDefault ? 'DEFAULT' : 'CUSTOM',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      if (isPinnedWeb) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0E7490)
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: const Color(0xFF0E7490)
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: const Text(
                            'WEB PIN',
                            style: TextStyle(
                              color: Color(0xFF67E8F9),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                trailing: GestureDetector(
                  onTap: () => deletePhrase(phrase),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Text(
                      'Del',
                      style: TextStyle(
                        color: Color(0xFFF87171),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          Widget buildTabToggle() {
            Widget tab(String label, bool active, {int? badge}) {
              return GestureDetector(
                onTap: () =>
                    setModalState(() => showPinnedTab = label == 'Pinned'),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? const Color(0xFF6D28D9)
                        : const Color(0xFF252542),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: active ? Colors.white : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? Colors.white.withValues(alpha: 0.25)
                                : Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$badge',
                            style: TextStyle(
                              color: active ? Colors.white : Colors.white54,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }

            return Row(
              children: [
                tab('Unpinned', !showPinnedTab, badge: unpinned.length),
                const SizedBox(width: 8),
                tab('Pinned', showPinnedTab, badge: pinned.length),
                const Spacer(),
                if (pinned.length < kMobileMaxPins)
                  Text(
                    '${kMobileMaxPins - pinned.length} pin slot${kMobileMaxPins - pinned.length == 1 ? '' : 's'} free',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 11,
                    ),
                  )
                else
                  Row(
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 12,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Pins full',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
              ],
            );
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.85,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Common Phrases',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Tap the pin icon to toggle pinned status',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            color: Colors.white70,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _PhraseInputField(
                    controller: phraseInputController,
                    isGenerating: isGenerating,
                    onSubmitted: addPhrase,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _modalTextButton(
                          label: 'Add Phrase',
                          icon: Icons.add,
                          color: const Color(0xFF6D28D9),
                          loading: isSaving,
                          onTap: isSaving ? null : addPhrase,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _modalTextButton(
                          label: 'Generate with AI',
                          icon: Icons.auto_awesome,
                          color: const Color(0xFF0F766E),
                          loading: isGenerating,
                          onTap: isGenerating ? null : generateWithAi,
                        ),
                      ),
                    ],
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Color(0xFFF87171),
                          size: 14,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            errorText!,
                            style: const TextStyle(
                              color: Color(0xFFF87171),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (!isLoading && allPhrases.isNotEmpty) ...[
                    buildTabToggle(),
                    const SizedBox(height: 10),
                  ],
                  Expanded(
                    child: isLoading
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF6D28D9),
                            ),
                          )
                        : allPhrases.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline,
                                  size: 40,
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No phrases yet.\nType one above and tap +',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : displayed.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  showPinnedTab
                                      ? Icons.push_pin_outlined
                                      : Icons.chat_bubble_outline,
                                  size: 36,
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  showPinnedTab
                                      ? 'No pinned phrases yet.\nTap the pin icon on any phrase.'
                                      : 'All phrases are pinned!',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: displayed.length,
                            itemBuilder: (_, i) => buildPhraseRow(displayed[i]),
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  phraseInputController.dispose();
  onChanged();
}

Widget _modalTextButton({
  required String label,
  required IconData icon,
  required Color color,
  required bool loading,
  required VoidCallback? onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      height: 40,
      decoration: BoxDecoration(
        color: onTap == null ? color.withValues(alpha: 0.35) : color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
      ),
    ),
  );
}

class _PhraseInputField extends StatefulWidget {
  final TextEditingController controller;
  final bool isGenerating;
  final VoidCallback onSubmitted;

  const _PhraseInputField({
    required this.controller,
    required this.isGenerating,
    required this.onSubmitted,
  });

  @override
  State<_PhraseInputField> createState() => _PhraseInputFieldState();
}

class _PhraseInputFieldState extends State<_PhraseInputField>
    with SingleTickerProviderStateMixin {
  late AnimationController _gradientCtrl;

  @override
  void initState() {
    super.initState();
    _gradientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isGenerating) _gradientCtrl.repeat();
  }

  @override
  void didUpdateWidget(_PhraseInputField old) {
    super.didUpdateWidget(old);
    if (widget.isGenerating && !_gradientCtrl.isAnimating) {
      _gradientCtrl.repeat();
    } else if (!widget.isGenerating && _gradientCtrl.isAnimating) {
      _gradientCtrl.stop();
      _gradientCtrl.reset();
    }
  }

  @override
  void dispose() {
    _gradientCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      maxLength: 200,
      maxLines: 1,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => widget.onSubmitted(),
      decoration: InputDecoration(
        hintText: 'Type a new phrase…',
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        counterStyle: const TextStyle(color: Colors.white24, fontSize: 10),
        filled: true,
        fillColor: const Color(0xFF252542),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
      ),
    );

    if (!widget.isGenerating) return field;

    return AnimatedBuilder(
      animation: _gradientCtrl,
      builder: (context, child) {
        return CustomPaint(
          painter: _GradientBorderPainter(progress: _gradientCtrl.value),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: field,
            ),
          ),
        );
      },
    );
  }
}

/// Paints a sweeping gradient border while AI generation is running.
class _GradientBorderPainter extends CustomPainter {
  final double progress;
  static const _radius = 10.0;
  static const _stroke = 2.0;

  const _GradientBorderPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rRect = RRect.fromRectAndRadius(rect, const Radius.circular(_radius));

    final angle = progress * 2 * 3.141592653589793;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..shader = SweepGradient(
        startAngle: angle,
        endAngle: angle + 3.141592653589793 * 2,
        colors: const [
          Color(0xFF0F766E),
          Color(0xFF6D28D9),
          Color(0xFFa78bfa),
          Color(0xFF0F766E),
        ],
      ).createShader(rect);

    canvas.drawRRect(rRect, paint);
  }

  @override
  bool shouldRepaint(_GradientBorderPainter old) => old.progress != progress;
}
