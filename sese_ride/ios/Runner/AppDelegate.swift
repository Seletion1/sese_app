import Flutter
import UIKit
import GoogleMaps

// Map Provider Strategy: Google Maps SDK renders all surfaces
// (browsing, idle positioning, live-trip tracking, in-app turn-by-turn).
// The key is read from Info.plist at runtime — it is NEVER hardcoded here.
//
// How to set the key without committing it:
//   1. Open ios/Runner/Info.plist and add (it is git-tracked — add a
//      placeholder value there and override at CI/CD time, OR):
//   2. Create ios/Runner/GoogleMapsSdkKey.xcconfig (git-ignored) with:
//        GOOGLE_MAPS_SDK_KEY = AIza<your-app-restricted-sdk-key>
//      then reference it from your build scheme's .xcconfig files.
//   3. The Info.plist key `GoogleMapsSdkKey` reads $(GOOGLE_MAPS_SDK_KEY)
//      from the xcconfig at build time.
//
// Restrict this key in Cloud Console to:
//   • Platform: iOS
//   • Bundle identifier: com.sesetech.seseRide
//   • APIs: Maps SDK for iOS only
//
// This key is DIFFERENT from GOOGLE_MAPS_API_KEY in functions/.env (the
// server-side web-services key used by the Cloud Function proxy).
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Read the Maps SDK key from Info.plist — the plist value is populated
    // at build time from an xcconfig variable, so no key lives in source.
    let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsSdkKey") as? String
    guard let apiKey = apiKey, !apiKey.isEmpty,
          !apiKey.hasPrefix("$(") // guard against un-substituted xcconfig var
    else {
      // In debug mode, crash fast with a clear message rather than silently
      // rendering a beige void. In release builds, continue without maps
      // (degraded but not crashed — the app can still dispatch via server).
      assertionFailure(
        """

        ⛔  GoogleMapsSdkKey is not set in Info.plist.
            Add `GoogleMapsSdkKey` → $(GOOGLE_MAPS_SDK_KEY) to Info.plist,
            then define GOOGLE_MAPS_SDK_KEY in your .xcconfig or environment.
        """
      )
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    GMSServices.provideAPIKey(apiKey)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
