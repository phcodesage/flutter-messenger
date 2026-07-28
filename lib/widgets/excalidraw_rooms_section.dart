import 'package:flutter/material.dart';

import '../models/excalidraw_room.dart';
import '../screens/excalidraw_board_screen.dart';
import '../services/excalidraw_rooms_service.dart';

/// The "Boards" half of the Excalidraw modal: whiteboards hosted by our own
/// backend, scoped to this conversation, with create / rename / delete / open.
///
/// Sits above the pinned-links list rather than replacing it — pinned links are
/// messages someone highlighted, these are boards that live here.
class ExcalidrawRoomsSection extends StatefulWidget {
  const ExcalidrawRoomsSection({
    super.key,
    required this.conversationKey,
    this.myUserId,
    this.onCountChanged,
  });

  /// `dm:<lo>-<hi>` or `group:<id>`. Null while the peer is still unknown.
  final String? conversationKey;
  final int? myUserId;

  /// Fired after any change so the header badge can be refreshed.
  final VoidCallback? onCountChanged;

  @override
  State<ExcalidrawRoomsSection> createState() => ExcalidrawRoomsSectionState();
}

class ExcalidrawRoomsSectionState extends State<ExcalidrawRoomsSection> {
  static const Color _orange = Color(0xFFF97316);
  static const Color _orangeDeep = Color(0xFFEA580C);

  final TextEditingController _titleController = TextEditingController();

  List<ExcalidrawRoom> _rooms = const [];
  bool _loading = true;
  bool _creating = false;
  String? _error;

  /// Board pending a second tap to confirm deletion, and its reset timer.
  int? _armedForDelete;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = widget.conversationKey;
    if (key == null) {
      if (mounted) setState(() { _loading = false; _rooms = const []; });
      return;
    }
    final rooms = await ExcalidrawRoomsService.list(key);
    if (!mounted) return;
    setState(() {
      _rooms = rooms;
      _loading = false;
    });
  }

  /// Re-fetch from outside (a socket event told us the list moved).
  Future<void> reload() => _load();

  Future<void> _create() async {
    final key = widget.conversationKey;
    final title = _titleController.text.trim();
    if (key == null) {
      setState(() => _error = 'Open a conversation first.');
      return;
    }
    if (title.isEmpty) {
      setState(() => _error = 'Give the whiteboard a name first.');
      return;
    }

    setState(() { _creating = true; _error = null; });
    try {
      final room = await ExcalidrawRoomsService.create(
        title: title,
        conversationKey: key,
      );
      if (!mounted) return;
      setState(() {
        // Keyed insert, not a blind prepend: the server echoes our own create
        // over the socket, and that echo triggers a reload which can land
        // either side of this response. Two paths, one board.
        _rooms = [room, ..._rooms.where((r) => r.id != room.id)];
        _titleController.clear();
      });
      await ExcalidrawRoomsService.markSeen(key);
      widget.onCountChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _rename(ExcalidrawRoom room) async {
    final controller = TextEditingController(text: room.title);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF191729),
        title: const Text('Edit title', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            counterText: '',
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: _orange),
            ),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save', style: TextStyle(color: _orange)),
          ),
        ],
      ),
    );
    controller.dispose();

    final title = next?.trim();
    if (title == null || title.isEmpty || title == room.title) return;

    try {
      final updated = await ExcalidrawRoomsService.rename(room.id, title);
      if (!mounted) return;
      setState(() {
        _rooms = [
          for (final r in _rooms) if (r.id == room.id) updated else r,
        ];
      });
      final key = widget.conversationKey;
      if (key != null) await ExcalidrawRoomsService.markSeen(key);
      widget.onCountChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  Future<void> _delete(ExcalidrawRoom room) async {
    // Two-step confirm in the button itself, matching the web modal.
    if (_armedForDelete != room.id) {
      setState(() => _armedForDelete = room.id);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted && _armedForDelete == room.id) {
          setState(() => _armedForDelete = null);
        }
      });
      return;
    }

    setState(() => _armedForDelete = null);
    try {
      await ExcalidrawRoomsService.delete(room.id);
      if (!mounted) return;
      setState(() => _rooms = _rooms.where((r) => r.id != room.id).toList());
      widget.onCountChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  Future<void> _open(ExcalidrawRoom room) async {
    // In-app, not the system browser: the WebView carries the JWT on the first
    // request and keeps the resulting session, which an external browser has no
    // way to do.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExcalidrawBoardScreen(
          url: ExcalidrawRoomsService.boardUrl(room),
          title: room.title,
        ),
      ),
    );
  }

  String _message(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _titleController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _create(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'New whiteboard name...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: _orange),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _creating ? null : _create,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _orangeDeep,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Create'),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: _body(),
        ),
      ],
    );
  }

  Widget _sectionHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: Row(
        children: [
          const Icon(Icons.dashboard_customize_outlined,
              color: _orange, size: 17),
          const SizedBox(width: 8),
          const Text(
            'Boards on this chat',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_rooms.length}',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _orange),
          ),
        ),
      );
    }
    if (_rooms.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Text(
          'No boards in this chat yet — create one above.',
          style: TextStyle(color: Colors.white38, fontSize: 12.5),
        ),
      );
    }
    return Column(
      children: [for (final room in _rooms) _roomCard(room)],
    );
  }

  Widget _roomCard(ExcalidrawRoom room) {
    final armed = _armedForDelete == room.id;
    final by = room.createdByUsername;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _orange.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Sending a photo or note into a board only works while somebody
              // has it open, so that state belongs next to the name.
              Icon(
                Icons.circle,
                size: 9,
                color: room.live ? const Color(0xFF4ADE80) : Colors.white24,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  room.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _rename(room),
                icon: const Icon(Icons.edit_outlined,
                    color: Colors.white54, size: 18),
                tooltip: 'Edit title',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(6),
              ),
            ],
          ),
          if (by != null)
            Padding(
              padding: const EdgeInsets.only(left: 17, top: 2),
              child: Text(
                room.live
                    ? 'by $by · open now (${room.clients})'
                    : 'by $by · nobody has this open',
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _open(room),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: _orange.withValues(alpha: 0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _delete(room),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        armed ? const Color(0xFFFDE047) : const Color(0xFFF87171),
                    side: BorderSide(
                      color: armed
                          ? const Color(0xFFFDE047)
                          : const Color(0xFFF87171).withValues(alpha: 0.6),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                  child: Text(armed ? 'Confirm?' : 'Delete'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
