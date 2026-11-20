/// Types of legal documents in the SESE Ecosystem.
enum LegalDocType {
  terms,
  privacy,
  accountDeletion,
}

/// Global legal copy for SESE Technology LTD.
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

  static const String termsOfServiceText = '''
SESE TECHNOLOGY LTD — GLOBAL TERMS OF SERVICE
Last Updated: November 20, 2026
Official Web Portal: https://sesetech.com/terms

1. ACCEPTANCE & GOVERNING AGREEMENT
By creating an account, accessing, or using SESE Technology LTD ("SESE", "Company", "We", "Us") platforms, including SESE Ride (Rider and Driver modes) and SESE Hub operations desk, you ("User", "Rider", "Driver", "Partner") agree to be bound by these Terms of Service, Privacy Policy (https://sesetech.com/privacy), and Account Deletion Policy (https://sesetech.com/delete). If you do not agree, you must immediately cease accessing or using our services.

2. IDENTITY VERIFICATION, KYC & STRICT ONE-ACCOUNT POLICY
• Strict One-Person-One-Account Enforcement: Every user or driver is permitted exactly one account tied to a verified phone number, government ID, and unique device. SESE normalizes and hashes identity credentials (NIN, BVN, Driver's License) via SHA-256 to ensure duplicate prevention without storing raw PII.
• Driver KYC Requirements: Drivers must maintain a valid driver's license, vehicle registration, roadworthiness certificate, active third-party/comprehensive motor insurance, and complete live facial verification.
• Anti-Spoofing & Platform Security: GPS spoofing, mock location software, virtual emulators, rooted devices, or modified app binaries are strictly prohibited and result in permanent device bans and fund forfeiture.

3. RIDE-HAILING & SYNCHRONIZED FARE BIDDING
• Intermediary Technology Status: SESE connects passengers with verified independent third-party driver partners. SESE does not own vehicles or operate direct transport services.
• Synchronized Bidding: On enabled routes, drivers can accept published base fares or submit a counter-bid. Riders receive real-time bids with live countdowns and may accept, decline, or counter-offer. Once accepted, the agreed fare is binding.

4. ON-DEMAND LOGISTICS & COURIER DELIVERY
• Prohibited Goods: Senders must ensure packages contain no illegal drugs, unregistered firearms, weapons, toxic materials, hazardous goods, stolen items, or counterfeit property. Drivers retain the right to inspect exterior packaging and decline transit.
• Delivery PIN Verification: Couriers require a secure 4-digit PIN delivered to the recipient, which must be validated before delivery completion.

5. PRICING, IMMEDIATE WALLET DEDUCTION & ESCROW
• Server-Authoritative Money: Fares, commission rates, waiting fees, and settlements are calculated strictly by SESE authoritative backend servers.
• Immediate Prepayment & Escrow Lock: For trips paid via Wallet or Card, the fare is immediately deducted from the customer's available balance and held in secure server Escrow upon booking. This prevents balance double-spending. Driver partners receive wallet credit upon confirmed drop-off completion.

6. CANCELLATION RULES, WAITING FEES & IN-PROGRESS LOCK
• Cancellation Before Trip Start: Riders may cancel without fee before a driver arrives.
• Waiting Fees: If a driver partner arrives at the pickup and waits past the Grace Period (default: 10 minutes), an automated waiting fee (default: ₦20 per minute) accrues dynamically.
• Strict In-Progress Cancellation Lock: Once a ride is started (status: IN_PROGRESS or pending_customer_approval), in-app cancellation by either rider or driver is strictly locked. The trip must proceed to destination.
• Support Intervention: In verifiable emergencies, a SESE Hub support administrator can cancel/refund the trip to the rider's wallet, with driver fare forfeited except for valid waiting compensation.

7. CASH REMITTANCE & DRIVER WALLET RULES
Drivers collecting cash fares must remit platform commission promptly. If a driver's wallet balance drops below the minimum threshold (default: ₦1,000), dispatches are temporarily held until settled via top-up.

8. DRIVER DAILY STREAKS & COMMISSIONS
Eligible drivers maintain daily dispatch acceptance to unlock reduced commission tiers and milestone bonuses. Declining assigned orders resets streak progression. Public order pool pickups carry standard base commission.

9. IN-APP AUDIO CALLING & CHAT STANDARDS
• Calling: Powered by WebRTC peer-to-peer audio with automatic Agora RTC failover. Calling states operate cleanly without exposing private cellular numbers.
• Chat Protocol: Trip Chat is restricted to text and photos. Support Chat allows voice notes (up to 5MB). Abusive language, harassment, or off-platform solicitation results in immediate suspension.

10. SAFETY, TELEMETRY & SOS EMERGENCY TOOLS
SESE monitors route anomalies and provides an in-app SOS Panic Button. SESE is a technology platform; during immediate life-safety emergencies, users must contact local law enforcement authorities directly.

11. INDEPENDENT CONTRACTOR STATUS & TAXES
Driver partners are independent contractors, not employees or agents of SESE Technology LTD. Drivers are solely responsible for local, state, and federal tax filings.

12. LIMITATION OF LIABILITY
SESE liability for damaged or lost courier goods during transit is capped at declared transit value or a maximum statutory default cap of ₦50,000 NGN, unless extra transit coverage was purchased at checkout.

13. ACCOUNT DELETION & REGULATORY ARCHIVAL
Users may delete their account at any time via App Settings -> Account Privacy -> Delete Account, or through our web portal at https://sesetech.com/delete. Accounts must have zero balance and no ongoing trips. Data is held in a 30-day regulatory soft-archive before permanent PII erasure.

14. DISPUTE RESOLUTION & GOVERNING LAW
These Terms are governed by the laws of the Federal Republic of Nigeria. Unresolved disputes shall be submitted to binding arbitration under the Arbitration and Mediation Act.

15. CONTACT & INQUIRIES
Legal: legal@sesetech.com | Support: support@sesetech.com
Official Portal: https://sesetech.com/terms
''';

  static const String privacyPolicyText = '''
SESE TECHNOLOGY LTD — PRIVACY POLICY & DATA SAFETY ADDENDUM
Last Updated: November 20, 2026
Official Web Portal: https://sesetech.com/privacy

1. COMPLIANCE & FRAMEWORKS
SESE Technology LTD complies with global data privacy frameworks, including the Nigeria Data Protection Act (NDPA), GDPR, and Google Play Developer Data Safety Standards.

2. RUNTIME PERMISSION DISCLOSURES
• Location (ACCESS_FINE_LOCATION & ACCESS_BACKGROUND_LOCATION):
  - Driver App: Continuous location tracking runs in both foreground and background while online to enable dispatch matching, route telemetry, accurate ETA, and emergency tracking.
  - Rider App: Precise location is gathered in foreground to set pickup/drop-off points and view nearby vehicles.
• Contacts (READ_CONTACTS): Accessed strictly on explicit user tap for "Book for Someone Else" or parcel recipient selection. SESE NEVER uploads or harvests full address books.
• Camera & Photos (CAMERA, READ_MEDIA_IMAGES): Required for driver partner document onboarding (driver's license, vehicle papers, liveness selfie), damage claim photos, and profile pictures.
• Microphone (RECORD_AUDIO): Used strictly for encrypted in-app audio VoIP calling and support voice notes.
• System Alert Window (SYSTEM_ALERT_WINDOW): Enables floating incoming order alerts over navigation maps for online drivers.

3. DATA ENCRYPTION & IDENTIFIER MASKING
All communications use TLS 1.3 encryption. Phone numbers and government IDs are normalized and stored as SHA-256 cryptographic hashes for single-account verification.

4. THIRD-PARTY PROCESSORS
• Payments: Paystack (PCI-DSS compliant). SESE never stores raw card or CVV details.
• Maps & Geocoding: Google Maps Platform and OpenStreetMap.
• Audio Calling: WebRTC and Agora RTC.
• Infrastructure: Google Cloud Platform & Firebase.

5. DATA RETENTION & ACCOUNT DELETION
Users have the full right to delete their personal data. Requests can be submitted in-app (Settings -> Delete Account) or online at https://sesetech.com/delete. Data is subject to a 30-day regulatory retention period before permanent PII erasure.

6. PRIVACY CONTACT
Data Protection Officer: privacy@sesetech.com | Support: support@sesetech.com
Web: https://sesetech.com/privacy
''';

  static const String accountDeletionText = '''
SESE TECHNOLOGY LTD — ACCOUNT & DATA DELETION POLICY
Last Updated: November 20, 2026
Official Deletion Portal: https://sesetech.com/delete

1. RIGHT TO DELETION
You have the right to request deletion of your SESE account, profile, and all associated personal data at any time.

2. HOW TO REQUEST DELETION
• In-App (Instant): Navigate to Settings -> Legal & Compliance -> Delete Account. Re-authenticate to confirm.
• Online Web Portal: Visit https://sesetech.com/delete and submit your registered phone number or email address.

3. DATA ERASURE & REGULATORY RETENTION
• Immediate Erasure: Profile details, authentication credentials, saved locations, push tokens, and contact picker references are purged upon deletion execution.
• 30-Day Regulatory Retention: Transaction receipts, tax records, and driver payout history are maintained in an encrypted, restricted soft-archive for 30 days to satisfy financial audit and anti-fraud regulations, after which they are permanently purged or anonymized.

4. MANDATORY PREREQUISITES
• In-app wallet balance must be exactly ₦0.00.
• No active trips or courier deliveries in progress.
• No pending driver bank payout requests awaiting settlement.

For support, contact support@sesetech.com or visit https://sesetech.com/delete.
''';
}
