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
exports.roundToNearest100 = roundToNearest100;
exports.formatCurrency = formatCurrency;
exports.computeFares = computeFares;
const admin = __importStar(require("firebase-admin"));
const DEFAULT_RATES = {
    bicycle: { baseFee: 300, distanceRatePerKm: 80, timeRatePerMinute: 10, surgeMultiplier: 1.0 },
    motorcycle: { baseFee: 400, distanceRatePerKm: 120, timeRatePerMinute: 15, surgeMultiplier: 1.0 },
    tricycle: { baseFee: 450, distanceRatePerKm: 130, timeRatePerMinute: 18, surgeMultiplier: 1.0 },
    car: { baseFee: 600, distanceRatePerKm: 180, timeRatePerMinute: 25, surgeMultiplier: 1.0 },
    van: { baseFee: 1200, distanceRatePerKm: 300, timeRatePerMinute: 40, surgeMultiplier: 1.0 },
    truck: { baseFee: 2500, distanceRatePerKm: 500, timeRatePerMinute: 60, surgeMultiplier: 1.0 },
};
const DEFAULT_CAR_TIERS = {
    comfortMultiplier: 1.0,
    premiumMultiplier: 1.35,
    luxeMultiplier: 1.75,
    comfortLabel: "Standard / Comfort",
    premiumLabel: "Executive / Premium",
    luxeLabel: "Luxe / Super",
};
const DELIVERY_TIER_NAMES = {
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
function roundToNearest100(amount, minFloor = 0) {
    if (amount <= 0)
        return 0;
    const intAmount = Math.round(amount);
    const remainder = intAmount % 100;
    let rounded;
    if (remainder >= 50) {
        rounded = intAmount - remainder + 100;
    }
    else {
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
function formatCurrency(amount, symbol = "₦") {
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
async function resolveRegionConfig(params) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p;
    let rates = Object.assign({}, DEFAULT_RATES);
    let carTiers = Object.assign({}, DEFAULT_CAR_TIERS);
    let regionalSurge = 1.0;
    let currencySymbol = "₦";
    try {
        const firestore = admin.firestore();
        // Fetch all system_configs — fallback chain needs at most 3 docs.
        // Using individual gets for efficiency when country/state are known.
        const countryCode = ((_a = params.countryCode) !== null && _a !== void 0 ? _a : "").trim().toUpperCase();
        const stateOrRegion = ((_b = params.stateOrRegion) !== null && _b !== void 0 ? _b : "").trim();
        const docIds = ["global_default"];
        if (countryCode)
            docIds.push(`country_${countryCode}`);
        if (countryCode && stateOrRegion) {
            const statePart = stateOrRegion.toUpperCase().replace(/\s+/g, "_");
            docIds.push(`state_${countryCode}_${statePart}`);
        }
        // Fetch in order so later docs override earlier ones.
        for (const docId of docIds) {
            try {
                const snap = await firestore.collection("system_configs").doc(docId).get();
                if (!snap.exists)
                    continue;
                const data = snap.data();
                if (!data)
                    continue;
                if (typeof data.currencySymbol === "string" && data.currencySymbol) {
                    currencySymbol = data.currencySymbol;
                }
                if (typeof data.regionalSurgeMultiplier === "number") {
                    regionalSurge = Number(data.regionalSurgeMultiplier) || regionalSurge;
                }
                else if (typeof data.regionalSurgeMultiplier === "string") {
                    const v = Number(data.regionalSurgeMultiplier);
                    if (!isNaN(v) && v > 0)
                        regionalSurge = v;
                }
                // Merge pricingRates per vehicle category (child overrides parent per-category)
                if (data.pricingRates && typeof data.pricingRates === "object") {
                    const rawRates = data.pricingRates;
                    for (const [key, val] of Object.entries(rawRates)) {
                        if (val && typeof val === "object") {
                            const r = val;
                            const normKey = key.toLowerCase();
                            rates[normKey] = {
                                baseFee: Number((_e = (_c = r.baseFee) !== null && _c !== void 0 ? _c : (_d = rates[normKey]) === null || _d === void 0 ? void 0 : _d.baseFee) !== null && _e !== void 0 ? _e : 500),
                                distanceRatePerKm: Number((_h = (_f = r.distanceRatePerKm) !== null && _f !== void 0 ? _f : (_g = rates[normKey]) === null || _g === void 0 ? void 0 : _g.distanceRatePerKm) !== null && _h !== void 0 ? _h : 150),
                                timeRatePerMinute: Number((_l = (_j = r.timeRatePerMinute) !== null && _j !== void 0 ? _j : (_k = rates[normKey]) === null || _k === void 0 ? void 0 : _k.timeRatePerMinute) !== null && _l !== void 0 ? _l : 20),
                                surgeMultiplier: Number((_p = (_m = r.surgeMultiplier) !== null && _m !== void 0 ? _m : (_o = rates[normKey]) === null || _o === void 0 ? void 0 : _o.surgeMultiplier) !== null && _p !== void 0 ? _p : 1.0),
                            };
                        }
                    }
                }
                // Merge car tier thresholds — child overrides only explicitly set fields
                if (data.carTierThresholds && typeof data.carTierThresholds === "object") {
                    const ct = data.carTierThresholds;
                    if (typeof ct.comfortMultiplier === "number")
                        carTiers.comfortMultiplier = Number(ct.comfortMultiplier);
                    if (typeof ct.premiumMultiplier === "number")
                        carTiers.premiumMultiplier = Number(ct.premiumMultiplier);
                    if (typeof ct.luxeMultiplier === "number")
                        carTiers.luxeMultiplier = Number(ct.luxeMultiplier);
                    if (typeof ct.comfortLabel === "string" && ct.comfortLabel)
                        carTiers.comfortLabel = ct.comfortLabel;
                    if (typeof ct.premiumLabel === "string" && ct.premiumLabel)
                        carTiers.premiumLabel = ct.premiumLabel;
                    if (typeof ct.luxeLabel === "string" && ct.luxeLabel)
                        carTiers.luxeLabel = ct.luxeLabel;
                }
            }
            catch (_q) {
                // Individual doc fetch failed — continue with already-resolved config
            }
        }
    }
    catch (_r) {
        // Firestore unreachable — fallback to in-memory defaults
    }
    return { rates, carTiers, regionalSurge, currencySymbol };
}
function carTierConfigForTierId(tierId, carTiers) {
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
async function computeFares(params) {
    var _a, _b, _c, _d;
    const { serviceType, selectedTiers, distanceKm, durationMins } = params;
    const { rates: dbRates, carTiers, regionalSurge, currencySymbol } = await resolveRegionConfig({
        countryCode: params.countryCode,
        stateOrRegion: params.stateOrRegion,
    });
    const results = [];
    if (serviceType === "ride") {
        const carRate = (_a = dbRates.car) !== null && _a !== void 0 ? _a : DEFAULT_RATES.car;
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
    }
    else {
        // Delivery: send_item or receive_item - all 6 delivery categories (incl. Car / Sedan) per Fleet Scope Matrix
        const tiersToCalc = (selectedTiers && selectedTiers.length > 0)
            ? selectedTiers
            : ["bicycle", "motorcycle", "tricycle", "car", "van", "truck"];
        for (const rawCat of tiersToCalc) {
            const norm = rawCat.toLowerCase();
            const rate = (_c = (_b = dbRates[norm]) !== null && _b !== void 0 ? _b : DEFAULT_RATES[norm]) !== null && _c !== void 0 ? _c : DEFAULT_RATES.motorcycle;
            const surge = (rate.surgeMultiplier || 1.0) * regionalSurge;
            const distanceFare = distanceKm * rate.distanceRatePerKm;
            const timeFare = durationMins * rate.timeRatePerMinute;
            const variableFare = (distanceFare + timeFare) * surge;
            const rawTotal = rate.baseFee + variableFare;
            const totalFare = roundToNearest100(rawTotal, rate.baseFee);
            results.push({
                tierId: rawCat,
                name: (_d = DELIVERY_TIER_NAMES[norm]) !== null && _d !== void 0 ? _d : norm,
                isRecommended: norm === "motorcycle",
                fareFormatted: formatCurrency(totalFare, currencySymbol),
                fareAmount: totalFare,
            });
        }
    }
    return results;
}
//# sourceMappingURL=pricing.js.map