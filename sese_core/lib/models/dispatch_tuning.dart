/// Live cascading dispatch engine tunables and map animation settings.
///
/// Mirrors the `system_settings/dispatch` Firestore document keys consumed
/// by Cloud Functions (`functions/src/trips.ts`), the Hub Dispatch Console
/// (`sese_hub`), and the customer Live Trip searching screen (`sese_ride`).
class DispatchTuning {
  final double dispatchRadiusKm;
  final double tier1RadiusKm;
  final double tier2RadiusKm;
  final double tier3RadiusKm;
  final int tier1TimeoutSec;
  final int tier2TimeoutSec;
  final int pingTimeoutSec;
  final int repingIntervalSec;
  final int tier2Count;
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
    this.tier2RadiusKm = 6,
    this.tier3RadiusKm = 10,
    this.tier1TimeoutSec = 15,
    this.tier2TimeoutSec = 15,
    this.pingTimeoutSec = 60,
    this.repingIntervalSec = 30,
    this.tier2Count = 2,
    this.candidateLimit = 25,
    this.recycleWindowMin = 25,
    this.maxRecycles = 5,
    this.cameraPickupDwellSec = 5,
    this.cameraDropoffDwellSec = 2,
  });

  /// Resolves the driver search radius (in kilometers) for a given trip dispatch tier (0, 1, 2, 3).
  ///
  /// - Tier 1 (or 0 / default): Nearest single driver (0 to [tier1RadiusKm] km, default ~3 km).
  /// - Tier 2: Next group in parallel (0 to [tier2RadiusKm] km, default ~6 km).
  /// - Tier 3: Marketplace open pool (0 to [tier3RadiusKm] km, default ~10 km).
  double radiusForTier(int tier) {
    switch (tier) {
      case 2:
        return tier2RadiusKm;
      case 3:
        return tier3RadiusKm;
      case 1:
      default:
        return tier1RadiusKm;
    }
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
      tier2RadiusKm: numOf('tier2RadiusKm', 6),
      tier3RadiusKm: t3,
      tier1TimeoutSec: intOf('tier1TimeoutSec', 15),
      tier2TimeoutSec: intOf('tier2TimeoutSec', 15),
      pingTimeoutSec: intOf('pingTimeoutSec', 60),
      repingIntervalSec: intOf('repingIntervalSec', 30),
      tier2Count: intOf('tier2Count', 2),
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
        'tier2RadiusKm': tier2RadiusKm,
        'tier3RadiusKm': tier3RadiusKm,
        'tier1TimeoutSec': tier1TimeoutSec,
        'tier2TimeoutSec': tier2TimeoutSec,
        'pingTimeoutSec': pingTimeoutSec,
        'repingIntervalSec': repingIntervalSec,
        'tier2Count': tier2Count,
        'candidateLimit': candidateLimit,
        'recycleWindowMin': recycleWindowMin,
        'maxRecycles': maxRecycles,
        'cameraPickupDwellSec': cameraPickupDwellSec,
        'cameraDropoffDwellSec': cameraDropoffDwellSec,
      };
}
