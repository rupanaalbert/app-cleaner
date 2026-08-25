import 'package:flutter_test/flutter_test.dart';

import 'package:sparkle_cleaner/main.dart';

void main() {
  testWidgets('app builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const SparkleCleanerApp());
    await tester.pump();
  });
}
