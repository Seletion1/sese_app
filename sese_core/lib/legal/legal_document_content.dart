/// Types of legal documents in the SESE Ecosystem.
enum LegalDocType {
  terms,
  privacy,
}

/// Global legal copy for SESE Technology LTD.
abstract final class LegalDocumentContent {
  static String titleFor(LegalDocType type) {
    switch (type) {
      case LegalDocType.terms:
        return 'Terms of Use';
      case LegalDocType.privacy:
        return 'Privacy Policy';
    }
  }

  static String contentFor(LegalDocType type) {
    switch (type) {
      case LegalDocType.terms:
        return termsOfServiceText;
      case LegalDocType.privacy:
        return privacyPolicyText;
    }
  }

  static const String termsOfServiceText = '''
SESE TECHNOLOGY LTD — GLOBAL TERMS OF SERVICE
Last Updated: October 4, 2026

1. ACCEPTANCE & GOVERNING AGREEMENT
By creating an account, accessing, or using SESE Technology LTD ("SESE", "Company", "We", "Us"), you ("User", "Rider", "Driver", "Merchant", "Partner") agree to be bound by these Terms of Service, Privacy Policy, and all applicable global and local laws. If you do not agree, you must immediately cease accessing or using our services.

2. ANTI-SPOOFING, ANTI-TAMPERING & PLATFORM SECURITY
To preserve platform integrity and dispatch accuracy:
• Prohibited Hardware/Software Modifications: Users, Drivers, and Partners are strictly forbidden from utilizing GPS spoofing applications, mock location software, virtual Android emulators, rooted devices (e.g., Magisk), or modified APK/IPA binaries to falsify coordinates or automate order acceptance.
• Security & Device Attestation: SESE employs automated background hardware attestation, device fingerprinting, and dynamic route checks.
• Consequences of Violation: Detection of spoofing, telemetry manipulation, reverse-engineering, or unauthorized API interaction results in immediate permanent device-ID ban, total forfeiture of accumulated wallet balance, and referral to law enforcement.

3. PROMOTIONS, REFERRALS & ANTI-FRAUD REGULATIONS
• Strict One-Account Policy: Every user is allowed exactly one personal or driver account tied to a verified phone number, national identity document, and unique device identifier.
• Promo Abuse: Any attempt to manipulate streak rewards, referral bonuses, promo codes, or simulated trips (ghost riding) will trigger automatic clawback of funds, permanent account closure, and potential legal recovery claims.

4. RIDE-HAILING & LOGISTICS REGULATORY COMPLIANCE
• Driver Eligibility & Safety: Drivers must maintain valid driver licenses, vehicle registration, roadworthiness certificates, and active third-party or comprehensive insurance matching local municipal standards (e.g., Lagos State Ministry of Transportation guidelines and equivalent global transport authorities).
• Zero Tolerance for Drugs/Alcohol: SESE maintains an absolute Zero Tolerance policy regarding substance use while operating on the network.
• Prohibited Items for Delivery: Customers and Drivers must strictly adhere to international logistics rules. Prohibited items include illegal drugs, unregistered firearms, explosives, hazardous chemicals, stolen property, unsealed perishable goods, and counterfeit items.

5. DYNAMIC PRICING, FEES & WALLET PAYOUTS
• Fare Structure: Base fares, distance rates, time surcharges, and streak fees are calculated dynamically based on real-time demand, traffic, and platform configuration.
• Payout Deductions & Chargebacks: SESE reserves the right to withhold, freeze, or adjust driver earnings in cases of confirmed customer fraud, abandoned deliveries, unverified trip routes, or disputed credit card/mobile wallet chargebacks.

6. CASH-ON-DELIVERY (COD) & OFFLINE FARE SETTLEMENTS
• Driver Cash Limits: Drivers accepting cash for rides or deliveries must remit platform commission fees to their wallet within 24 hours or upon reaching the local currency cash threshold (e.g., ₦20,000 / \$50 USD equivalent).
• Non-Remittance & Suspension: Failure to settle negative wallet balances blocks driver dispatch access immediately.
• Customer Non-Payment: If a customer refuses to pay cash upon completion of a trip or delivery, the driver must report the incident immediately via the emergency inbox in sese_ride. SESE will compensate verified drivers and restrict the customer's phone number and device from further bookings.

7. EMERGENCY, SAFETY & SOS FEATURE DISCLAIMERS
• In-App Safety Tools: SESE provides an in-app emergency alert / panic button for drivers and riders.
• Limitation of Emergency Response: SESE is a technology platform connecting third-party independent contractors and customers; it is not a primary emergency dispatch service. The triggering of an in-app panic button sends automated alerts to emergency contacts and logs coordinates, but users must contact local emergency services (e.g., Police, First Responders) directly in critical situations.

8. TAX COMPLIANCE & INDEPENDENT CONTRACTOR STATUS
• No Employment Relationship: Drivers, riders, and fleet operators are independent third-party contractors and not employees, agents, or joint partners of SESE Technology LTD.
• Tax Obligations: Contractors are solely responsible for reporting, calculating, and paying all applicable municipal, state, and federal income taxes, local VAT/GST, and social contribution fees in their operating jurisdiction.

9. INDEMNIFICATION & MAXIMUM LIMITATION OF LIABILITY
• Loss or Damage to Goods: SESE's maximum liability for lost, damaged, or delayed parcels during transit is capped at the total value declared during booking or a maximum default cap of \$50 USD equivalent per delivery, whichever is lower, unless extra transit insurance was selected at checkout.
• Platform Availability Disclaimer: Services are provided on an "AS IS" and "AS AVAILABLE" basis. SESE does not guarantee zero server downtime, unbroken map tile availability, or uninterrupted GPS location tracking.

10. VEHICLE INSURANCE & PASSENGER/PARCEL COVERAGE
• Driver Insurance Requirements: All drivers operating motorcycles, tricycles, or cars must maintain active Third-Party or Comprehensive Motor Vehicle Insurance compliant with regional transport laws (e.g., Nigerian Insurance Act / NAICOM standards).
• Platform Non-Liability for Uninsured Vehicles: SESE does not provide primary motor vehicle liability insurance for independent driver vehicles. Drivers are personally liable for any traffic violations, road accidents, or collisions occurring while online or en route.

11. DISPUTE RESOLUTION, ARBITRATION & JURISDICTION
• Mandatory Informal Resolution: Before filing any formal legal claim, users and drivers agree to submit dispute details to SESE Support (support@sesetech.com) and attempt good-faith negotiation for at least 30 days.
• Binding Arbitration: Any unresolved dispute, claim, or controversy arising out of these Terms shall be settled by binding arbitration in accordance with local arbitration laws (e.g., the Arbitration and Mediation Act of Nigeria for regional operations). Users explicitly waive rights to participate in class-action lawsuits or class-wide arbitration against SESE Technology LTD.

12. ABANDONED PARCELS & UNCLAIMED GOODS
• Non-Delivery Protocol: If a receiver is unreachable at the destination after a 15-minute waiting window, the driver will attempt to return the parcel to the sender.
• Return Fees: Return trips are billed automatically to the sender's account/wallet at standard trip rates.
• Holding Period: If both sender and receiver are unreachable, the item is surrendered to a SESE Hub office. Items unclaimed after 14 days will be disposed of or donated, and SESE disclaims all liability for forfeited property.
''';

  static const String privacyPolicyText = '''
SESE TECHNOLOGY LTD — PRIVACY POLICY & DATA SAFETY ADDENDUM
Last Updated: October 4, 2026

1. APP PERMISSIONS & DATA USAGE DISCLOSURES
SESE explicitly declares the collection, scope, and operational necessity of all runtime and system permissions requested across SESE Ride (Customer & Driver) and SESE Hub:

a) Contacts List Access (READ_CONTACTS):
• Purpose: Accessed exclusively when a customer taps the Contacts icon to "Book for Someone Else" or auto-fill a parcel recipient's phone number.
• Mechanism: Tapping the icon launches the system contact picker. The app retrieves only the selected contact's display name and primary mobile number to populate the booking field.
• Privacy Guarantee: SESE NEVER uploads, harvests, indexes, or stores your full address book on our servers. Only the single contact explicitly chosen for a specific transaction is processed for trip dispatch.

b) Location Access (ACCESS_FINE_LOCATION & ACCESS_BACKGROUND_LOCATION):
• Driver App: Continuous location data is collected in both the foreground and background (including when the app is closed or the screen is off) to calculate driver-to-pickup proximity, enable live route navigation, execute automated dispatch matching, and provide driver emergency safety tracking.
• Customer App: Precise location data is collected in the foreground while searching or during an active ride to locate pickup points, display nearby available vehicles, and show real-time progress.

c) Photos, Camera & Storage Access (CAMERA, READ_EXTERNAL_STORAGE, READ_MEDIA_IMAGES):
• Purpose: Required for driver onboarding verification (capturing driver license, vehicle registration, and live facial verification selfie), submitting delivery dispute evidence (attaching photos of damaged/missing goods), and customizing user profile avatars.

d) System Alert Window / Overlay Permission (SYSTEM_ALERT_WINDOW):
• Driver App: Enables floating, high-priority incoming order alerts over third-party applications when a driver is online and navigating via external maps (e.g., Google Maps or Waze).

e) Phone State & Device Identification (READ_PHONE_STATE, Hardware Fingerprinting):
• Purpose: Utilized strictly for hardware security attestation, anti-spoofing verification, device fingerprinting, and preventing fraudulent referral/promo code abuse on a single physical device.

2. INTERNATIONAL DATA PRIVACY COMPLIANCE
SESE complies with global data privacy frameworks, including the General Data Protection Regulation (GDPR), Nigeria Data Protection Act (NDPA), and Google Play Developer Data Safety Standards.

3. DATA RETENTION & ACCOUNT DELETION PROTOCOL
Users retain full ownership of their data and may request total account deletion at any time via App Settings -> Account Privacy -> Delete Account. All Personally Identifiable Information (PII) is permanently purged within 30 days, except where financial, tax, or legal reporting mandates transactional retention.
''';
}
