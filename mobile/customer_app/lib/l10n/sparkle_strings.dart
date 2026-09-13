import 'package:flutter/widgets.dart';

/// Hand-written localization — no `flutter gen-l10n`/ARB codegen, on purpose.
/// This machine has no Flutter toolchain to run the generator or catch a
/// mistake in it, so every string here is plain, reviewable Dart instead of
/// generated code. `SparkleStrings.of(context)` returns the active language's
/// implementation; wire `SparkleStringsDelegate()` into `MaterialApp` and it
/// resolves from the device locale automatically (English/Spanish only —
/// anything else falls back to English, see `isSupported` below).
abstract class SparkleStrings {
  static const supportedLocales = [Locale('en'), Locale('es')];

  static SparkleStrings of(BuildContext context) =>
      Localizations.of<SparkleStrings>(context, SparkleStrings)!;

  // ---- service step ----
  String get whatKindOfClean;
  String get addAnything;
  String get addAnythingSub;
  String serviceName(String code);
  String servicePitch(String code);
  String serviceDetail(String code);
  String addonName(String code);

  // ---- home step ----
  String get tellUsAboutHome;
  String get roomCountSub;
  String get bedrooms;
  String get bathrooms;
  String get squareFootage;
  String get squareFootageSub;
  String get squareFootageHint;
  String get sqFt;
  String fewer(String label);
  String more(String label);

  // ---- schedule step ----
  String get whenWorksForYou;
  String get scheduleSub;
  String get noTimesLeft;
  String get howDoWeGetIn;
  String get entryHome;
  String get entryDoorman;
  String get entryLockbox;
  String get entryHiddenKey;

  // ---- review step ----
  String get almostDone;
  String get rowService;
  String get rowHome;
  String get rowWhen;
  String get rowExpectedTime;
  String get rowExtras;
  String get change;
  String homeSummary(int bedrooms, int bathrooms, int? squareFeet);
  String get anythingCleanerShouldKnow;
  String get instructionsHint;
  String get heldNowChargedAfter;
  String get heldNowBodyNoQuote;
  String heldNowBody(String amount);
  String get backgroundCheckedTitle;
  String get backgroundCheckedBody;
  String get refreshingPrice;
  String get priceExpired;
  String priceHolds(String mmss);

  // ---- duration formatting (two registers: "3h 30m" vs "3 hours 30 minutes") ----
  String hoursShort(int totalMinutes);
  String hoursLong(int totalMinutes);

  // ---- price ledger / booking flow chrome ----
  String get estimate;
  String get total;
  String get pickATime;
  String allIn(String hours);
  String get continueLabel;
  String get reviewBooking;
  String get confirmAndBook;
  String get weekendRateNote;
  String get eveningRateNote;

  // ---- paypal approval ----
  String get approveWithPaypal;
  String couldNotLoadPaypal(String error);

  // ---- confirmation sheet ----
  String bookedFor(String when);
  String findingCleanerBody(String amount);
  String referenceLabel(String reference);
  String get viewBooking;
}

class SparkleStringsEn extends SparkleStrings {
  @override
  String get whatKindOfClean => 'What kind of clean?';
  @override
  String get addAnything => 'Add anything?';
  @override
  String get addAnythingSub => 'Optional extras, priced individually.';
  @override
  String serviceName(String code) => switch (code) {
        'deep' => 'Deep Clean',
        _ => 'Standard Clean',
      };
  @override
  String servicePitch(String code) => switch (code) {
        'deep' => 'First clean or a reset',
        _ => 'Keeping on top of things',
      };
  @override
  String serviceDetail(String code) => switch (code) {
        'deep' =>
          'Everything in a standard clean, plus baseboards, inside appliances, grout, and behind furniture. Takes about twice as long.',
        _ => 'Floors, surfaces, kitchen, bathrooms, and a general tidy.',
      };
  @override
  String addonName(String code) => switch (code) {
        'inside_fridge' => 'Inside fridge',
        'inside_oven' => 'Inside oven',
        'interior_windows' => 'Interior windows',
        'laundry' => 'Laundry (1 load)',
        _ => code,
      };

  @override
  String get tellUsAboutHome => 'Tell us about your home';
  @override
  String get roomCountSub => 'Room count sets the price and the time we book for your cleaner.';
  @override
  String get bedrooms => 'Bedrooms';
  @override
  String get bathrooms => 'Bathrooms';
  @override
  String get squareFootage => 'Square footage';
  @override
  String get squareFootageSub => 'Optional. A rough number is fine — it only adjusts larger homes.';
  @override
  String get squareFootageHint => 'e.g. 1600';
  @override
  String get sqFt => 'sq ft';
  @override
  String fewer(String label) => 'Fewer $label';
  @override
  String more(String label) => 'More $label';

  @override
  String get whenWorksForYou => 'When works for you?';
  @override
  String get scheduleSub => 'Book at least 2 hours ahead. Weekends cost a little more.';
  @override
  String get noTimesLeft => 'No times left today. Try tomorrow.';
  @override
  String get howDoWeGetIn => 'How do we get in?';
  @override
  String get entryHome => "I'll be home";
  @override
  String get entryDoorman => 'Doorman or front desk';
  @override
  String get entryLockbox => 'Lockbox or keypad';
  @override
  String get entryHiddenKey => 'Key is hidden on site';

  @override
  String get almostDone => 'Almost done';
  @override
  String get rowService => 'Service';
  @override
  String get rowHome => 'Home';
  @override
  String get rowWhen => 'When';
  @override
  String get rowExpectedTime => 'Expected time on site';
  @override
  String get rowExtras => 'Extras';
  @override
  String get change => 'Change';
  @override
  String homeSummary(int bedrooms, int bathrooms, int? squareFeet) =>
      '$bedrooms bed · $bathrooms bath${squareFeet != null ? ' · $squareFeet sq ft' : ''}';
  @override
  String get anythingCleanerShouldKnow => 'Anything your cleaner should know?';
  @override
  String get instructionsHint => 'Gate code, where supplies live, a room to skip, a nervous cat…';
  @override
  String get heldNowChargedAfter => 'Held now, charged after';
  @override
  String get heldNowBodyNoQuote =>
      'We place a hold on your card and only charge once the clean is finished.';
  @override
  String heldNowBody(String amount) =>
      'We hold $amount on your card now and charge it once the clean is finished. '
      'Cancel more than 12 hours ahead and the hold is released in full.';
  @override
  String get backgroundCheckedTitle => 'Every cleaner is background checked';
  @override
  String get backgroundCheckedBody =>
      'Identity and criminal record checks are re-run yearly. Your address is only shared once a cleaner accepts.';
  @override
  String get refreshingPrice => 'Refreshing your price…';
  @override
  String get priceExpired => 'Price expired — refreshing.';
  @override
  String priceHolds(String mmss) => 'This price holds for $mmss.';

  @override
  String hoursShort(int totalMinutes) {
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  @override
  String hoursLong(int totalMinutes) {
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return m == 1 ? '1 minute' : '$m minutes';
    if (m == 0) return h == 1 ? '1 hour' : '$h hours';
    return '${h}h ${m}m';
  }

  @override
  String get estimate => 'Estimate';
  @override
  String get total => 'Total';
  @override
  String get pickATime => 'Pick a time';
  @override
  String allIn(String hours) => '$hours · all in';
  @override
  String get continueLabel => 'Continue';
  @override
  String get reviewBooking => 'Review booking';
  @override
  String get confirmAndBook => 'Confirm and book';
  @override
  String get weekendRateNote => 'Weekend rate applied — 15% above weekday pricing.';
  @override
  String get eveningRateNote => 'Evening rate applied — 10% above daytime pricing.';

  @override
  String get approveWithPaypal => 'Approve with PayPal';
  @override
  String couldNotLoadPaypal(String error) => 'Could not load PayPal: $error';

  @override
  String bookedFor(String when) => 'Booked for $when';
  @override
  String findingCleanerBody(String amount) =>
      "We're finding your cleaner now — usually within a few minutes. "
      'Your card is on hold for $amount and is only charged once the clean is done.';
  @override
  String referenceLabel(String reference) => 'Reference $reference';
  @override
  String get viewBooking => 'View booking';
}

class SparkleStringsEs extends SparkleStrings {
  @override
  String get whatKindOfClean => '¿Qué tipo de limpieza?';
  @override
  String get addAnything => '¿Algo más?';
  @override
  String get addAnythingSub => 'Extras opcionales, con precio individual.';
  @override
  String serviceName(String code) => switch (code) {
        'deep' => 'Limpieza profunda',
        _ => 'Limpieza estándar',
      };
  @override
  String servicePitch(String code) => switch (code) {
        'deep' => 'Primera limpieza o para empezar de nuevo',
        _ => 'Mantener todo al día',
      };
  @override
  String serviceDetail(String code) => switch (code) {
        'deep' =>
          'Todo lo de la limpieza estándar, más zócalos, interior de electrodomésticos, lechada y detrás de los muebles. Toma aproximadamente el doble de tiempo.',
        _ => 'Pisos, superficies, cocina, baños y un orden general.',
      };
  @override
  String addonName(String code) => switch (code) {
        'inside_fridge' => 'Interior del refrigerador',
        'inside_oven' => 'Interior del horno',
        'interior_windows' => 'Ventanas interiores',
        'laundry' => 'Lavandería (1 carga)',
        _ => code,
      };

  @override
  String get tellUsAboutHome => 'Cuéntanos sobre tu hogar';
  @override
  String get roomCountSub =>
      'El número de habitaciones define el precio y el tiempo que reservamos para tu limpiador.';
  @override
  String get bedrooms => 'Habitaciones';
  @override
  String get bathrooms => 'Baños';
  @override
  String get squareFootage => 'Metraje cuadrado';
  @override
  String get squareFootageSub => 'Opcional. Un número aproximado está bien — solo ajusta hogares más grandes.';
  @override
  String get squareFootageHint => 'ej. 150';
  @override
  String get sqFt => 'm²';
  @override
  String fewer(String label) => 'Menos $label';
  @override
  String more(String label) => 'Más $label';

  @override
  String get whenWorksForYou => '¿Cuándo te conviene?';
  @override
  String get scheduleSub => 'Reserva con al menos 2 horas de anticipación. Los fines de semana cuestan un poco más.';
  @override
  String get noTimesLeft => 'No quedan horarios hoy. Intenta mañana.';
  @override
  String get howDoWeGetIn => '¿Cómo entramos?';
  @override
  String get entryHome => 'Estaré en casa';
  @override
  String get entryDoorman => 'Portero o recepción';
  @override
  String get entryLockbox => 'Caja de seguridad o teclado';
  @override
  String get entryHiddenKey => 'Hay una llave escondida en el lugar';

  @override
  String get almostDone => 'Ya casi';
  @override
  String get rowService => 'Servicio';
  @override
  String get rowHome => 'Hogar';
  @override
  String get rowWhen => 'Cuándo';
  @override
  String get rowExpectedTime => 'Tiempo estimado en el lugar';
  @override
  String get rowExtras => 'Extras';
  @override
  String get change => 'Cambiar';
  @override
  String homeSummary(int bedrooms, int bathrooms, int? squareFeet) =>
      '$bedrooms hab · $bathrooms baño${bathrooms == 1 ? '' : 's'}${squareFeet != null ? ' · $squareFeet m²' : ''}';
  @override
  String get anythingCleanerShouldKnow => '¿Algo que tu limpiador deba saber?';
  @override
  String get instructionsHint => 'Código del portón, dónde están los insumos, una habitación a evitar, un gato nervioso…';
  @override
  String get heldNowChargedAfter => 'Retenido ahora, cobrado después';
  @override
  String get heldNowBodyNoQuote =>
      'Retenemos un monto en tu tarjeta y solo lo cobramos una vez terminada la limpieza.';
  @override
  String heldNowBody(String amount) =>
      'Retenemos $amount en tu tarjeta ahora y lo cobramos una vez terminada la limpieza. '
      'Cancela con más de 12 horas de anticipación y la retención se libera por completo.';
  @override
  String get backgroundCheckedTitle => 'Todo limpiador pasa una verificación de antecedentes';
  @override
  String get backgroundCheckedBody =>
      'Las verificaciones de identidad y antecedentes penales se repiten cada año. Tu dirección solo se comparte una vez que un limpiador acepta.';
  @override
  String get refreshingPrice => 'Actualizando tu precio…';
  @override
  String get priceExpired => 'Precio vencido — actualizando.';
  @override
  String priceHolds(String mmss) => 'Este precio se mantiene por $mmss.';

  @override
  String hoursShort(int totalMinutes) {
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  @override
  String hoursLong(int totalMinutes) {
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return m == 1 ? '1 minuto' : '$m minutos';
    if (m == 0) return h == 1 ? '1 hora' : '$h horas';
    return '${h}h ${m}m';
  }

  @override
  String get estimate => 'Estimado';
  @override
  String get total => 'Total';
  @override
  String get pickATime => 'Elige un horario';
  @override
  String allIn(String hours) => '$hours · todo incluido';
  @override
  String get continueLabel => 'Continuar';
  @override
  String get reviewBooking => 'Revisar reserva';
  @override
  String get confirmAndBook => 'Confirmar y reservar';
  @override
  String get weekendRateNote => 'Tarifa de fin de semana aplicada — 15% sobre el precio de entre semana.';
  @override
  String get eveningRateNote => 'Tarifa nocturna aplicada — 10% sobre el precio diurno.';

  @override
  String get approveWithPaypal => 'Aprobar con PayPal';
  @override
  String couldNotLoadPaypal(String error) => 'No se pudo cargar PayPal: $error';

  @override
  String bookedFor(String when) => 'Reservado para $when';
  @override
  String findingCleanerBody(String amount) =>
      'Estamos buscando a tu limpiador — normalmente toma solo unos minutos. '
      'Tu tarjeta tiene una retención de $amount y solo se cobra cuando termina la limpieza.';
  @override
  String referenceLabel(String reference) => 'Referencia $reference';
  @override
  String get viewBooking => 'Ver reserva';
}

class SparkleStringsDelegate extends LocalizationsDelegate<SparkleStrings> {
  const SparkleStringsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'es'].contains(locale.languageCode);

  @override
  Future<SparkleStrings> load(Locale locale) async {
    return locale.languageCode == 'es' ? SparkleStringsEs() : SparkleStringsEn();
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<SparkleStrings> old) => false;
}
