import 'package:flutter/material.dart';

/// Hand-written localization — no `flutter gen-l10n`/ARB codegen, on purpose.
/// This machine has no Flutter toolchain to run the generator or catch a
/// mistake in it, so every string here is plain, reviewable Dart instead of
/// generated code. `SparkleStrings.of(context)` returns the active language's
/// implementation; wire `SparkleStringsDelegate()` into `MaterialApp` and it
/// resolves from the device locale automatically (English/Spanish only —
/// anything else falls back to English, see `isSupported` below).
///
/// Same pattern as `customer_app/lib/l10n/sparkle_strings.dart` — kept as an
/// independent copy per app rather than a shared package, matching how
/// `core/theme.dart` is already duplicated per app in this project.
abstract class SparkleStrings {
  static const supportedLocales = [Locale('en'), Locale('es')];

  static SparkleStrings of(BuildContext context) =>
      Localizations.of<SparkleStrings>(context, SparkleStrings)!;

  // ---- bottom nav ----
  String get navDiscover;
  String get navSchedule;
  String get navEarnings;
  String get navApproval;

  // ---- job discovery ----
  String get couldNotLoadJobs;
  String get jobAccepted;
  String get offerTaken;
  String get offerExpired;
  String jobsNearYou(int count);
  String get acceptingJobs;
  String get notAcceptingJobs;
  String get acceptingJobsSub;
  String get notAcceptingJobsSub;
  String perHour(String amount);
  String get deepCleanChip;
  String get petsChip;
  String bedBathSummary(int bedrooms, int bathrooms, int? squareFeet);
  String distanceNeighborhood(String km, String neighborhood);
  String onSite(String hours);
  String closingIn(int seconds);
  String openFor(int seconds);
  String get pass;
  String get acceptJob;
  String secondsLeftToAccept(int seconds);
  String get whyPassing;
  String get whyPassingSub;
  String get reasonTooFar;
  String get reasonBadTiming;
  String get reasonLowPay;
  String get reasonOther;
  String get emptyNoJobsTitle;
  String get emptyNoJobsBody;
  String get emptyNotAcceptingTitle;
  String get emptyNotAcceptingBody;
  String get tryAgain;

  // ---- active job ----
  String get couldNotLoadJob;
  String get jobFallbackTitle;
  String get messageCustomer;
  String get customerTitle;
  String get youEarn;
  String get address;
  String get gettingIn;
  String get addressLocked;
  String get fromCustomer;
  String get jobComplete;
  String get afterPhotos;
  String photosCount(int have, int need);
  String get photosEnoughBody;
  String photosNeededBody(int need);
  String get uploading;
  String get addPhoto;
  String couldNotAddPhoto(String error);
  String needAfterPhotos(int need);
  String get jobCompletePayout;
  /// The action button's label for the *next* step to take — keyed by the
  /// status that tap would move the job into (`en_route`/`arrived`/
  /// `in_progress`/`completed`).
  String actionLabel(String targetStatus);
  /// The stepper's label for a status the job has already reached or is in —
  /// same four keys, different (shorter) copy than [actionLabel].
  String statusLabel(String status);

  // ---- earnings ----
  String get earningsTitle;
  String get couldNotLoadEarnings;
  String get periodWeek;
  String get periodMonth;
  String get periodAll;
  String get takeHome;
  String jobsShare(int jobs);
  String get yourShare;
  String get tips;
  String get bookedGross;
  String get platformFee;
  String get nextPayout;
  String get noPayoutPending;
  String get onItsWay;
  String arrives(String date);

  // ---- duration formatting ("3h 30m" register, shared shape with customer_app) ----
  String hoursShort(int totalMinutes);
}

class SparkleStringsEn extends SparkleStrings {
  @override
  String get navDiscover => 'Discover';
  @override
  String get navSchedule => 'Schedule';
  @override
  String get navEarnings => 'Earnings';
  @override
  String get navApproval => 'Approval';

  @override
  String get couldNotLoadJobs => 'Could not load jobs. Pull down to retry.';
  @override
  String get jobAccepted => 'Job accepted. The address is in your schedule.';
  @override
  String get offerTaken => 'Another cleaner took this one.';
  @override
  String get offerExpired => 'That offer expired.';
  @override
  String jobsNearYou(int count) => count == 0 ? 'Jobs near you' : '$count jobs near you';
  @override
  String get acceptingJobs => 'Accepting jobs';
  @override
  String get notAcceptingJobs => 'Not accepting jobs';
  @override
  String get acceptingJobsSub => "We'll notify you when work comes in";
  @override
  String get notAcceptingJobsSub => 'Turn on to start receiving offers';
  @override
  String perHour(String amount) => '$amount/hr';
  @override
  String get deepCleanChip => 'DEEP CLEAN';
  @override
  String get petsChip => 'PETS';
  @override
  String bedBathSummary(int bedrooms, int bathrooms, int? squareFeet) =>
      '$bedrooms bed · $bathrooms bath${squareFeet != null ? ' · $squareFeet sq ft' : ''}';
  @override
  String distanceNeighborhood(String km, String neighborhood) => '$km km · $neighborhood';
  @override
  String onSite(String hours) => '$hours on site';
  @override
  String closingIn(int seconds) => 'Closing in ${seconds}s';
  @override
  String openFor(int seconds) => 'Open for ${seconds}s';
  @override
  String get pass => 'Pass';
  @override
  String get acceptJob => 'Accept job';
  @override
  String secondsLeftToAccept(int seconds) => '$seconds seconds left to accept';
  @override
  String get whyPassing => 'Why are you passing?';
  @override
  String get whyPassingSub => 'This tunes which jobs we send you. Passing never affects your rating.';
  @override
  String get reasonTooFar => 'Too far away';
  @override
  String get reasonBadTiming => "Doesn't fit my schedule";
  @override
  String get reasonLowPay => 'Pay is too low';
  @override
  String get reasonOther => 'Another reason';
  @override
  String get emptyNoJobsTitle => 'No open jobs right now';
  @override
  String get emptyNoJobsBody =>
      'Keep the app open — new jobs arrive as a notification, and weekend mornings are busiest.';
  @override
  String get emptyNotAcceptingTitle => "You're not accepting jobs";
  @override
  String get emptyNotAcceptingBody => 'Turn on Accepting jobs at the top to start receiving offers.';
  @override
  String get tryAgain => 'Try again';

  @override
  String get couldNotLoadJob => 'Could not load the job. Pull down to retry.';
  @override
  String get jobFallbackTitle => 'Job';
  @override
  String get messageCustomer => 'Message customer';
  @override
  String get customerTitle => 'Customer';
  @override
  String get youEarn => 'You earn';
  @override
  String get address => 'Address';
  @override
  String get gettingIn => 'Getting in';
  @override
  String get addressLocked => 'The full address unlocks when you start the job.';
  @override
  String get fromCustomer => 'From the customer';
  @override
  String get jobComplete => 'Job complete';
  @override
  String get afterPhotos => 'After-photos';
  @override
  String photosCount(int have, int need) => '$have of $need';
  @override
  String get photosEnoughBody => "You've got enough to finish. Add more if you like.";
  @override
  String photosNeededBody(int need) =>
      'A Deep Clean needs $need photos of the finished work before you can complete it.';
  @override
  String get uploading => 'Uploading…';
  @override
  String get addPhoto => 'Add photo';
  @override
  String couldNotAddPhoto(String error) => 'Could not add that photo. $error';
  @override
  String needAfterPhotos(int need) => 'Add at least $need after-photos before finishing.';
  @override
  String get jobCompletePayout => 'Job complete. Your payout is on its way.';
  @override
  String actionLabel(String targetStatus) => switch (targetStatus) {
        'en_route' => "I'm on my way",
        'arrived' => "I've arrived",
        'in_progress' => 'Start cleaning',
        'completed' => 'Finish job',
        _ => targetStatus,
      };
  @override
  String statusLabel(String status) => switch (status) {
        'en_route' => 'On the way',
        'arrived' => 'Arrived',
        'in_progress' => 'Cleaning',
        'completed' => 'Done',
        _ => status,
      };

  @override
  String get earningsTitle => 'Earnings';
  @override
  String get couldNotLoadEarnings => 'Could not load earnings. Pull down to retry.';
  @override
  String get periodWeek => 'This week';
  @override
  String get periodMonth => 'This month';
  @override
  String get periodAll => 'All time';
  @override
  String get takeHome => 'TAKE-HOME';
  @override
  String jobsShare(int jobs) => '$jobs ${jobs == 1 ? 'job' : 'jobs'} · your share plus tips';
  @override
  String get yourShare => 'Your share';
  @override
  String get tips => 'Tips';
  @override
  String get bookedGross => 'Booked (gross)';
  @override
  String get platformFee => 'Platform fee';
  @override
  String get nextPayout => 'Next payout';
  @override
  String get noPayoutPending => 'No payout pending';
  @override
  String get onItsWay => 'On its way';
  @override
  String arrives(String date) => 'Arrives $date';

  @override
  String hoursShort(int totalMinutes) {
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

class SparkleStringsEs extends SparkleStrings {
  @override
  String get navDiscover => 'Descubrir';
  @override
  String get navSchedule => 'Agenda';
  @override
  String get navEarnings => 'Ganancias';
  @override
  String get navApproval => 'Aprobación';

  @override
  String get couldNotLoadJobs => 'No se pudieron cargar los trabajos. Desliza hacia abajo para reintentar.';
  @override
  String get jobAccepted => 'Trabajo aceptado. La dirección está en tu agenda.';
  @override
  String get offerTaken => 'Otro limpiador tomó este trabajo.';
  @override
  String get offerExpired => 'Esa oferta expiró.';
  @override
  String jobsNearYou(int count) => count == 0 ? 'Trabajos cerca de ti' : '$count trabajos cerca de ti';
  @override
  String get acceptingJobs => 'Aceptando trabajos';
  @override
  String get notAcceptingJobs => 'Sin aceptar trabajos';
  @override
  String get acceptingJobsSub => 'Te avisaremos cuando llegue trabajo';
  @override
  String get notAcceptingJobsSub => 'Actívalo para empezar a recibir ofertas';
  @override
  String perHour(String amount) => '$amount/h';
  @override
  String get deepCleanChip => 'LIMPIEZA PROFUNDA';
  @override
  String get petsChip => 'MASCOTAS';
  @override
  String bedBathSummary(int bedrooms, int bathrooms, int? squareFeet) =>
      '$bedrooms hab · $bathrooms baño${bathrooms == 1 ? '' : 's'}${squareFeet != null ? ' · $squareFeet m²' : ''}';
  @override
  String distanceNeighborhood(String km, String neighborhood) => '$km km · $neighborhood';
  @override
  String onSite(String hours) => '$hours en el lugar';
  @override
  String closingIn(int seconds) => 'Cierra en ${seconds}s';
  @override
  String openFor(int seconds) => 'Abierto por ${seconds}s';
  @override
  String get pass => 'Pasar';
  @override
  String get acceptJob => 'Aceptar trabajo';
  @override
  String secondsLeftToAccept(int seconds) => '$seconds segundos para aceptar';
  @override
  String get whyPassing => '¿Por qué pasas de este trabajo?';
  @override
  String get whyPassingSub =>
      'Esto ajusta qué trabajos te enviamos. Pasar nunca afecta tu calificación.';
  @override
  String get reasonTooFar => 'Queda muy lejos';
  @override
  String get reasonBadTiming => 'No encaja con mi horario';
  @override
  String get reasonLowPay => 'El pago es muy bajo';
  @override
  String get reasonOther => 'Otra razón';
  @override
  String get emptyNoJobsTitle => 'No hay trabajos disponibles ahora';
  @override
  String get emptyNoJobsBody =>
      'Mantén la app abierta — los nuevos trabajos llegan como notificación, y las mañanas de fin de semana son las más movidas.';
  @override
  String get emptyNotAcceptingTitle => 'No estás aceptando trabajos';
  @override
  String get emptyNotAcceptingBody => 'Activa "Aceptando trabajos" arriba para empezar a recibir ofertas.';
  @override
  String get tryAgain => 'Intentar de nuevo';

  @override
  String get couldNotLoadJob => 'No se pudo cargar el trabajo. Desliza hacia abajo para reintentar.';
  @override
  String get jobFallbackTitle => 'Trabajo';
  @override
  String get messageCustomer => 'Mensaje al cliente';
  @override
  String get customerTitle => 'Cliente';
  @override
  String get youEarn => 'Tú ganas';
  @override
  String get address => 'Dirección';
  @override
  String get gettingIn => 'Cómo entrar';
  @override
  String get addressLocked => 'La dirección completa se desbloquea al iniciar el trabajo.';
  @override
  String get fromCustomer => 'Del cliente';
  @override
  String get jobComplete => 'Trabajo terminado';
  @override
  String get afterPhotos => 'Fotos finales';
  @override
  String photosCount(int have, int need) => '$have de $need';
  @override
  String get photosEnoughBody => 'Ya tienes suficientes para terminar. Agrega más si quieres.';
  @override
  String photosNeededBody(int need) =>
      'Una limpieza profunda necesita $need fotos del trabajo terminado antes de poder completarla.';
  @override
  String get uploading => 'Subiendo…';
  @override
  String get addPhoto => 'Agregar foto';
  @override
  String couldNotAddPhoto(String error) => 'No se pudo agregar esa foto. $error';
  @override
  String needAfterPhotos(int need) => 'Agrega al menos $need fotos finales antes de terminar.';
  @override
  String get jobCompletePayout => 'Trabajo terminado. Tu pago está en camino.';
  @override
  String actionLabel(String targetStatus) => switch (targetStatus) {
        'en_route' => 'Voy en camino',
        'arrived' => 'Ya llegué',
        'in_progress' => 'Empezar a limpiar',
        'completed' => 'Terminar trabajo',
        _ => targetStatus,
      };
  @override
  String statusLabel(String status) => switch (status) {
        'en_route' => 'En camino',
        'arrived' => 'Llegó',
        'in_progress' => 'Limpiando',
        'completed' => 'Listo',
        _ => status,
      };

  @override
  String get earningsTitle => 'Ganancias';
  @override
  String get couldNotLoadEarnings => 'No se pudieron cargar las ganancias. Desliza hacia abajo para reintentar.';
  @override
  String get periodWeek => 'Esta semana';
  @override
  String get periodMonth => 'Este mes';
  @override
  String get periodAll => 'Todo el tiempo';
  @override
  String get takeHome => 'TUS GANANCIAS';
  @override
  String jobsShare(int jobs) => '$jobs ${jobs == 1 ? 'trabajo' : 'trabajos'} · tu parte más propinas';
  @override
  String get yourShare => 'Tu parte';
  @override
  String get tips => 'Propinas';
  @override
  String get bookedGross => 'Reservado (bruto)';
  @override
  String get platformFee => 'Tarifa de la plataforma';
  @override
  String get nextPayout => 'Próximo pago';
  @override
  String get noPayoutPending => 'Sin pagos pendientes';
  @override
  String get onItsWay => 'En camino';
  @override
  String arrives(String date) => 'Llega $date';

  @override
  String hoursShort(int totalMinutes) {
    final h = totalMinutes ~/ 60, m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
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

/// App-wide language override, in memory only (resets on cold start — this
/// app has no persistence layer for settings yet, and adding one just for
/// this felt like more risk than the feature warranted on a machine that
/// can't verify a new dependency resolves). `null` means "follow the device
/// locale", same as before this existed. A bare `ValueNotifier` rather than a
/// state-management package, so `MaterialApp` and [LanguageSwitch] can share
/// it without adding a dependency.
final ValueNotifier<Locale?> localeOverride = ValueNotifier<Locale?>(null);

/// A small "EN"/"ES" toggle — shows the language a tap switches *to*, not the
/// current one, matching the landing page's switcher. Reads the resolved
/// locale via `Localizations.localeOf`, not `localeOverride.value` directly,
/// so it's correct even before the user has ever touched the toggle (i.e.
/// while following the device locale).
class LanguageSwitch extends StatelessWidget {
  const LanguageSwitch({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final current = Localizations.localeOf(context).languageCode;
    final next = current == 'es' ? 'en' : 'es';
    return TextButton(
      onPressed: () => localeOverride.value = Locale(next),
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(44, 44),
      ),
      child: Text(next.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}
