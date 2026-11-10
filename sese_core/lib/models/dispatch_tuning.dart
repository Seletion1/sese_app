/// Live sequential dispatch engine tunables (1 -> 2 -> 3 -> Public Pool),
/// map animation settings, and offer boost limits.
///
/// Mirrors the `system_settings/dispatch` Firestore document keys consumed
/// by Cloud Functions (`functions/src/trips.ts`), the Hub Dispatch Console
/// (`sese_hub`), and the customer Live Trip searching screen (`sese_ride`).
class DispatchTuning {
  /// Maximum number of sequential nearest drivers targeted (Step 1, 2, 3)
  /// before escalating to the Public Order Pool (Step 4).
  static const int maxSequentialDrivers = 3;

  final double dispatchRadiusKm;
  final double tier1RadiusKm;
  final double tier3RadiusKm;
  final int tier1TimeoutSec;
  final int pingTimeoutSec;
  final int repingIntervalSec;
  final int candidateLimit;
  final int recycleWindowMin;
  final int maxRecycles;

  /// Public Order Pool expiration duration in minutes (Hub configurable).
  /// Default: 60 minutes (1 hour). When reached without driver acceptance,
  /// the order automatically transitions to `returned_to_customer` and purges from driver feeds.
  final int publicPoolDurationMin;

  /// Configured search radius for sequential driver matching (Step 1, 2, 3). Default 3.0 km (0–3 km).
  double get searchRadiusKm => tier1RadiusKm;

  /// Configured extended pool radius for Public Order Pool (Step 4). Default 15.0 km.
  double get poolRadiusKm => tier3RadiusKm;

  /// Configured exclusive response timeout per sequential driver (seconds). Default 15s.
  int get driverTimeoutSec => tier1TimeoutSec;

  /// Maximum allowed customer fare boost percentage over baseline fare (Hub configurable).
  /// Default: 100.0 (i.e. Max Offer = Original Base Fare * 2).
  final double maxOfferBoostPct;

  /// Dynamic Map Camera Animation Timing Parameters (Hub Configurable)
  ///
  /// Controls automated camera dwell/pause duration at the pickup point
  /// and drop-off destination during live customer searching loop.
  final int cameraPickupDwellSec; // default: 5 seconds
  final int cameraDropoffDwellSec; // default: 2 seconds

  /// Maximum concurrent driver bids visible to customer in live bidding list.
  final int maxConcurrentBids; // default: 5

  const DispatchTuning({
    this.dispatchRadiusKm = 15,
    this.tier1RadiusKm = 3,
    this.tier3RadiusKm = 15,
    this.tier1TimeoutSec = 15,
    this.pingTimeoutSec = 15,
    this.repingIntervalSec = 30,
    this.candidateLimit = 25,
    this.recycleWindowMin = 25,
    this.maxRecycles = 5,
    this.publicPoolDurationMin = 60,
    this.maxOfferBoostPct = 100.0,
    this.cameraPickupDwellSec = 5,
    this.cameraDropoffDwellSec = 2,
    this.maxConcurrentBids = 5,
  });

  /// Resolves the driver search radius (in kilometers) for a given trip dispatch tier (1, 3).
  ///
  /// - Tier 1: Nearest single driver sequential ring (0 to [tier1RadiusKm] km, default ~3 km).
  /// - Tier 3: Marketplace open pool (0 to [tier3RadiusKm] km, default ~15 km).
  double radiusForTier(int tier) {
    switch (tier) {
      case 3:
        return tier3RadiusKm;
      case 1:
      default:
        return tier1RadiusKm;
    }
  }

  /// Determines if sequential dispatch search should escalate to Public Pool.
  ///
  /// Escalates when all 3 sequential drivers have timed out or declined,
  /// or when [attemptedCount] reaches [candidateLimit] or exceeds available [candidateCount].
  bool shouldEscalateToPool({
    required int candidateCount,
    required int attemptedCount,
    bool isTier1Expired = false,
  }) {
    if (isTier1Expired) return true;
    if (candidateCount == 0) return true;
    if (attemptedCount >= maxSequentialDrivers) return true;
    if (attemptedCount >= candidateCount) return true;
    if (attemptedCount >= candidateLimit) return true;
    return false;
  }

  factory DispatchTuning.fromMap(Map<String, dynamic>? map) {
    map ??= const {};
    double numOf(String key, double fb) =>
        (map![key] is num) ? (map[key] as num).toDouble() : fb;
    int intOf(String key, int fb) =>
        (map![key] is num) ? (map[key] as num).toInt() : fb;
    final t3 = numOf('tier3RadiusKm', numOf('dispatchRadiusKm', numOf('poolRadiusKm', 15)));
    final t1 = numOf('tier1RadiusKm', numOf('searchRadiusKm', 3));
    final t1Timeout = intOf('tier1TimeoutSec', intOf('sequentialTimeoutSec', 15));
    return DispatchTuning(
      dispatchRadiusKm: t3,
      tier1RadiusKm: t1,
      tier3RadiusKm: t3,
      tier1TimeoutSec: t1Timeout,
      pingTimeoutSec: intOf('pingTimeoutSec', t1Timeout),
      repingIntervalSec: intOf('repingIntervalSec', 30),
      candidateLimit: intOf('candidateLimit', 25),
      recycleWindowMin: intOf('recycleWindowMin', 25),
      maxRecycles: intOf('maxRecycles', 5),
      publicPoolDurationMin: intOf('publicPoolDurationMin', intOf('poolDurationMin', 60)),
      maxOfferBoostPct: numOf('maxOfferBoostPct', 100.0),
      cameraPickupDwellSec: intOf('cameraPickupDwellSec', 5),
      cameraDropoffDwellSec: intOf('cameraDropoffDwellSec', 2),
      maxConcurrentBids: intOf('maxConcurrentBids', intOf('max_visible_bids', 5)),
    );
  }

  Map<String, dynamic> toMap() => {
        'dispatchRadiusKm': tier3RadiusKm,
        'tier1RadiusKm': tier1RadiusKm,
        'searchRadiusKm': tier1RadiusKm,
        'tier3RadiusKm': tier3RadiusKm,
        'poolRadiusKm': tier3RadiusKm,
        'tier1TimeoutSec': tier1TimeoutSec,
        'sequentialTimeoutSec': tier1TimeoutSec,
        'pingTimeoutSec': pingTimeoutSec,
        'repingIntervalSec': repingIntervalSec,
        'candidateLimit': candidateLimit,
        'recycleWindowMin': recycleWindowMin,
        'maxRecycles': maxRecycles,
        'publicPoolDurationMin': publicPoolDurationMin,
        'poolDurationMin': publicPoolDurationMin,
        'maxOfferBoostPct': maxOfferBoostPct,
        'cameraPickupDwellSec': cameraPickupDwellSec,
        'cameraDropoffDwellSec': cameraDropoffDwellSec,
        'maxConcurrentBids': maxConcurrentBids,
        'max_visible_bids': maxConcurrentBids,
      };
}
