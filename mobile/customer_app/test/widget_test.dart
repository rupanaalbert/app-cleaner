import 'package:flutter_test/flutter_test.dart';

import 'package:sparkle_customer/main.dart';

void main() {
  testWidgets('app builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const SparkleCustomerApp());
    await tester.pump();
  });
}
