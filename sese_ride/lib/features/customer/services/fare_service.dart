import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/fare_models.dart';

/// Zero-trust fare calculation client.
///
/// The client **never** computes fares locally. Every call forwards pickup +
/// dropoff coordinates and the selected service/vehicle types to the
/// `calculateFare` Firebase Callable Function, which performs:
///   - JWT verification (via Firebase Auth context)
///   - Actual road-network distance & duration via OSRM
///   - Fare formula evaluation against the Firestore [RegionConfig]
///   - HMAC-SHA256 signing of the response payload
///
/// The returned [FareResponse.tiers] are rendered verbatim in the UI.
abstract class FareBackend {
  Future<Map<String, dynamic>> callCalculateFare(
      Map<String, dynamic> payload);
}

/// Production transport: Firebase Callable Functions.
class _CloudFunctionsFareBackend implements FareBackend {
  @override
  Future<Map<String, dynamic>> callCalculateFare(
      Map<String, dynamic> payload) async {
    final fn = FirebaseFunctions.instance;
    final result = await fn.httpsCallable('calculateFare').call(payload);
    return Map<String, dynamic>.from(result.data as Map);
  }
}

/// Service layer that wraps [FareBackend] with error mapping and logging.
class FareService {
  final FareBackend _backend;

  FareService([FareBackend? backend])
      : _backend = backend ?? _CloudFunctionsFareBackend();

  /// Calls `calculateFare` and returns a [FareResponse].
  ///
  /// Throws [FareException] on any backend error with a user-friendly message.
  Future<FareResponse> calculateFare({
    required LatLng pickup,
    required LatLng dropoff,
    required FareServiceType serviceType,
    required List<String> selectedTiers,
    String? countryCode,
    String? stateOrRegion,
  }) async {
    final payload = FareRequest(
      pickup: pickup,
      dropoff: dropoff,
      serviceType: serviceType,
      selectedTiers: selectedTiers,
      countryCode: countryCode,
      stateOrRegion: stateOrRegion,
    ).toMap();

    debugPrint(
        'FareService: calling calculateFare — serviceType=${serviceType.apiValue} '
        'tiers=$selectedTiers '
        'pickup=(${pickup.latitude.toStringAsFixed(4)}, ${pickup.longitude.toStringAsFixed(4)}) '
        'dropoff=(${dropoff.latitude.toStringAsFixed(4)}, ${dropoff.longitude.toStringAsFixed(4)})');

    try {
      final data = await _backend.callCalculateFare(payload);
      final response = FareResponse.fromMap(data);
      debugPrint(
          'FareService: response — '
          '${response.distanceKm.toStringAsFixed(1)} km, '
          '${response.durationMins.toStringAsFixed(0)} mins, '
          '${response.tiers.length} tier(s)');
      return response;
    } on FirebaseFunctionsException catch (e) {
      debugPrint('FareService: FirebaseFunctionsException ${e.code}: ${e.message}');
      throw FareException(
        e.code,
        _mapFunctionsError(e.code, e.message),
      );
    } catch (e) {
      debugPrint('FareService: unexpected error: $e');
      throw const FareException(
        'network-error',
        'Could not reach the fare server. Check your connection and try again.',
      );
    }
  }

  static String _mapFunctionsError(String code, String? message) {
    switch (code) {
      case 'unauthenticated':
        return 'Your session has expired. Please sign in again.';
      case 'invalid-argument':
        return 'Invalid location data. Please re-enter pickup and destination.';
      case 'not-found':
        return 'No route found between these locations.';
      case 'unavailable':
        return 'Fare server is temporarily unavailable. Please try again.';
      case 'resource-exhausted':
        return 'Too many requests. Please wait a moment and try again.';
      default:
        return message ?? 'Fare calculation failed. Please try again.';
    }
  }
}
