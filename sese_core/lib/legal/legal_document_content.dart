/// Types of legal documents in the SESE Ecosystem.
enum LegalDocType {
  terms,
  privacy,
  accountDeletion,
}

/// Global legal copy for SESE Technology LTD.
///
/// All three official URLs are authoritative across in-app viewers,
/// web hosting (Firebase), and Google Play store listings:
///   - Terms of Service:  https://sesetech.com/terms
///   - Privacy Policy:    https://sesetech.com/PrivacyPolicy
///   - Account Deletion:  https://sesetech.com/delete
abstract final class LegalDocumentContent {
  static String titleFor(LegalDocType type) {
    switch (type) {
      case LegalDocType.terms:
        return 'Terms of Use';
      case LegalDocType.privacy:
        return 'Privacy Policy';
      case LegalDocType.accountDeletion:
        return 'Account & Data Deletion';
    }
  }

  static String contentFor(LegalDocType type) {
    switch (type) {
      case LegalDocType.terms:
        return termsOfServiceText;
      case LegalDocType.privacy:
        return privacyPolicyText;
      case LegalDocType.accountDeletion:
        return accountDeletionText;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // TERMS OF SERVICE
  // ─────────────────────────────────────────────────────────────
  static const String termsOfServiceText = '''
SESE TECHNOLOGY LTD — GLOBAL TERMS OF SERVICE
Last Updated: November 20, 2026
Official Web Portal: https://sesetech.com/terms

1. ACCEPTANCE & GOVERNING AGREEMENT
By creating an account, accessing, or using SESE Technology LTD ("SESE", "Company", "We", "Us") platforms — including SESE Ride (Rider and Driver modes) and SESE Hub operations desk — you ("User", "Rider", "Driver", "Partner") agree to be bound by these Terms of Service, our Privacy Policy (https://sesetech.com/PrivacyPolicy), and our Account Deletion Policy (https://sesetech.com/delete). If you do not agree, you must immediately cease accessing or using our services.

2. IDENTITY VERIFICATION, KYC & STRICT ONE-ACCOUNT POLICY
• Strict One-Person-One-Account Enforcement: Every user or driver is permitted exactly one account tied to a verified phone number, government ID, and unique device. SESE normalizes and hashes identity credentials (NIN, BVN, Driver's License) via SHA-256 to ensure duplicate prevention without storing raw PII.
• Driver KYC Requirements: Drivers must maintain a valid driver's license, vehicle registration, roadworthiness certificate, active third-party/comprehensive motor insurance, and complete live facial verification before dispatch eligibility is granted.
• Anti-Spoofing & Platform Security: GPS spoofing, mock location software, virtual emulators, rooted devices, or modified app binaries are strictly prohibited and result in permanent device bans and fund forfeiture.

3. RIDE-HAILING & SYNCHRONIZED FARE BIDDING
• Intermediary Technology Status: SESE connects passengers with verified independent third-party driver partners. SESE does not own vehicles or operate direct transport services.
• Synchronized Bidding: On enabled routes, drivers can accept published base fares or submit a counter-bid. Riders receive real-time bids with live countdowns and may accept, decline, or counter-offer. Once accepted, the agreed fare is binding and cannot be modified mid-trip.

4. ON-DEMAND LOGISTICS & COURIER DELIVERY
• Prohibited Goods: Senders must ensure packages contain no illegal drugs, unregistered firearms, weapons, toxic materials, hazardous goods, stolen items, or counterfeit property. Drivers retain the right to inspect exterior packaging and decline transit.
• Delivery PIN Verification: Couriers require a secure 4-digit PIN delivered to the recipient, which must be validated before delivery completion. Delivery is not finalized without successful PIN confirmation.

5. PRICING, IMMEDIATE WALLET DEDUCTION & ESCROW
• Server-Authoritative Money: Fares, commission rates, waiting fees, and settlements are calculated strictly by SESE's authoritative backend servers. No client-side fare computation is permitted or honored.
• Immediate Prepayment & Escrow Lock: For trips paid via Wallet or Card, the full fare amount is immediately deducted from the customer's available balance and held in secure server-side Escrow upon booking confirmation. This prevents balance double-spending across concurrent ride requests. Driver partners receive wallet credit only upon confirmed drop-off completion verified by the platform.
• Wallet Top-Up: Customers may top up their SESE Wallet via Paystack (bank card, bank transfer, USSD). All payment processing is PCI-DSS compliant. SESE never stores raw card or CVV details.

6. CANCELLATION RULES, WAITING FEES & IN-PROGRESS LOCK
• Cancellation Before Trip Start: Riders may cancel without fee before a driver arrives at the pickup point.
• Waiting Fees: If a driver partner arrives at the pickup location and waits beyond the Grace Period (default: 10 minutes), an automated waiting fee (default: ₦20 per minute) accrues dynamically and is deducted from the escrow balance. Configurable by platform administrators.
• Strict In-Progress Cancellation Lock: Once a ride is started (status: IN_PROGRESS or pending_customer_approval), in-app cancellation by either rider or driver is strictly locked. The trip must proceed to its destination.
• Support Intervention: In verifiable emergencies, a SESE Hub Support administrator can cancel and refund the trip to the rider's wallet. Driver trip fare is forfeited except for valid waiting fee compensation already accrued.
• Hub Admin Cancellation: Hub administrators retain the authority to cancel any trip regardless of status, issue full or partial refunds, and manually settle driver waiting compensation.

7. CASH REMITTANCE & DRIVER WALLET RULES
Drivers collecting cash fares must remit platform commission promptly. If a driver's wallet balance drops below the minimum threshold (default: ₦1,000), dispatches are temporarily suspended until the balance is settled via wallet top-up. Persistent non-remittance results in account suspension.

8. DRIVER DAILY STREAKS & COMMISSIONS
Eligible drivers maintain daily dispatch acceptance streaks to unlock reduced commission tiers and milestone bonuses. Declining assigned orders resets streak progression. Public order pool pickups carry standard base commission rates as configured by platform administrators.

9. IN-APP AUDIO CALLING & CHAT STANDARDS
• Calling: Powered by WebRTC peer-to-peer encrypted audio with automatic Agora RTC failover when WebRTC signaling fails. Calls operate without exposing private cellular phone numbers. All provider switchovers occur silently with no technical details exposed to users.
• Trip Chat: Restricted strictly to text messages and image attachments. Audio/voice notes are not permitted in trip chat.
• Support Chat: Allows text, image attachments, and voice notes (maximum 5MB per audio file). Supported audio formats: AAC, MP3, OGG, Opus, WAV, M4A.
• Prohibited Conduct: Abusive language, harassment, discriminatory remarks, solicitation of off-platform transactions, or any threats result in immediate account suspension and referral to law enforcement where warranted.

10. SAFETY, TELEMETRY & SOS EMERGENCY TOOLS
SESE continuously monitors route anomalies, geofence violations, and speed irregularities. An in-app SOS Panic Button is available during active trips for both riders and drivers. Activation alerts SESE Hub safety coordinators with live GPS location. SESE is a technology intermediary platform; during immediate life-safety emergencies, users must contact local law enforcement (112/199) and emergency services directly.

11. DRIVER PRESENCE, BACKGROUND OPERATION & OVERLAY PERMISSIONS
• Android: The Driver Quick-Return Bubble (floating overlay badge) is displayed only when a driver is actively online or has an active trip and the app is in the background. This requires SYSTEM_ALERT_WINDOW permission, which is requested exclusively after an explicit prominent disclosure and consent flow. Drivers may toggle this feature at any time in Driver Settings.
• iOS: Background presence is maintained via Apple Push Notification Service (APNs) Time-Sensitive notifications and Live Activities. No overlay permissions are requested on iOS, ensuring full Apple App Store Guideline 2.5.1 compliance.

12. INDEPENDENT CONTRACTOR STATUS & TAXES
Driver partners are independent contractors, not employees, agents, or representatives of SESE Technology LTD. Drivers are solely responsible for local, state, and federal tax filings, vehicle maintenance, fuel costs, and applicable licensing fees. SESE makes no guarantees of minimum income or guaranteed dispatch volume.

13. LIMITATION OF LIABILITY
SESE's liability for damaged or lost courier goods during transit is capped at the declared transit value or a maximum statutory default cap of ₦50,000 NGN, unless additional transit coverage was purchased at checkout. SESE is not liable for consequential, indirect, or punitive damages arising from service unavailability, route deviation, or driver conduct beyond its reasonable control.

14. ACCOUNT DELETION & REGULATORY ARCHIVAL
Users may delete their account at any time:
• In-App: Settings → Legal & Compliance → Delete Account. Re-authentication required.
• Web Portal: https://sesetech.com/delete
Prerequisites: Zero wallet balance, no active trips or deliveries, no pending driver payout requests. After deletion, data is held in a 30-day regulatory soft-archive for financial audit compliance before permanent PII erasure.

15. DISPUTE RESOLUTION & GOVERNING LAW
These Terms are governed by the laws of the Federal Republic of Nigeria. Unresolved disputes shall first be escalated to SESE's internal resolution desk (legal@sesetech.com). Disputes not resolved within 30 days shall be submitted to binding arbitration under the Arbitration and Mediation Act, 2023.

16. CONTACT & INQUIRIES
Legal: legal@sesetech.com | Support: support@sesetech.com
Privacy Officer: privacy@sesetech.com
Official Terms: https://sesetech.com/terms
Privacy Policy: https://sesetech.com/PrivacyPolicy
Account Deletion: https://sesetech.com/delete
''';

  // ─────────────────────────────────────────────────────────────
  // PRIVACY POLICY
  // ─────────────────────────────────────────────────────────────
  static const String privacyPolicyText = '''
SESE TECHNOLOGY LTD — PRIVACY POLICY & DATA SAFETY ADDENDUM
Last Updated: November 20, 2026
Official Web Portal: https://sesetech.com/PrivacyPolicy

1. COMPLIANCE & FRAMEWORKS
SESE Technology LTD complies with applicable global data privacy frameworks including:
• Nigeria Data Protection Act, 2023 (NDPA) — enforced by the Nigeria Data Protection Commission (NDPC).
• Google Play Developer Data Safety Standards (Android).
• Apple App Store Privacy Nutrition Labels (iOS).

2. RUNTIME PERMISSION DISCLOSURES
• Location (ACCESS_FINE_LOCATION & ACCESS_BACKGROUND_LOCATION):
  - Driver App: Continuous GPS tracking runs in foreground and background while the driver is online. Used for dispatch matching, live route telemetry, accurate ETA computation, and emergency SOS tracking.
  - Rider App: Precise location gathered in foreground only to set pickup/drop-off pins and display nearby vehicles. Location is not tracked after trip completion.
• Contacts (READ_CONTACTS): Accessed exclusively on explicit user tap for "Book for Someone Else" or recipient selection fields. SESE NEVER uploads, harvests, or stores full address books. Only the selected contact's name and phone number are used.
• Camera & Photos (CAMERA, READ_MEDIA_IMAGES): Required for driver KYC document uploads (license, vehicle papers, liveness selfie), damage claim photographs, and trip/support chat image attachments.
• Microphone (RECORD_AUDIO): Used strictly for encrypted in-app WebRTC/Agora VoIP audio calling between riders and drivers, and voice note attachments in Support Chat only.
• System Alert Window (SYSTEM_ALERT_WINDOW) — Android Only: Enables the Driver Quick-Return Bubble floating overlay badge when a driver is online and the app is backgrounded. Requested exclusively after displaying a full prominent disclosure dialog, as required by Google Play policy. Toggleable by the driver at any time.
• Push Notifications (POST_NOTIFICATIONS): Used for new order dispatch alerts, trip status updates, payment confirmations, and in-app message notifications.
• Full-Screen Intent (USE_FULL_SCREEN_INTENT): Displays full-screen incoming order alerts on locked screens for online drivers, ensuring no dispatch is missed.

3. DATA WE COLLECT
• Identity: Full name, phone number, email address (optional), government ID type (not raw ID; hashed only).
• Location: Real-time GPS during active sessions. Historical route data for completed trips.
• Payment: Wallet balance, transaction history, top-up receipts. Card and bank details are processed exclusively by Paystack (PCI-DSS certified). SESE never stores raw card numbers or CVV.
• Device: Device model, OS version, app version, Firebase push token, and anonymized crash reports.
• Communications: Trip chat messages (text/images), support chat messages (text/images/voice notes). These are retained for 30 days post-trip for safety review.

4. DATA ENCRYPTION & IDENTIFIER MASKING
• All client-server communications use TLS 1.3 encryption.
• Phone numbers, government IDs (NIN, BVN, Driver's License), and biometric reference hashes are normalized and stored as SHA-256 cryptographic hashes. Raw PII values are never persisted in SESE databases.
• Fare signing uses a rotating 256-bit HMAC secret to prevent client-side fare tampering.

5. THIRD-PARTY PROCESSORS
• Payments: Paystack (PCI-DSS compliant). Webhooks are verified with constant-time HMAC signatures.
• Maps & Geocoding: Google Maps Platform and OpenStreetMap tile servers.
• Audio Calling: WebRTC (peer-to-peer) and Agora RTC (relay fallback).
• Infrastructure: Google Cloud Platform and Firebase (Firestore, Authentication, Cloud Functions, Cloud Messaging).
• Transactional Email: Resend API (for OTP delivery and administrative notifications).

6. DATA RETENTION & ACCOUNT DELETION
You have the right to request deletion of your personal data at any time. Requests can be submitted:
• In-App: Settings → Legal & Compliance → Delete Account
• Web Portal: https://sesetech.com/delete
Data is subject to a mandatory 30-day regulatory retention period for financial audit and anti-fraud compliance before permanent PII erasure. Transaction receipts, tax records, and driver payout history may be retained for the minimum period required by Nigerian financial regulations.

7. YOUR RIGHTS UNDER NDPA
Under the Nigeria Data Protection Act, 2023, you have the right to:
• Access your personal data held by SESE.
• Correct inaccurate personal data.
• Request erasure (see Section 6 above).
• Object to automated profiling decisions.
• Data portability in a machine-readable format.
To exercise any right, contact: privacy@sesetech.com

8. CHILDREN'S PRIVACY
SESE services are not directed to or intended for use by individuals under 18 years of age. We do not knowingly collect personal data from minors.

9. PRIVACY CONTACT
Data Protection Officer: privacy@sesetech.com
Customer Support: support@sesetech.com
Terms of Service: https://sesetech.com/terms
Official Privacy Policy: https://sesetech.com/PrivacyPolicy
Account Deletion Portal: https://sesetech.com/delete
''';

  // ─────────────────────────────────────────────────────────────
  // ACCOUNT & DATA DELETION POLICY
  // ─────────────────────────────────────────────────────────────
  static const String accountDeletionText = '''
SESE TECHNOLOGY LTD — ACCOUNT & DATA DELETION POLICY
Last Updated: November 20, 2026
Official Deletion Portal: https://sesetech.com/delete

1. RIGHT TO DELETION
You have the right to request deletion of your SESE account, profile, and all associated personal data at any time, in compliance with the Nigeria Data Protection Act, 2023 (NDPA) and Google Play Developer Policy.

2. HOW TO REQUEST DELETION

OPTION A — In-App (Instant Workflow):
Navigate to: Settings → Legal & Compliance → Delete Account
You will be required to re-authenticate (password or Google sign-in) and confirm your intent. The in-app workflow checks all financial prerequisites in real time before initiating deletion.

OPTION B — Online Web Portal:
Visit https://sesetech.com/delete and submit your registered phone number or email address. Our compliance desk will verify your identity and process the request within 24–48 business hours.

OPTION C — Email Request:
Send a request from your registered email to: support@sesetech.com
Subject: Account Deletion Request — [Your Registered Phone Number]

3. DATA ERASURE & REGULATORY RETENTION
• Immediate Erasure (upon deletion execution):
  - Full name, email address, saved locations, profile photo, and push notification tokens.
  - Firebase Authentication credentials (email/password or Google sign-in link).
  - SHA-256 hashed phone/government ID uniqueness records.
  - Device registration entries and contact picker references.

• 30-Day Regulatory Retention:
  - Transaction receipts, fare records, and commission settlement statements are retained in an encrypted, access-restricted soft-archive for 30 days to satisfy financial audit and anti-fraud regulatory obligations.
  - After 30 days, all retained records are permanently purged or fully anonymized such that no personal re-identification is possible.

• Driver-Specific Retention:
  - Pending bank payout records are retained until settlement is complete before account closure finalizes.
  - Vehicle registration and insurance documents associated with completed trips are retained for the statutory minimum period.

4. MANDATORY PREREQUISITES FOR DELETION
Your account cannot be deleted until ALL of the following conditions are met:
• In-app wallet balance must be exactly ₦0.00 (withdraw or spend all funds first).
• No active trips or courier deliveries currently in progress.
• No pending driver bank payout requests awaiting settlement.
• No unresolved disputes or fraud investigations flagged by SESE Compliance.

5. WHAT HAPPENS AFTER DELETION
• Your account is immediately deactivated; login access is revoked.
• Your phone number and email become eligible for re-registration after the 30-day archival window.
• Any residual anonymized analytics data (trip counts, aggregate route data) may be retained indefinitely in de-identified form for platform improvement purposes.
• You will receive a final email confirmation of deletion initiation.

6. REACTIVATION POLICY
Deleted accounts cannot be reactivated. If you wish to use SESE services after deletion, you must register a new account subject to full KYC re-verification.

7. CONTACT
For deletion requests, inquiries, or to exercise NDPA data rights:
• Support: support@sesetech.com
• Privacy Officer: privacy@sesetech.com
• Web Portal: https://sesetech.com/delete
• Privacy Policy: https://sesetech.com/PrivacyPolicy
• Terms of Service: https://sesetech.com/terms
''';
}
