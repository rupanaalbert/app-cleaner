import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/booking_repository.dart';

enum BookingStep { service, home, schedule, review }

enum QuoteState { idle, loading, ready, failed }

/// Drives the four-step booking flow and keeps a live quote in sync with the
/// draft.
///
/// Re-quoting is debounced by 400 ms and every request carries a sequence
/// number: a slow response for an earlier draft is discarded rather than
/// overwriting a newer price. Getting this wrong is how a customer taps
/// "3 bedrooms" and watches the total flicker back to the 2-bedroom figure.
class BookingController extends ChangeNotifier {
  BookingController({required this.repository, required String propertyId}) {
    draft.propertyId = propertyId;
  }

  final BookingRepository repository;
  final draft = BookingDraft();

  BookingStep step = BookingStep.service;
  QuoteState quoteState = QuoteState.idle;
  Quote? quote;
  String? quoteError;
  bool submitting = false;
  String? submitError;
  ConfirmedBooking? confirmed;

  Timer? _debounce;
  int _sequence = 0;
  String _idempotencyKey = _newKey();

  static const _order = BookingStep.values;
  bool get canGoBack => step != BookingStep.service;
  int get stepIndex => _order.indexOf(step);

  bool get canAdvance => switch (step) {
        BookingStep.service => true,
        BookingStep.home => draft.bedrooms > 0 && draft.bathrooms > 0,
        BookingStep.schedule => draft.hasSchedule,
        BookingStep.review => quote != null && !quote!.isStale && !submitting,
      };

  void next() {
    if (step == BookingStep.review || !canAdvance) return;
    step = _order[stepIndex + 1];
    notifyListeners();
  }

  void back() {
    if (!canGoBack) return;
    step = _order[stepIndex - 1];
    notifyListeners();
  }

  void setService(String code) {
    draft.serviceCode = code;
    _scheduleQuote();
  }

  void toggleAddon(String code) {
    draft.addonCodes.contains(code) ? draft.addonCodes.remove(code) : draft.addonCodes.add(code);
    _scheduleQuote();
  }

  void setRooms({int? bedrooms, int? bathrooms, int? squareFeet}) {
    if (bedrooms != null) draft.bedrooms = bedrooms.clamp(1, 8);
    if (bathrooms != null) draft.bathrooms = bathrooms.clamp(1, 6);
    if (squareFeet != null) draft.squareFeet = squareFeet;
    _scheduleQuote();
  }

  void setSchedule(DateTime when) {
    draft.scheduledAt = when;
    _scheduleQuote(immediate: true);
  }

  void setInstructions(String value) => draft.specialInstructions = value;
  void setEntryMethod(String value) {
    draft.entryMethod = value;
    notifyListeners();
  }

  void _scheduleQuote({bool immediate = false}) {
    notifyListeners(); // reflect the selection instantly, price catches up
    if (!draft.isQuotable) return;

    _debounce?.cancel();
    if (immediate) {
      refreshQuote();
    } else {
      _debounce = Timer(const Duration(milliseconds: 400), refreshQuote);
    }
  }

  Future<void> refreshQuote() async {
    if (!draft.isQuotable) return;
    final mine = ++_sequence;
    quoteState = QuoteState.loading;
    quoteError = null;
    notifyListeners();

    try {
      final result = await repository.requestQuote(draft);
      if (mine != _sequence) return; // a newer draft is already in flight
      quote = result;
      quoteState = QuoteState.ready;
    } catch (e) {
      if (mine != _sequence) return;
      quoteState = QuoteState.failed;
      quoteError = e is ApiFailure ? e.message : 'Could not price this yet.';
    }
    notifyListeners();
  }

  Future<void> submit(String paymentMethodId) async {
    if (quote == null || submitting) return;
    submitting = true;
    submitError = null;
    notifyListeners();

    try {
      confirmed = await repository.confirm(
        quoteId: quote!.id,
        paymentMethodId: paymentMethodId,
        draft: draft,
        idempotencyKey: _idempotencyKey,
      );
    } on QuoteExpired {
      // Prices move; re-quote and let the customer see the new number before
      // charging them. Never silently book at a different price.
      _idempotencyKey = _newKey();
      await refreshQuote();
      submitError = 'Prices refreshed while you were deciding. Check the total and confirm again.';
    } on CardDeclined catch (e) {
      _idempotencyKey = _newKey();
      submitError = e.message;
    } catch (e) {
      submitError = '$e';
    } finally {
      submitting = false;
      notifyListeners();
    }
  }

  static String _newKey() =>
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
