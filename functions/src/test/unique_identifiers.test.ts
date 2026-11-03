import assert from "node:assert";
import { test, describe } from "node:test";
import * as admin from "firebase-admin";

if (admin.apps.length === 0) {
  try {
    admin.initializeApp({ projectId: "sese-ride" });
  } catch (_) {}
}

import {
  normalizeIdentifier,
  hashIdentifier,
  maskIdentifier,
  getConflictErrorMessage,
  prepareIdentifiers,
} from "../uniqueIdentifiers";

describe("Unique Identifiers & Duplicate-Prevention Engine Tests", () => {
  test("1. Phone Number Normalization to E.164", () => {
    // Nigerian local 080... format
    assert.strictEqual(normalizeIdentifier("phone", "08012345678"), "+2348012345678");
    // Formatted with spaces and dashes
    assert.strictEqual(normalizeIdentifier("phone", "080-1234-5678"), "+2348012345678");
    assert.strictEqual(normalizeIdentifier("phone", "+234 (801) 234-5678"), "+2348012345678");
    // Already in 234 format without +
    assert.strictEqual(normalizeIdentifier("phone", "2348012345678"), "+2348012345678");
    // International numbers
    assert.strictEqual(normalizeIdentifier("phone", "+1 (555) 019-2834"), "+15550192834");
    assert.strictEqual(normalizeIdentifier("phone", "+44 20 7946 0912"), "+442079460912");
  });

  test("2. Email Normalization & Anti-Alias Protection", () => {
    // Gmail dots are stripped
    assert.strictEqual(
      normalizeIdentifier("email", "john.doe.smith@gmail.com"),
      "johndoesmith@gmail.com"
    );
    // Gmail +aliases are stripped to prevent infinite duplicate accounts
    assert.strictEqual(
      normalizeIdentifier("email", "johndoe+ride1@gmail.com"),
      "johndoe@gmail.com"
    );
    assert.strictEqual(
      normalizeIdentifier("email", "John.Doe+promo99@googlemail.com"),
      "johndoe@gmail.com"
    );
    // Non-Gmail domains preserve mailbox name, just lowercase and trimmed
    assert.strictEqual(
      normalizeIdentifier("email", " Support@SeseRide.com "),
      "support@seseride.com"
    );
    assert.strictEqual(
      normalizeIdentifier("email", "Admin.Staff@Yahoo.com"),
      "admin.staff@yahoo.com"
    );
  });

  test("3. Government Issued IDs (NIN & BVN Normalization)", () => {
    // 11 digits NIN with spaces or hyphens stripped
    assert.strictEqual(normalizeIdentifier("nin", "123-456-789-01"), "12345678901");
    assert.strictEqual(normalizeIdentifier("nin", " 98765432109 "), "98765432109");

    // 11 digits BVN with letters/symbols stripped
    assert.strictEqual(normalizeIdentifier("bvn", "BVN: 22334455667"), "22334455667");
    assert.strictEqual(normalizeIdentifier("bvn", "223-344-556-67"), "22334455667");
  });

  test("4. Vehicle & Motorcycle License Plate Normalization", () => {
    // Uppercase, whitespace, and hyphens stripped
    assert.strictEqual(normalizeIdentifier("plate_number", "lag-123-aa"), "LAG123AA");
    assert.strictEqual(normalizeIdentifier("plate_number", "KJA 456 XY"), "KJA456XY");
    assert.strictEqual(normalizeIdentifier("plate_number", "  abj.789.zz  "), "ABJ789ZZ");
    // Motorcycle plates
    assert.strictEqual(normalizeIdentifier("plate_number", "MTR - 999 - AB"), "MTR999AB");
  });

  test("5. International Passport Normalization", () => {
    assert.strictEqual(normalizeIdentifier("passport", " a12345678 "), "A12345678");
    assert.strictEqual(normalizeIdentifier("passport", "B-98765432"), "B98765432");
  });

  test("6. SHA-256 Hash Determinism & Collision Resistance", () => {
    const hash1 = hashIdentifier("phone", "+2348012345678");
    const hash2 = hashIdentifier("phone", "+2348012345678");
    assert.strictEqual(hash1, hash2);
    assert.strictEqual(hash1.length, 64); // Valid SHA-256 hex string

    // Cross-type separation: same numeric sequence in different types yields distinct hashes
    const phoneHash = hashIdentifier("phone", "12345678901");
    const ninHash = hashIdentifier("nin", "12345678901");
    const bvnHash = hashIdentifier("bvn", "12345678901");
    assert.notStrictEqual(phoneHash, ninHash);
    assert.notStrictEqual(ninHash, bvnHash);
  });

  test("7. Masking for Privacy & User Experience", () => {
    assert.strictEqual(maskIdentifier("phone", "+2348012345678"), "+234••••••78");
    assert.strictEqual(maskIdentifier("email", "michael@gmail.com"), "m••••@gmail.com");
    assert.strictEqual(maskIdentifier("nin", "12345678901"), "•••••••8901");
    assert.strictEqual(maskIdentifier("bvn", "22334455667"), "•••••••5667");
    assert.strictEqual(maskIdentifier("plate_number", "LAG123AA"), "LAG•••AA");
    assert.strictEqual(maskIdentifier("passport", "A12345678"), "A1••••78");
  });

  test("8. Conflict Error Messages", () => {
    const phoneErr = getConflictErrorMessage("phone", "+234••••••78");
    assert.match(phoneErr, /phone number/i);
    assert.match(phoneErr, /already registered/i);

    const emailErr = getConflictErrorMessage("email", "m••••@gmail.com");
    assert.match(emailErr, /email address/i);
    assert.match(emailErr, /already associated/i);

    const plateErr = getConflictErrorMessage("plate_number", "LAG•••AA");
    assert.match(plateErr, /plate number/i);
    assert.match(plateErr, /already registered/i);

    const ninErr = getConflictErrorMessage("nin", "•••••••8901");
    assert.match(ninErr, /National Identity Number/i);
  });

  test("9. Identifier Preparation & Deduplication", () => {
    const prepared = prepareIdentifiers([
      { type: "phone", value: "08012345678" },
      { type: "phone", value: "+234 801 234 5678" }, // duplicate normalized
      { type: "email", value: "test@gmail.com" },
      { type: "plate_number", value: "lag-123-aa", entityId: "v_123" },
      { type: "nin", value: "" }, // empty value skipped
    ]);

    assert.strictEqual(prepared.length, 3);
    assert.strictEqual(prepared[0].type, "phone");
    assert.strictEqual(prepared[0].normalized, "+2348012345678");
    assert.strictEqual(prepared[1].type, "email");
    assert.strictEqual(prepared[2].type, "plate_number");
    assert.strictEqual(prepared[2].entityId, "v_123");
  });
});
