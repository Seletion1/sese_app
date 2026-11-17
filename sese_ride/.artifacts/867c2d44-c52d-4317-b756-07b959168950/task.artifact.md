# Implementation Task Checklist - Distributed Rate Limiting & Billing Budget Control

- [/] Implement distributed Firestore sliding window rate limiter in `functions/src/googleMaps.ts`
- [/] Create `functions/src/billingAlert.ts` for Pub/Sub billing notifications and emergency circuit-breaking
- [/] Export `handleBillingBudgetAlert` in `functions/src/index.ts`
- [/] Update rate-limiting unit test in `functions/src/test/security_fixes.test.ts`
- [ ] Run backend build & unit tests (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
