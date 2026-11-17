# Token Freshness (`auth_time`) Validation in `resetTransactionPin`

Enforce zero-trust re-authentication token freshness validation inside `resetTransactionPin` in `functions/src/transactionPin.ts`.

## User Review Required

> [!IMPORTANT]
> - **Re-Authentication Freshness Gate**: Replicate the exact pattern from `deleteAccount.ts` inside `resetTransactionPin`.
> - **Validation Rule**:
>   - Extract `authTimeSec = Number(request.auth.token.auth_time ?? 0)`.
>   - Calculate `ageSec = Date.now() / 1000 - authTimeSec`.
>   - If `!Number.isFinite(ageSec) || ageSec < 0 || ageSec > 10 * 60` (older than 10 minutes / 600 seconds), throw `HttpsError('unauthenticated', 'Recent re-authentication is required to reset your transaction PIN.')`.
> - **Unit Tests**: Update `transactionPin.test.ts` to include fresh `auth_time` on test requests and add a dedicated test verifying rejection of stale session tokens.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [transactionPin.ts](file:///Users/micheal/sese_app/functions/src/transactionPin.ts#L290-L330)
- Add `auth_time` freshness check to `resetTransactionPin`.

#### [MODIFY] [transactionPin.test.ts](file:///Users/micheal/sese_app/functions/src/test/transactionPin.test.ts#L180-L200)
- Update mock request in `resetTransactionPin` unit test to include `auth.token.auth_time = Math.floor(Date.now() / 1000)`.
- Add test verifying stale `auth_time` rejection.

---

## Verification Plan

### Automated Test Execution
- Run `npm test` inside `/Users/micheal/sese_app/functions` to verify that all unit tests pass.

### Mandatory Pipeline Execution
- Run `flutter test` (if applicable) and `flutter analyze` in `sese_ride`.
- Run `npm run build` in `functions/`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `perf: eliminate blocking loaders, implement local-first caching, optimistic UI, and background pre-fetching`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
