import 'package:flutter_messenger/models/group.dart';
import 'package:flutter_messenger/models/message.dart';
import 'package:flutter_messenger/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    StorageService.useMilitaryTime = false;
  });

  test('direct message display time uses the stable epoch timestamp', () {
    final now = DateTime.now();
    final sentAt = DateTime(now.year, now.month, now.day, 7, 52);
    final message = Message(
      id: 1,
      senderId: 10,
      recipientId: 20,
      content: 'hello',
      messageType: 'text',
      // Deliberately different: optimistic and confirmed ISO strings can use
      // different timezone representations, but timestampMs is unambiguous.
      timestamp: '2000-01-01T00:00:00Z',
      timestampMs: sentAt.millisecondsSinceEpoch,
      isRead: false,
      status: 'sending',
      threadId: 'thread-1',
      reactions: const {},
      isDeleted: false,
    );

    expect(message.formattedTime, '7:52 AM');
  });

  test('group message display time uses the stable epoch timestamp', () {
    final now = DateTime.now();
    final sentAt = DateTime(now.year, now.month, now.day, 19, 5);
    final message = GroupMessage(
      id: 2,
      messageId: 2,
      groupId: 3,
      senderId: 10,
      content: 'hello group',
      messageType: 'text',
      timestamp: '2000-01-01T00:00:00Z',
      timestampMs: sentAt.millisecondsSinceEpoch,
    );

    expect(message.formattedTime, '7:05 PM');
  });
}
