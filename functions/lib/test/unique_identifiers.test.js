"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const admin = __importStar(require("firebase-admin"));
if (admin.apps.length === 0) {
    try {
        admin.initializeApp({ projectId: "sese-ride" });
    }
    catch (_) { }
}
const uniqueIdentifiers_1 = require("../uniqueIdentifiers");
(0, node_test_1.describe)("Unique Identifiers & Duplicate-Prevention Engine Tests", () => {
    (0, node_test_1.test)("1. Phone Number Normalization to E.164", () => {
        // Nigerian local 080... format
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "08012345678"), "+2348012345678");
        // Formatted with spaces and dashes
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "080-1234-5678"), "+2348012345678");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "+234 (801) 234-5678"), "+2348012345678");
        // Already in 234 format without +
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "2348012345678"), "+2348012345678");
        // International numbers
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "+1 (555) 019-2834"), "+15550192834");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "+44 20 7946 0912"), "+442079460912");
    });
    (0, node_test_1.test)("2. Email Normalization & Anti-Alias Protection", () => {
        // Gmail dots are stripped
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", "john.doe.smith@gmail.com"), "johndoesmith@gmail.com");
        // Gmail +aliases are stripped to prevent infinite duplicate accounts
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", "johndoe+ride1@gmail.com"), "johndoe@gmail.com");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", "John.Doe+promo99@googlemail.com"), "johndoe@gmail.com");
        // Non-Gmail domains preserve mailbox name, just lowercase and trimmed
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", " Support@SeseRide.com "), "support@seseride.com");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", "Admin.Staff@Yahoo.com"), "admin.staff@yahoo.com");
    });
    (0, node_test_1.test)("3. Government Issued IDs (NIN & BVN Normalization)", () => {
        // 11 digits NIN with spaces or hyphens stripped
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("nin", "123-456-789-01"), "12345678901");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("nin", " 98765432109 "), "98765432109");
        // 11 digits BVN with letters/symbols stripped
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("bvn", "BVN: 22334455667"), "22334455667");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("bvn", "223-344-556-67"), "22334455667");
    });
    (0, node_test_1.test)("4. Vehicle & Motorcycle License Plate Normalization", () => {
        // Uppercase, whitespace, and hyphens stripped
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("plate_number", "lag-123-aa"), "LAG123AA");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("plate_number", "KJA 456 XY"), "KJA456XY");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("plate_number", "  abj.789.zz  "), "ABJ789ZZ");
        // Motorcycle plates
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("plate_number", "MTR - 999 - AB"), "MTR999AB");
    });
    (0, node_test_1.test)("5. International Passport Normalization", () => {
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("passport", " a12345678 "), "A12345678");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("passport", "B-98765432"), "B98765432");
    });
    (0, node_test_1.test)("6. SHA-256 Hash Determinism & Collision Resistance", () => {
        const hash1 = (0, uniqueIdentifiers_1.hashIdentifier)("phone", "+2348012345678");
        const hash2 = (0, uniqueIdentifiers_1.hashIdentifier)("phone", "+2348012345678");
        node_assert_1.default.strictEqual(hash1, hash2);
        node_assert_1.default.strictEqual(hash1.length, 64); // Valid SHA-256 hex string
        // Cross-type separation: same numeric sequence in different types yields distinct hashes
        const phoneHash = (0, uniqueIdentifiers_1.hashIdentifier)("phone", "12345678901");
        const ninHash = (0, uniqueIdentifiers_1.hashIdentifier)("nin", "12345678901");
        const bvnHash = (0, uniqueIdentifiers_1.hashIdentifier)("bvn", "12345678901");
        node_assert_1.default.notStrictEqual(phoneHash, ninHash);
        node_assert_1.default.notStrictEqual(ninHash, bvnHash);
    });
    (0, node_test_1.test)("7. Masking for Privacy & User Experience", () => {
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.maskIdentifier)("phone", "+2348012345678"), "+234••••••78");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.maskIdentifier)("email", "michael@gmail.com"), "m••••@gmail.com");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.maskIdentifier)("nin", "12345678901"), "•••••••8901");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.maskIdentifier)("bvn", "22334455667"), "•••••••5667");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.maskIdentifier)("plate_number", "LAG123AA"), "LAG•••AA");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.maskIdentifier)("passport", "A12345678"), "A1••••78");
    });
    (0, node_test_1.test)("8. Conflict Error Messages (Generic & Secure)", () => {
        const phoneErr = (0, uniqueIdentifiers_1.getConflictErrorMessage)("phone", "+234••••••78");
        node_assert_1.default.strictEqual(phoneErr, "Please check your details and try again.");
        const emailErr = (0, uniqueIdentifiers_1.getConflictErrorMessage)("email", "m••••@gmail.com");
        node_assert_1.default.strictEqual(emailErr, "Please check your details and try again.");
        const plateErr = (0, uniqueIdentifiers_1.getConflictErrorMessage)("plate_number", "LAG•••AA");
        node_assert_1.default.strictEqual(plateErr, "Please check your details and try again.");
        const ninErr = (0, uniqueIdentifiers_1.getConflictErrorMessage)("nin", "•••••••8901");
        node_assert_1.default.strictEqual(ninErr, "Please check your details and try again.");
    });
    (0, node_test_1.test)("9. Identifier Preparation & Deduplication", () => {
        const prepared = (0, uniqueIdentifiers_1.prepareIdentifiers)([
            { type: "phone", value: "08012345678" },
            { type: "phone", value: "+234 801 234 5678" }, // duplicate normalized
            { type: "email", value: "test@gmail.com" },
            { type: "plate_number", value: "lag-123-aa", entityId: "v_123" },
            { type: "nin", value: "" }, // empty value skipped
        ]);
        node_assert_1.default.strictEqual(prepared.length, 3);
        node_assert_1.default.strictEqual(prepared[0].type, "phone");
        node_assert_1.default.strictEqual(prepared[0].normalized, "+2348012345678");
        node_assert_1.default.strictEqual(prepared[1].type, "email");
        node_assert_1.default.strictEqual(prepared[2].type, "plate_number");
        node_assert_1.default.strictEqual(prepared[2].entityId, "v_123");
    });
});
//# sourceMappingURL=unique_identifiers.test.js.map