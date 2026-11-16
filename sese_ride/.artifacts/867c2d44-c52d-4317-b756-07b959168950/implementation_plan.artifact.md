# Fix Unauthenticated Identifier Enumeration & Oracle Vulnerability in checkIdentifierAvailability

Fix the unauthenticated identifier enumeration and oracle vulnerability in `checkIdentifierAvailability` located in `functions/src/uniqueIdentifiers.ts`.

## User Review Required

> [!IMPORTANT]
> - `checkIdentifierAvailability` previously allowed unauthenticated, rate-unlimited lookups for sensitive identity fields.
> - With this change:
>   - Unauthenticated requests will be rejected immediately with `HttpsError('unauthenticated')`.
>   - Per-UID sliding window rate limiting (30 requests/min) will be enforced to prevent scraping/credential stuffing.
>   - Sensitive identity lookups (`nin`, `bvn`, `passport`, `drivers_license`) will be strictly validated for format and length before lookup.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [uniqueIdentifiers.ts](file:///Users/micheal/sese_app/functions/src/uniqueIdentifiers.ts)
- Add caller authentication check at the start of `checkIdentifierAvailability`:
  `if (!request.auth) throw new HttpsError('unauthenticated', 'Authentication required to check identifier availability.');`.
- Implement `checkIdentifierRateLimit(uid: string)` to enforce sliding window rate limiting per UID.
- Enforce strict format/length validation for sensitive types (`nin`, `bvn`, `passport`, `drivers_license`).

#### [MODIFY] [unique_identifiers.test.ts](file:///Users/micheal/sese_app/functions/src/test/unique_identifiers.test.ts)
- Add unit tests for `checkIdentifierAvailability`:
  - Verify rejection of unauthenticated calls.
  - Verify per-UID rate limiting enforcement.
  - Verify sensitive credential format validation.

---

## Verification Plan

### Automated Tests
- Run `npm test` inside `/Users/micheal/sese_app/functions` to compile TypeScript and run unit test suites.

### Manual Verification
- Verify TypeScript compilation using `npm run build` in `/Users/micheal/sese_app/functions`.
