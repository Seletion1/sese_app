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

2. ACCOUNT REGISTRATION, IDENTITY VERIFICATION & ONE-ACCOUNT POLICY
• Account Creation Methods: Users may create an account using phone number verification, email and password, or federated OAuth (Google Sign-In). All account credentials are bound to a verified identity.
• Strict One-Person-One-Account Enforcement: Every user or driver is permitted exactly one account tied to a verified phone number, government ID, and unique device. SESE normalizes and hashes identity credentials (NIN, BVN, Driver's License) via SHA-256 to ensure duplicate prevention without storing raw PII.
• Driver KYC Requirements: Drivers must maintain a valid driver's license, vehicle registration, roadworthiness certificate, active motor insurance, and complete live facial verification before dispatch eligibility is granted.
• Anti-Spoofing & Platform Security: GPS spoofing, mock location software, virtual emulators, rooted devices, or modified app binaries are strictly prohibited and result in permanent device bans and fund forfeiture.

3. RIDE-HAILING & SYNCHRONIZED FARE BIDDING
• Intermediary Technology Status: SESE connects passengers with verified independent third-party driver partners. SESE does not own vehicles or operate direct transport services.
• Synchronized Bidding: On enabled routes, drivers can accept published base fares or submit a counter-bid. Riders receive real-time bids with live countdowns and may accept, decline, or counter-offer. Once accepted, the agreed fare is binding and cannot be modified mid-trip.

4. ON-DEMAND LOGISTICS & COURIER DELIVERY
• Prohibited Goods: Senders must ensure packages contain no illegal drugs, unregistered firearms, weapons, toxic materials, hazardous goods, stolen items, or counterfeit property. Drivers retain the right to inspect exterior packaging and decline transit.
• Delivery PIN Verification: Couriers require a secure 4-digit PIN delivered to the recipient, which must be validated before delivery completion. Delivery is not finalized without successful PIN confirmation.

5. PRICING & DIRECT ORDER PAYMENTS
• Server-Authoritative Pricing: Fares, commission rates, waiting fees, and settlements are calculated strictly by SESE's authoritative backend servers. No client-side fare computation is permitted or honored.
• Direct Trip Payments: Customer trips are paid directly per booking via Cash or online Card (Paystack checkout). When paid online, trip payments are authorized through licensed gateways in ESCROW until trip completion. SESE does not operate a stored-value customer wallet, customer deposits, or withdrawal system.
• Online Payment Processing: When paying online, payment is authorized directly through Paystack's PCI-DSS compliant checkout. SESE never stores raw card PAN or CVV details. If an online payment declines, the customer must select Cash or retry before trip execution.

6. CANCELLATION RULES, WAITING FEES & IN-PROGRESS LOCK
• Cancellation Before Trip Start: Riders may cancel without fee before a driver arrives at the pickup point.
• Waiting Fees: If a driver partner arrives at the pickup location and waits beyond the Grace Period (default: 10 minutes), an automated waiting fee (default: ₦20 per minute) accrues dynamically as configured by platform administrators.
• Strict In-Progress Cancellation Lock: Once a ride is started (status: IN_PROGRESS or pending_customer_approval), in-app cancellation by either rider or driver is strictly locked. The trip must proceed to its destination.
• Support Intervention: In verifiable emergencies, a SESE Hub Support administrator can cancel the trip.
• Hub Admin Cancellation: Hub administrators retain the authority to cancel any trip regardless of status and manually settle driver waiting compensation.

7. CASH REMITTANCE & DRIVER SESE CREDITS
• Non-Withdrawable Dispatch Credits: SESE provides Driver Sese Credits strictly as non-withdrawable platform service credits used to settle trip commissions. Sese Credits carry zero cash value, cannot be withdrawn, transferred, or cashed out.
• Commission Remittance: Drivers collecting cash fares retain the full customer fare and remit platform commission via their Sese Credits balance. Drivers purchase Sese Credits via Paystack checkout. Dispatches are temporarily paused if credits fall below the minimum threshold until topped up.

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
Prerequisites: No active trips or deliveries in progress. After deletion, data is held in a 30-day regulatory soft-archive for audit compliance before permanent PII erasure.

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
• Camera & Photos (CAMERA, READ_MEDIA_IMAGES): Required for driver KYC document uploads (license, vehicle papers, liveness selfie), damage claim photographs, proof-of-delivery images, and trip/support chat image attachments.
• Microphone (RECORD_AUDIO): Used strictly for encrypted in-app WebRTC/Agora VoIP audio calling between riders and drivers, and voice note attachments in Support Chat only.
• System Alert Window (SYSTEM_ALERT_WINDOW) — Android Only: Enables the Driver Quick-Return Bubble floating overlay badge when a driver is online and the app is backgrounded. Requested exclusively after displaying a full prominent disclosure dialog, as required by Google Play policy. Toggleable by the driver at any time.
• Push Notifications (POST_NOTIFICATIONS): Used for new order dispatch alerts, trip status updates, payment confirmations, and in-app message notifications.
• Full-Screen Intent (USE_FULL_SCREEN_INTENT): Displays full-screen incoming order alerts on locked screens for online drivers, ensuring no dispatch is missed.

3. GOOGLE PLAY DATA SAFETY DECLARATION & DATA TYPES COLLECTED
In strict alignment with our Google Play Console Data Safety disclosures, SESE Technology LTD collects the following categories of data. All data is collected directly for legitimate business purposes; No user data is shared with third parties for commercial or advertising purposes:

(1) Personal Info:
  • Name: Collected for App functionality, Analytics, Developer communications, Fraud prevention/security/compliance, Personalization, and Account management.
  • Email Address: Collected for App functionality, Analytics, Developer communications, Fraud prevention, Personalization, and Account management.
  • User IDs: Firebase Authentication UID assigned to each account for App functionality, Security, and Account management.
  • Address: Physical pickup, destination, and saved addresses for App functionality, Analytics, Fraud prevention, and Personalization.
  • Phone Number: Verified E.164 phone number collected for Account authentication, 2FA, Fraud prevention, and Driver-Rider contact.
  • Other Info: Cryptographic SHA-256 hashes of government IDs (NIN, BVN, Driver's License) for Driver KYC duplicate prevention, age/date of birth validation, and vehicle registration numbers.

(2) Financial Info:
  • User Payment Info: Paystack tokenized card reference keys for direct trip payments and driver Sese Credits purchases for App functionality, Fraud prevention, and Account management. SESE never stores raw card PAN or CVV.
  • Purchase History: Direct ride fares, courier deliveries, Sese Credits purchases, and transaction receipts for App functionality, Accounting, Analytics, and Legal compliance.

(3) Location:
  • Approximate Location: Coarse geographic fix used for regional service availability, city-level analytics, and initial map center.
  • Precise Location: Real-time high-accuracy GPS coordinates collected during active sessions (and in background for online drivers) for live dispatch matching, turn-by-turn routing, ETA calculation, and SOS emergency safety monitoring.

(4) Messages:
  • Other In-App Messages: Rider-driver in-trip chat messages and customer support conversations collected for App functionality, Customer support, Safety, and Dispute resolution.

(5) Photos and Videos:
  • Photos: Driver license images, vehicle inspection photos, proof-of-delivery parcel photos, user avatar profile photos, and support claim documentation. Data collection is required for App functionality, KYC verification, Fraud prevention, and Account management.

(6) Audio Files:
  • Voice or Sound Recordings: VoIP voice audio during active in-app calls between rider and driver (WebRTC/Agora RTC) and recorded voice notes submitted in Support Chat for App functionality, Communications, and Quality assurance.

(7) Contacts:
  • Contacts: Accessed strictly via the native system contact picker on explicit user action ("Book for Someone Else" / "Package Recipient"). Only the chosen contact's name and telephone number are utilized. No bulk contact harvesting or address book storage occurs.

(8) Files and Docs:
  • Files and Docs: Driver vehicle registration papers, roadworthiness certificates, commercial insurance documents, and exported transaction receipts for App functionality, Driver verification, and Regulatory compliance.

(9) App Activity:
  • App Interactions: Order dispatch requests, fare bidding interactions, trip acceptance, ratings, and reviews collected for App functionality, Analytics, and Fraud prevention.
  • In-App Search History: Address search queries and recently visited locations collected for App functionality, Personalization, and Auto-complete convenience.

(10) Web Browsing:
  • Web Browsing History: In-app WebView browsing events strictly associated with Paystack 3D-Secure card verification, bank authorization flows, and official legal portals (sesetech.com).

(11) App Info and Performance:
  • Crash Logs: Firebase Crashlytics stack traces, exceptions, and memory states collected for Analytics, Diagnostics, and Software stabilization.
  • Diagnostics: Network latency, WebRTC signaling quality, and API response timing collected for App performance optimization.
  • Other App Performance Data: App launch duration, frame rendering performance, and device battery/memory telemetry.

(12) Device or Other IDs:
  • Device or Other IDs: Firebase installation identifier, Firebase Cloud Messaging (FCM) push token, device manufacturer, model, and OS version collected for App functionality, Push notifications, Device binding, Fraud prevention, and Account management.

4. DATA ENCRYPTION & SECURITY PRACTICES
• Encrypted in Transit: All network communications between the mobile application and SESE backend servers are strictly encrypted using Transport Layer Security (TLS 1.3).
• Account Creation Methods: SESE supports account creation via username (email/phone) and password, as well as federated OAuth (Google Sign-In).
• Independent Third-Party Sharing: SESE declares "No data shared with third parties" on Google Play. Data is processed solely by certified infrastructure processors (Firebase, Google Cloud Platform, Paystack) under strict data processing agreements.
• Identifier Masking: Government identification numbers (NIN, BVN, Driver's License) are converted to SHA-256 cryptographic hashes before database persistence. Raw identity numbers are never stored on SESE servers.
• Fare Tamper Protection: Fares and financial calculations use rotating 256-bit HMAC signatures to guarantee server authority.

5. THIRD-PARTY INFRASTRUCTURE PROCESSORS
• Payments: Paystack (PCI-DSS Level 1 Certified).
• Maps & Geocoding: Google Maps Platform and OpenStreetMap tiles.
• Audio Calling: WebRTC (peer-to-peer audio) and Agora RTC (relay fallback).
• Backend & Cloud Compute: Google Cloud Platform and Firebase (Firestore, Cloud Functions, Cloud Messaging, Crashlytics).
• Transactional Communications: Resend API (for administrative emails and OTP delivery).

6. DATA RETENTION & ACCOUNT DELETION
Users have the absolute right to delete their SESE account and associated personal data at any time:
• In-App: Settings → Legal & Compliance → Delete Account
• Official Web Deletion Portal: https://sesetech.com/delete
• Regulatory Soft-Archive Retention: In accordance with Nigerian financial anti-money laundering and tax regulations, financial ledger records, transaction receipts, and driver payout history are maintained in an access-restricted soft-archive for thirty (30) days prior to permanent, irreversible PII erasure.

7. YOUR RIGHTS UNDER NDPA & GDPR
Under the Nigeria Data Protection Act (NDPA) 2023, users enjoy the right to:
• Access: Request a copy of personal information maintained by SESE.
• Rectification: Correct inaccurate or incomplete profile data.
• Erasure: Request permanent deletion of your account and personal records.
• Restriction: Restrict processing of personal data under disputed circumstances.
• Portability: Receive personal data in a structured, machine-readable format.
To exercise your rights, email our Data Protection Officer at: privacy@sesetech.com

8. CHILDREN'S PRIVACY
SESE services are strictly restricted to individuals aged 18 years and older. We do not knowingly collect, solicit, or process personal data from minors.

9. PRIVACY OFFICER & OFFICIAL LINKS
• Data Protection Officer: privacy@sesetech.com
• Customer Support: support@sesetech.com
• Official Terms of Service: https://sesetech.com/terms
• Official Privacy Policy: https://sesetech.com/PrivacyPolicy
• Official Account Deletion Portal: https://sesetech.com/delete
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
You will be required to re-authenticate (email/password or Google Sign-In) and confirm your intent. The in-app workflow verifies all financial prerequisites in real time before initiating deletion.

OPTION B — Online Web Portal:
Visit https://sesetech.com/delete and submit your registered phone number or email address. Our compliance desk will verify your identity and process the request within 24–48 business hours.

OPTION C — Email Request:
Send a request from your registered email to: support@sesetech.com
Subject: Account Deletion Request — [Your Registered Phone Number]

3. DATA ERASURE & REGULATORY RETENTION
• Immediate Erasure (upon deletion execution):
  - Personal info: Full name, email address, physical addresses, saved locations, profile avatar photo, and push notification tokens.
  - Authentication credentials: Email/password records or federated Google Sign-In linkage in Firebase Authentication.
  - Identity records: SHA-256 hashed phone, NIN, BVN, and Driver's License uniqueness records.
  - Media & Communications: Rider-driver in-app chat logs, support chats, voice recordings, and delivery proof photos.
  - Device telemetry: FCM tokens, device identifiers, and recent search history.

• 30-Day Regulatory Retention (Soft-Archive):
  - In compliance with statutory anti-money laundering (AML), tax, and financial accounting laws in the Federal Republic of Nigeria, completed transaction ledgers, fare invoices, and driver bank payout summaries are held in an encrypted, access-restricted soft-archive for thirty (30) days.
  - Following the 30-day archival period, all retained financial records are permanently purged or irrevocably anonymized such that personal re-identification is mathematically impossible.

• Driver-Specific Retention:
  - Vehicle registration certificates, insurance documents, and roadworthiness records associated with completed trips are archived for the statutory minimum period.

4. MANDATORY PREREQUISITES FOR DELETION
Your account cannot be deleted until ALL of the following conditions are met:
• No active trips or courier deliveries currently in progress.
• Zero outstanding platform debt balance (₦0.00).
• No unresolved disputes or fraud investigations flagged by SESE Compliance.

5. WHAT HAPPENS AFTER DELETION
• Your account is immediately deactivated; login access is permanently revoked.
• Your phone number and email become eligible for re-registration after the 30-day archival window.
• Any residual anonymized analytics data (trip counts, aggregate route metrics) may be retained indefinitely in de-identified form for platform improvement.
• You will receive a final confirmation email confirming that your account has been scheduled for deletion.

6. REACTIVATION POLICY
Deleted accounts cannot be reactivated. If you wish to use SESE services after deletion, you must register a new account subject to full KYC re-verification.

7. CONTACT & COMPLIANCE
For deletion requests, inquiries, or to exercise NDPA data rights:
• Customer Support: support@sesetech.com
• Data Protection Officer: privacy@sesetech.com
• Official Web Deletion Portal: https://sesetech.com/delete
• Official Privacy Policy: https://sesetech.com/PrivacyPolicy
• Official Terms of Service: https://sesetech.com/terms
''';
}
