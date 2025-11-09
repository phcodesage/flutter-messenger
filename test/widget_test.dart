import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_messenger/main.dart';

void main() {
  testWidgets('Loads Sign in screen', (tester) async {
    await tester.pumpWidget(const MessengerApp());
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });
}
