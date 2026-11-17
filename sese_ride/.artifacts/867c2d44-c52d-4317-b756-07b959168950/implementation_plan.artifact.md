# Distributed Rate Limiting & Cloud Billing Budget Control for `googleMapsProxy`

Upgrade `googleMapsProxy` rate-limiting to a distributed Firestore sliding window rate-limiter and set up Pub/Sub Cloud Billing budget notification handling for automated circuit-breaking and cost control.

## User Review Required

> [!IMPORTANT]
> - **Distributed Firestore Sliding Window Rate Limiter**: Replace per-instance in-memory map in `googleMaps.ts` with an async distributed Firestore transaction on `rate_limits/maps_proxy_{uid}`. Globally synchronizes the `60 req/min/uid` ceiling across all horizontal Cloud Run instances, with an in-memory fallback for unit tests and offline environments.
> - **Cloud Billing Budget Pub/Sub Handler**: Implement `handleBillingBudgetAlert` (`onMessagePublished` on Pub/Sub topic `billing-budget-alerts`) to parse GCP Billing notifications. At 100% budget threshold, automatically engages global emergency circuit-breaking on Google Maps API calls to protect against cost spikes.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [googleMaps.ts](file:///Users/micheal/sese_app/functions/src/googleMaps.ts#L180-L215)
- Refactor `checkProxyRateLimit(uid)` into an `async` function using Firestore transactions on `rate_limits/maps_proxy_${uid}` for global instance synchronization.

#### [NEW] [billingAlert.ts](file:///Users/micheal/sese_app/functions/src/billingAlert.ts)
- Implement `handleBillingBudgetAlert` listening on Pub/Sub topic `billing-budget-alerts`. Parses GCP budget notifications (50%, 80%, 100%), logs severity alerts, and triggers emergency circuit-breaking at 100% budget.

#### [MODIFY] [index.ts](file:///Users/micheal/sese_app/functions/src/index.ts)
- Export `handleBillingBudgetAlert` from `./billingAlert`.

#### [MODIFY] [security_fixes.test.ts](file:///Users/micheal/sese_app/functions/src/test/security_fixes.test.ts#L5-L25)
- Update rate limiting unit test to handle `async checkProxyRateLimit(uid)`.

---

## Verification Plan

### Automated Build & Test Execution
- Run `npm run build` in `functions/` to compile TypeScript and generate `functions.yaml` manifest.
- Run `npm test` in `functions/` to verify all unit test suites pass cleanly.

### Mandatory Pipeline Execution
- Run `flutter analyze` in `sese_ride`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: implement distributed rate-limiting and cloud billing budget handler`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
