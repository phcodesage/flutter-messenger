import 'package:flutter/material.dart';

import '../models/excalidraw_room.dart';
import '../services/excalidraw_rooms_service.dart';

/// Sheet asking which whiteboard to send a message or photo into.
///
/// Only boards belonging to the conversation are offered — the same scoping the
/// list uses. Boards somebody currently has open are shown first and marked
/// live, because content can only land in a board with a client in it.
class ExcalidrawRoomPicker extends StatefulWidget {
  const ExcalidrawRoomPicker({super.key, required this.conversationKey});

  final String conversationKey;

  /// Returns the chosen board, or null if dismissed.
  static Future<ExcalidrawRoom?> show(
    BuildContext context, {
    required String conversationKey,
  }) {
    return showModalBottomSheet<ExcalidrawRoom>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ExcalidrawRoomPicker(conversationKey: conversationKey),
    );
  }

  @override
  State<ExcalidrawRoomPicker> createState() => _ExcalidrawRoomPickerState();
}

class _ExcalidrawRoomPickerState extends State<ExcalidrawRoomPicker> {
  static const Color _orange = Color(0xFFF97316);

  List<ExcalidrawRoom> _rooms = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rooms = await ExcalidrawRoomsService.list(widget.conversationKey);
    // Live boards first: a dormant board is rarely the one you meant.
    rooms.sort((a, b) {
      if (a.live == b.live) return 0;
      return a.live ? -1 : 1;
    });
    if (!mounted) return;
    setState(() {
      _rooms = rooms;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _orange.withValues(alpha: 0.28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const Row(
              children: [
                Icon(Icons.draw_outlined, color: _orange, size: 18),
                SizedBox(width: 8),
                Text(
                  'Send to Excalidraw',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _orange,
                  ),
                ),
              )
            else if (_rooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18, horizontal: 4),
                child: Text(
                  'No boards in this chat yet — create one from the Excalidraw '
                  'button first.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _rooms.length,
                  itemBuilder: (context, index) {
                    final room = _rooms[index];
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        Icons.circle,
                        size: 10,
                        color: room.live
                            ? const Color(0xFF4ADE80)
                            : Colors.white24,
                      ),
                      title: Text(
                        room.title,
                        style: TextStyle(
                          color: room.live ? Colors.white : Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        room.live
                            ? 'Open now (${room.clients})'
                            : 'Nobody has this open',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11.5,
                        ),
                      ),
                      onTap: () => Navigator.pop(context, room),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
