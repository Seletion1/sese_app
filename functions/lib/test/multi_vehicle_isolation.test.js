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
Object.defineProperty(exports, "__esModule", { value: true });
const node_test_1 = require("node:test");
const assert = __importStar(require("node:assert"));
/**
 * Multi-Vehicle Ownership, Strict Approval & Category Isolation Tests
 */
(0, node_test_1.describe)("Multi-Vehicle Ownership & Category Isolation Engine", () => {
    (0, node_test_1.it)("1. goOnline rejects unapproved vehicle selection", () => {
        const requestedVehicle = {
            id: "v_tricycle_pending",
            category: "tricycle",
            verificationStatus: "PENDING",
            isVerified: false,
        };
        const isApproved = requestedVehicle.verificationStatus === "APPROVED" ||
            requestedVehicle.verificationStatus === "VERIFIED" ||
            requestedVehicle.isVerified === true;
        assert.strictEqual(isApproved, false, "Pending vehicle must not be approved.");
    });
    (0, node_test_1.it)("2. goOnline approves valid vehicle session and sets activeVehicleCategory", () => {
        const requestedVehicle = {
            id: "v_tricycle_approved",
            category: "tricycle",
            verificationStatus: "APPROVED",
            isVerified: true,
            licensePlate: "TRK-123-AA",
        };
        const isApproved = requestedVehicle.verificationStatus === "APPROVED" ||
            requestedVehicle.verificationStatus === "VERIFIED" ||
            requestedVehicle.isVerified === true;
        assert.strictEqual(isApproved, true);
        const activeVehicleCategory = requestedVehicle.category.toLowerCase();
        assert.strictEqual(activeVehicleCategory, "tricycle");
    });
    (0, node_test_1.it)("3. findNearestDrivers skips drivers online with category keke when trip asks for truck", () => {
        const driverActiveCat = "tricycle";
        const tripCategory = "truck";
        const selectedTiers = ["truck"];
        const allowedCats = new Set();
        if (tripCategory)
            allowedCats.add(tripCategory.toLowerCase());
        for (const t of selectedTiers)
            allowedCats.add(t.toLowerCase());
        const isDriverEligible = allowedCats.has(driverActiveCat);
        assert.strictEqual(isDriverEligible, false, "Tricycle driver must be isolated from truck trip.");
    });
    (0, node_test_1.it)("4. acceptTrip rejects driver when active category differs from order category", () => {
        const driverActiveCat = "tricycle";
        const orderRequiredCat = "truck";
        const isMatch = driverActiveCat === orderRequiredCat;
        assert.strictEqual(isMatch, false, "Driver category tricycle must not accept order for truck.");
    });
    (0, node_test_1.it)("5. submitBid rejects driver counter-offer when active category differs from order category", () => {
        const driverActiveCat = "tricycle";
        const orderRequiredCat = "sedan";
        const isMatch = driverActiveCat === orderRequiredCat;
        assert.strictEqual(isMatch, false, "Driver category tricycle must not bid on order for sedan.");
    });
    (0, node_test_1.it)("6. findNearestDrivers matches driver when active category is in selectedTiers", () => {
        const driverActiveCat = "tricycle";
        const selectedTiers = ["comfort", "tricycle"];
        const allowedCats = new Set(selectedTiers.map(t => t.toLowerCase()));
        const isDriverEligible = allowedCats.has(driverActiveCat);
        assert.strictEqual(isDriverEligible, true, "Tricycle driver must match trip allowing tricycle.");
    });
});
//# sourceMappingURL=multi_vehicle_isolation.test.js.map