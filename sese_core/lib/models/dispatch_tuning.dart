/// Live streamlined 2-stage dispatch engine tunables and map animation settings.
///
/// Mirrors the `system_settings/dispatch` Firestore document keys consumed
/// by Cloud Functions (`functions/src/trips.ts`), the Hub Dispatch Console
/// (`sese_hub`), and the customer Live Trip searching screen (`sese_ride`).
class DispatchTuning {
  final double dispatchRadiusKm;
  final double tier1RadiusKm;
  final double tier3RadiusKm;
  final int tier1TimeoutSec;
  final int pingTimeoutSec;
  final int repingIntervalSec;
  final int candidateLimit;
  final int recycleWindowMin;
  final int maxRecycles;

  /// Dynamic Map Camera Animation Timing Parameters (Hub Configurable)
  ///
  /// Controls automated camera dwell/pause duration at the pickup point
  /// and drop-off destination during live customer searching loop.
  final int cameraPickupDwellSec; // default: 5 seconds
  final int cameraDropoffDwellSec; // default: 2 seconds

  const DispatchTuning({
    this.dispatchRadiusKm = 10,
    this.tier1RadiusKm = 3,
    this.tier3RadiusKm = 10,
    this.tier1TimeoutSec = 15,
    this.pingTimeoutSec = 60,
    this.repingIntervalSec = 30,
    this.candidateLimit = 25,
    this.recycleWindowMin = 25,
    this.maxRecycles = 5,
    this.cameraPickupDwellSec = 5,
    this.cameraDropoffDwellSec = 2,
  });

  /// Resolves the driver search radius (in kilometers) for a given trip dispatch tier (1, 3).
  ///
  /// - Tier 1: Nearest single driver sequential ring (0 to [tier1RadiusKm] km, default ~3 km).
  /// - Tier 3: Marketplace open pool (0 to [tier3RadiusKm] km, default ~10 km).
  double radiusForTier(int tier) {
    switch (tier) {
      case 3:
        return tier3RadiusKm;
      case 1:
      default:
        return tier1RadiusKm;
    }
  }

  /// Determines if a Stage 1 sequential dispatch search should escalate to Stage 3 (Marketplace Pool).
  ///
  /// Escalates when all Stage 1 candidate drivers have timed out or declined,
  /// or when [attemptedCount] reaches [candidateLimit] or exceeds available [candidateCount].
  bool shouldEscalateToPool({
    required int candidateCount,
    required int attemptedCount,
    bool isTier1Expired = false,
  }) {
    if (isTier1Expired) return true;
    if (candidateCount == 0) return true;
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
    final t3 = numOf('tier3RadiusKm', numOf('dispatchRadiusKm', 10));
    return DispatchTuning(
      dispatchRadiusKm: t3,
      tier1RadiusKm: numOf('tier1RadiusKm', 3),
      tier3RadiusKm: t3,
      tier1TimeoutSec: intOf('tier1TimeoutSec', 15),
      pingTimeoutSec: intOf('pingTimeoutSec', 60),
      repingIntervalSec: intOf('repingIntervalSec', 30),
      candidateLimit: intOf('candidateLimit', 25),
      recycleWindowMin: intOf('recycleWindowMin', 25),
      maxRecycles: intOf('maxRecycles', 5),
      cameraPickupDwellSec: intOf('cameraPickupDwellSec', 5),
      cameraDropoffDwellSec: intOf('cameraDropoffDwellSec', 2),
    );
  }

  Map<String, dynamic> toMap() => {
        'dispatchRadiusKm': tier3RadiusKm,
        'tier1RadiusKm': tier1RadiusKm,
        'tier3RadiusKm': tier3RadiusKm,
        'tier1TimeoutSec': tier1TimeoutSec,
        'pingTimeoutSec': pingTimeoutSec,
        'repingIntervalSec': repingIntervalSec,
        'candidateLimit': candidateLimit,
        'recycleWindowMin': recycleWindowMin,
        'maxRecycles': maxRecycles,
        'cameraPickupDwellSec': cameraPickupDwellSec,
        'cameraDropoffDwellSec': cameraDropoffDwellSec,
      };
}
