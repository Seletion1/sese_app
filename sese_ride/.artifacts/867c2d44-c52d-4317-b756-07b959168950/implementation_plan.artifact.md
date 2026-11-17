# Firebase Storage Security Rules Hardening (`storage.rules`)

Update `storage.rules` to resolve policy contradictions, narrow profile photo visibility, and enforce strict per-user write boundaries.

## User Review Required

> [!IMPORTANT]
> - **Audio MIME Type & Size Validation (`support_media`)**: Clarified documentation and sharpened `isAudio()` validation to strictly match permitted audio MIME types (`audio/(aac|mp3|mpeg|ogg|opus|wav|webm|m4a|x-m4a|amr|3gpp|mp4)`) capped at 5 MB for support voice notes.
> - **Narrow `profile_photos` Read Access**: Restricted read access on `profile_photos/{userId}` from universal authenticated access (`allow read: if request.auth != null;`) to the account owner or authorized hub staff (`allow read: if request.auth != null && (request.auth.uid == userId || isHubStaffClaim());`).
> - **Enforce Per-User Write Boundaries**: Removed staff write permission on `support_media/{userId}` folders. All user storage writes are now strictly owner-bound (`request.auth.uid == userId`), requiring support staff to upload response media under their own user path (`support_media/{staffUid}`).

## Proposed Changes

### Firebase Storage Security Rules (`storage.rules`)

#### [MODIFY] [storage.rules](file:///Users/micheal/sese_app/storage.rules)

1. **Audio Helper Sharpening**:
   - Update `isAudio()` helper to validate exact audio MIME types:
     `return request.resource.contentType.matches('audio/(aac|mp3|mpeg|ogg|opus|wav|webm|m4a|x-m4a|amr|3gpp|mp4)');`

2. **Profile Photos Read Restriction**:
   - Update `profile_photos/{userId}/{allPaths=**}` read rule:
     `allow read: if request.auth != null && (request.auth.uid == userId || isHubStaffClaim());`

3. **Per-User Support Media Write Boundary**:
   - Update `support_media/{userId}/{allPaths=**}` write rule:
     `allow write: if isSupportMediaOwner(userId) && ((isImage() && request.resource.size < 2 * 1024 * 1024) || (isAudio() && request.resource.size < 5 * 1024 * 1024));`
     where `isSupportMediaOwner(userId)` enforces `request.auth.uid == userId`.

---

## Verification Plan

### Automated Dry-Run Validation
- Run `firebase deploy --only storage:rules --dry-run` from `/Users/micheal/sese_app` to verify storage rules compilation.

### Full Pipeline Execution
- Execute backend unit test suite (`npm test`).
- Execute mandatory build, test, deploy, and git synchronization pipeline.
