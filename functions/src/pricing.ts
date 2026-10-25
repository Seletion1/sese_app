import * as admin from "firebase-admin";

export interface VehicleRate {
  baseFee: number;
  distanceRatePerKm: number;
  timeRatePerMinute: number;
  surgeMultiplier: number;
}

export interface ComputedTier {
  tierId: string;
  name: string;
  isRecommended: boolean;
  fareFormatted: string;
  fareAmount: number;
}

const DEFAULT_RATES: Record<string, VehicleRate> = {
  bicycle: { baseFee: 300, distanceRatePerKm: 80, timeRatePerMinute: 10, surgeMultiplier: 1.0 },
  motorcycle: { baseFee: 400, distanceRatePerKm: 120, timeRatePerMinute: 15, surgeMultiplier: 1.0 },
  tricycle: { baseFee: 450, distanceRatePerKm: 130, timeRatePerMinute: 18, surgeMultiplier: 1.0 },
  car: { baseFee: 600, distanceRatePerKm: 180, timeRatePerMinute: 25, surgeMultiplier: 1.0 },
  van: { baseFee: 1200, distanceRatePerKm: 300, timeRatePerMinute: 40, surgeMultiplier: 1.0 },
  truck: { baseFee: 2500, distanceRatePerKm: 500, timeRatePerMinute: 60, surgeMultiplier: 1.0 },
};

interface CarTierDynamic {
  comfortMultiplier: number;
  premiumMultiplier: number;
  luxeMultiplier: number;
  comfortLabel: string;
  premiumLabel: string;
  luxeLabel: string;
}

const DEFAULT_CAR_TIERS: CarTierDynamic = {
  comfortMultiplier: 1.0,
  premiumMultiplier: 1.35,
  luxeMultiplier: 1.75,
  comfortLabel: "Standard / Comfort",
  premiumLabel: "Executive / Premium",
  luxeLabel: "Luxe / Super",
};

const DELIVERY_TIER_NAMES: Record<string, string> = {
  motorcycle: "Motorcycle",
  tricycle: "Tricycle (Keke)",
  bicycle: "Bicycle",
  van: "Van",
  truck: "Truck",
  car: "Car / Sedan",
};

/**
 * Rounds a fare amount to the nearest 100.
 *
 * Rule:
 * - If the remainder (amount % 100) is 50 or higher, it rounds UP to the nearest 100.
 * - If the remainder is less than 50, it rounds DOWN to the nearest 100.
 *
 * Examples:
 * - 3,612 -> 3,600 (remainder 12 < 50)
 * - 2,576 -> 2,600 (remainder 76 >= 50)
 * - 3,650 -> 3,700 (remainder 50 >= 50)
 */
export function roundToNearest100(amount: number, minFloor = 0): number {
  if (amount <= 0) return 0;
  const intAmount = Math.round(amount);
  const remainder = intAmount % 100;
  let rounded: number;
  if (remainder >= 50) {
    rounded = intAmount - remainder + 100;
  } else {
    rounded = intAmount - remainder;
  }
  const floorInt = Math.round(minFloor);
  if (floorInt > 0 && rounded < floorInt) {
    const floorRemainder = floorInt % 100;
    rounded = floorRemainder === 0
      ? floorInt
      : (floorInt - floorRemainder + (floorRemainder >= 50 ? 100 : 0));
  }
  return rounded;
}

export function formatCurrency(amount: number, symbol = "₦"): string {
  if (amount % 1 === 0) {
    const whole = amount.toLocaleString("en-US");
    return `${symbol}${whole}`;
  }
  const parts = amount.toFixed(2).split(".");
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${symbol}${parts.join(".")}`;
}

/**
 * Resolves effective regional configuration via fallback chain:
 * Global Default -> Country-Specific Rule -> State-Specific Override.
 * Reads from `system_configs/{configId}` (aligned with sese_hub SystemConfigService).
 */
async function resolveRegionConfig(params: {
  countryCode?: string;
  stateOrRegion?: string;
}): Promise<{
  rates: Record<string, VehicleRate>;
  carTiers: CarTierDynamic;
  regionalSurge: number;
  currencySymbol: string;
}> {
  let rates: Record<string, VehicleRate> = { ...DEFAULT_RATES };
  let carTiers: CarTierDynamic = { ...DEFAULT_CAR_TIERS };
  let regionalSurge = 1.0;
  let currencySymbol = "₦";

  try {
    const firestore = admin.firestore();
    // Fetch all system_configs — fallback chain needs at most 3 docs.
    // Using individual gets for efficiency when country/state are known.
    const countryCode = (params.countryCode ?? "").trim().toUpperCase();
    const stateOrRegion = (params.stateOrRegion ?? "").trim();

    const docIds: string[] = ["global_default"];
    if (countryCode) docIds.push(`country_${countryCode}`);
    if (countryCode && stateOrRegion) {
      const statePart = stateOrRegion.toUpperCase().replace(/\s+/g, "_");
      docIds.push(`state_${countryCode}_${statePart}`);
    }

    // Fetch in order so later docs override earlier ones.
    for (const docId of docIds) {
      try {
        const snap = await firestore.collection("system_configs").doc(docId).get();
        if (!snap.exists) continue;
        const data = snap.data() as Record<string, unknown>;
        if (!data) continue;

        if (typeof data.currencySymbol === "string" && data.currencySymbol) {
          currencySymbol = data.currencySymbol as string;
        }
        if (typeof data.regionalSurgeMultiplier === "number") {
          regionalSurge = Number(data.regionalSurgeMultiplier) || regionalSurge;
        } else if (typeof data.regionalSurgeMultiplier === "string") {
          const v = Number(data.regionalSurgeMultiplier);
          if (!isNaN(v) && v > 0) regionalSurge = v;
        }

        // Merge pricingRates per vehicle category (child overrides parent per-category)
        if (data.pricingRates && typeof data.pricingRates === "object") {
          const rawRates = data.pricingRates as Record<string, unknown>;
          for (const [key, val] of Object.entries(rawRates)) {
            if (val && typeof val === "object") {
              const r = val as Record<string, unknown>;
              const normKey = key.toLowerCase();
              rates[normKey] = {
                baseFee: Number(r.baseFee ?? rates[normKey]?.baseFee ?? 500),
                distanceRatePerKm: Number(r.distanceRatePerKm ?? rates[normKey]?.distanceRatePerKm ?? 150),
                timeRatePerMinute: Number(r.timeRatePerMinute ?? rates[normKey]?.timeRatePerMinute ?? 20),
                surgeMultiplier: Number(r.surgeMultiplier ?? rates[normKey]?.surgeMultiplier ?? 1.0),
              };
            }
          }
        }

        // Merge car tier thresholds — child overrides only explicitly set fields
        if (data.carTierThresholds && typeof data.carTierThresholds === "object") {
          const ct = data.carTierThresholds as Record<string, unknown>;
          if (typeof ct.comfortMultiplier === "number") carTiers.comfortMultiplier = Number(ct.comfortMultiplier);
          if (typeof ct.premiumMultiplier === "number") carTiers.premiumMultiplier = Number(ct.premiumMultiplier);
          if (typeof ct.luxeMultiplier === "number") carTiers.luxeMultiplier = Number(ct.luxeMultiplier);
          if (typeof ct.comfortLabel === "string" && ct.comfortLabel) carTiers.comfortLabel = ct.comfortLabel as string;
          if (typeof ct.premiumLabel === "string" && ct.premiumLabel) carTiers.premiumLabel = ct.premiumLabel as string;
          if (typeof ct.luxeLabel === "string" && ct.luxeLabel) carTiers.luxeLabel = ct.luxeLabel as string;
        }
      } catch {
        // Individual doc fetch failed — continue with already-resolved config
      }
    }
  } catch {
    // Firestore unreachable — fallback to in-memory defaults
  }

  return { rates, carTiers, regionalSurge, currencySymbol };
}

function carTierConfigForTierId(
  tierId: string,
  carTiers: CarTierDynamic
): { name: string; multiplier: number; canonicalId: string } {
  const norm = tierId.toLowerCase();
  if (["comfort", "car_standard", "standard"].includes(norm)) {
    return { name: carTiers.comfortLabel, multiplier: carTiers.comfortMultiplier, canonicalId: "comfort" };
  }
  if (["premium", "car_executive", "executive"].includes(norm)) {
    return { name: carTiers.premiumLabel, multiplier: carTiers.premiumMultiplier, canonicalId: "premium" };
  }
  if (["luxe", "car_luxe"].includes(norm)) {
    return { name: carTiers.luxeLabel, multiplier: carTiers.luxeMultiplier, canonicalId: "luxe" };
  }
  return { name: norm, multiplier: 1.0, canonicalId: norm };
}

export async function computeFares(params: {
  serviceType: "ride" | "send_item" | "receive_item";
  selectedTiers?: string[];
  distanceKm: number;
  durationMins: number;
  countryCode?: string;
  stateOrRegion?: string;
}): Promise<ComputedTier[]> {
  const { serviceType, selectedTiers, distanceKm, durationMins } = params;

  const { rates: dbRates, carTiers, regionalSurge, currencySymbol } =
    await resolveRegionConfig({
      countryCode: params.countryCode,
      stateOrRegion: params.stateOrRegion,
    });

  const results: ComputedTier[] = [];

  if (serviceType === "ride") {
    const carRate = dbRates.car ?? DEFAULT_RATES.car;
    const tiersToCalc = (selectedTiers && selectedTiers.length > 0)
      ? selectedTiers
      : ["comfort", "premium", "luxe"];

    for (const rawTierId of tiersToCalc) {
      const tierConf = carTierConfigForTierId(rawTierId, carTiers);
      const surge = (carRate.surgeMultiplier || 1.0) * regionalSurge;
      const distanceFare = distanceKm * carRate.distanceRatePerKm;
      const timeFare = durationMins * carRate.timeRatePerMinute;
      // Aligned with PricingCalculator: tier multiplier applies to variable fare only,
      // baseFee remains the floor for any trip.
      const variableFare = (distanceFare + timeFare) * surge * tierConf.multiplier;
      const rawTotal = carRate.baseFee + variableFare;
      const totalFare = roundToNearest100(rawTotal, carRate.baseFee);

      results.push({
        tierId: rawTierId,
        name: tierConf.name,
        isRecommended: tierConf.canonicalId === "comfort",
        fareFormatted: formatCurrency(totalFare, currencySymbol),
        fareAmount: totalFare,
      });
    }
  } else {
    // Delivery: send_item or receive_item - all 6 delivery categories (incl. Car / Sedan) per Fleet Scope Matrix
    const tiersToCalc = (selectedTiers && selectedTiers.length > 0)
      ? selectedTiers
      : ["bicycle", "motorcycle", "tricycle", "car", "van", "truck"];

    for (const rawCat of tiersToCalc) {
      const norm = rawCat.toLowerCase();
      const rate = dbRates[norm] ?? DEFAULT_RATES[norm] ?? DEFAULT_RATES.motorcycle;
      const surge = (rate.surgeMultiplier || 1.0) * regionalSurge;
      const distanceFare = distanceKm * rate.distanceRatePerKm;
      const timeFare = durationMins * rate.timeRatePerMinute;
      const variableFare = (distanceFare + timeFare) * surge;
      const rawTotal = rate.baseFee + variableFare;
      const totalFare = roundToNearest100(rawTotal, rate.baseFee);

      results.push({
        tierId: rawCat,
        name: DELIVERY_TIER_NAMES[norm] ?? norm,
        isRecommended: norm === "motorcycle",
        fareFormatted: formatCurrency(totalFare, currencySymbol),
        fareAmount: totalFare,
      });
    }
  }

  return results;
}
