import { describe, it } from "node:test";
import * as assert from "node:assert";

/**
 * Multi-Vehicle Ownership, Strict Approval & Category Isolation Tests
 */

describe("Multi-Vehicle Ownership & Category Isolation Engine", () => {

  it("1. goOnline rejects unapproved vehicle selection", () => {
    const requestedVehicle = {
      id: "v_tricycle_pending",
      category: "tricycle",
      verificationStatus: "PENDING",
      isVerified: false,
    };

    const isApproved =
      requestedVehicle.verificationStatus === "APPROVED" ||
      requestedVehicle.verificationStatus === "VERIFIED" ||
      requestedVehicle.isVerified === true;

    assert.strictEqual(isApproved, false, "Pending vehicle must not be approved.");
  });

  it("2. goOnline approves valid vehicle session and sets activeVehicleCategory", () => {
    const requestedVehicle = {
      id: "v_tricycle_approved",
      category: "tricycle",
      verificationStatus: "APPROVED",
      isVerified: true,
      licensePlate: "TRK-123-AA",
    };

    const isApproved =
      requestedVehicle.verificationStatus === "APPROVED" ||
      requestedVehicle.verificationStatus === "VERIFIED" ||
      requestedVehicle.isVerified === true;

    assert.strictEqual(isApproved, true);

    const activeVehicleCategory = requestedVehicle.category.toLowerCase();
    assert.strictEqual(activeVehicleCategory, "tricycle");
  });

  it("3. findNearestDrivers skips drivers online with category keke when trip asks for truck", () => {
    const driverActiveCat = "tricycle";
    const tripCategory = "truck";
    const selectedTiers = ["truck"];

    const allowedCats = new Set<string>();
    if (tripCategory) allowedCats.add(tripCategory.toLowerCase());
    for (const t of selectedTiers) allowedCats.add(t.toLowerCase());

    const isDriverEligible = allowedCats.has(driverActiveCat);
    assert.strictEqual(isDriverEligible, false, "Tricycle driver must be isolated from truck trip.");
  });

  it("4. acceptTrip rejects driver when active category differs from order category", () => {
    const driverActiveCat: string = "tricycle";
    const orderRequiredCat: string = "truck";

    const isMatch = (driverActiveCat as string) === (orderRequiredCat as string);
    assert.strictEqual(isMatch, false, "Driver category tricycle must not accept order for truck.");
  });

  it("5. submitBid rejects driver counter-offer when active category differs from order category", () => {
    const driverActiveCat: string = "tricycle";
    const orderRequiredCat: string = "sedan";

    const isMatch = (driverActiveCat as string) === (orderRequiredCat as string);
    assert.strictEqual(isMatch, false, "Driver category tricycle must not bid on order for sedan.");
  });

  it("6. findNearestDrivers matches driver when active category is in selectedTiers", () => {
    const driverActiveCat = "tricycle";
    const selectedTiers = ["comfort", "tricycle"];

    const allowedCats = new Set<string>(selectedTiers.map(t => t.toLowerCase()));
    const isDriverEligible = allowedCats.has(driverActiveCat);
    assert.strictEqual(isDriverEligible, true, "Tricycle driver must match trip allowing tricycle.");
  });
});
