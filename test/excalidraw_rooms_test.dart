import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_messenger/models/excalidraw_room.dart';
import 'package:flutter_messenger/services/excalidraw_rooms_service.dart';

void main() {
  group('conversation key', () {
    test('both peers derive the same key', () {
      // The web bug this guards against: one side keyed a board dm:1-1 while
      // the other keyed dm:1-2, so neither saw the other's boards.
      expect(
        ExcalidrawRoomsService.dmKey(2, 1),
        ExcalidrawRoomsService.dmKey(1, 2),
      );
      expect(ExcalidrawRoomsService.dmKey(2, 1), 'dm:1-2');
    });

    test('a self chat is still a valid key', () {
      expect(ExcalidrawRoomsService.dmKey(7, 7), 'dm:7-7');
    });

    test('group keys are the group id', () {
      expect(ExcalidrawRoomsService.groupKey(42), 'group:42');
    });
  });

  group('room id / key generation', () {
    test('room id is 20 lowercase hex characters', () {
      for (var i = 0; i < 200; i++) {
        final id = ExcalidrawRoomsService.generateRoomId();
        expect(id, matches(RegExp(r'^[a-f0-9]{20}$')), reason: 'got "$id"');
      }
    });

    test('room key is 22 url-safe unpadded base64 characters', () {
      // Anything else and Excalidraw refuses to import the key, so the board
      // silently fails to open.
      for (var i = 0; i < 200; i++) {
        final key = ExcalidrawRoomsService.generateRoomKey();
        expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')), reason: 'got "$key"');
      }
    });

    test('ids are not repeated', () {
      final ids = {for (var i = 0; i < 500; i++) ExcalidrawRoomsService.generateRoomId()};
      expect(ids.length, 500);
    });
  });

  group('parsing', () {
    ExcalidrawRoom parse(Map<String, dynamic> extra) => ExcalidrawRoom.fromJson({
      'id': 1,
      'room_id': 'abcdef0123456789abcd',
      'room_key': 'uWxJ06B0lR1dgOWw9Aw0jQ',
      'title': 'Board',
      ...extra,
    });

    test('naive server timestamps are read as UTC, not local', () {
      // The server sends datetime.utcnow() with no zone. Reading that as local
      // time would shift every comparison by the device offset.
      final room = parse({'created_at': '2026-07-28T12:00:00.000000'});
      expect(room.createdAt!.isUtc, isTrue);
      expect(room.createdAt, DateTime.utc(2026, 7, 28, 12));
    });

    test('a blank title falls back rather than rendering empty', () {
      expect(parse({'title': '   '}).title, 'Untitled board');
    });

    test('missing live/clients default to closed', () {
      final room = parse({});
      expect(room.live, isFalse);
      expect(room.clients, 0);
    });
  });

  group('unread counting', () {
    ExcalidrawRoom room({
      required int id,
      required int author,
      required DateTime created,
      DateTime? updated,
    }) => ExcalidrawRoom(
      id: id,
      roomId: 'r$id',
      roomKey: 'k$id',
      title: 'Board $id',
      createdByUserId: author,
      createdAt: created,
      updatedAt: updated ?? created,
    );

    final t0 = DateTime.utc(2026, 7, 28, 10);
    final t1 = DateTime.utc(2026, 7, 28, 11);
    final t2 = DateTime.utc(2026, 7, 28, 12);

    test("a peer's new board is unread", () {
      expect(
        ExcalidrawRoomsService.countUnread(
          rooms: [room(id: 1, author: 99, created: t2)],
          since: t1,
          myUserId: 5,
        ),
        1,
      );
    });

    test('a board older than the last visit is not unread', () {
      expect(
        ExcalidrawRoomsService.countUnread(
          rooms: [room(id: 1, author: 99, created: t0)],
          since: t1,
          myUserId: 5,
        ),
        0,
      );
    });

    test('my own untouched board never badges me, even on a fresh device', () {
      expect(
        ExcalidrawRoomsService.countUnread(
          rooms: [room(id: 1, author: 5, created: t2)],
          since: null,
          myUserId: 5,
        ),
        0,
      );
    });

    test('my board renamed by someone else does badge me', () {
      expect(
        ExcalidrawRoomsService.countUnread(
          rooms: [room(id: 1, author: 5, created: t0, updated: t2)],
          since: t1,
          myUserId: 5,
        ),
        1,
      );
    });

    test("a peer's board is unread on a device that never opened the modal", () {
      expect(
        ExcalidrawRoomsService.countUnread(
          rooms: [room(id: 1, author: 99, created: t0)],
          since: null,
          myUserId: 5,
        ),
        1,
      );
    });

    test('counts only the boards that changed', () {
      expect(
        ExcalidrawRoomsService.countUnread(
          rooms: [
            room(id: 1, author: 99, created: t2),
            room(id: 2, author: 99, created: t2),
            room(id: 3, author: 99, created: t0),
            room(id: 4, author: 5, created: t2),
          ],
          since: t1,
          myUserId: 5,
        ),
        2,
      );
    });
  });
}
