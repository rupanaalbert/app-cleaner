import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sparkle_cleaner/core/theme.dart';
import 'package:sparkle_cleaner/data/geolocation.dart';
import 'package:sparkle_cleaner/data/jobs_repository.dart';
import 'package:sparkle_cleaner/features/active_job/active_job_screen.dart';

// A live device pass on this machine can't reach 'completed' without real
// Firebase credentials — RealtimeService.publishStatus runs inside the same
// transaction as every en_route/arrived status update and throws without
// them, which is a separate, pre-existing gap from the animation itself.
// This isolates just the completion screen to verify the animated checkmark
// (added in the 2026-08-27 depth/font/illustration pass) renders without
// throwing, independent of that gap.
class _CompletedJobRepository implements JobsRepository {
  @override
  Future<List<ScheduledJob>> schedule() async => const [];

  @override
  Future<JobDetail> job(String bookingId) async => JobDetail(
        bookingId: bookingId,
        reference: 'SPK-TEST01',
        serviceCode: 'standard',
        serviceName: 'Standard Clean',
        scheduledAt: DateTime(2026, 8, 26, 10),
        durationMin: 135,
        payoutCents: 6080,
        tipCents: 0,
        status: 'completed',
        specialInstructions: null,
        line1: '31 Pleasant St',
        line2: null,
        city: 'Lowell',
        region: 'MA',
        postalCode: '01852',
        accessNotes: 'Key under the pot.',
      );

  @override
  Future<ScheduledJob> updateStatus(String bookingId, String status,
          {GeoPoint? location, int? actualDurationMin}) =>
      throw UnimplementedError('not exercised by this test');

  @override
  Future<List<PhotoTarget>> presignPhotos(String bookingId, String phase, int count) =>
      throw UnimplementedError('not exercised by this test');

  @override
  Future<void> uploadPhoto(String uploadUrl, List<int> bytes) =>
      throw UnimplementedError('not exercised by this test');
}

void main() {
  testWidgets('completed job shows the animated checkmark without throwing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: Sparkle.theme(),
      home: ActiveJobScreen(
        repository: _CompletedJobRepository(),
        locator: const FakeLocator(),
        bookingId: 'test-booking',
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // let the elasticOut TweenAnimationBuilder settle

    expect(tester.takeException(), isNull);
    expect(find.text('Job complete'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
