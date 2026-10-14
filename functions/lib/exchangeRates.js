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
exports.triggerExchangeRatesSync = exports.syncGlobalExchangeRates = void 0;
exports.performExchangeRateSync = performExchangeRateSync;
const admin = __importStar(require("firebase-admin"));
const scheduler_1 = require("firebase-functions/v2/scheduler");
const https_1 = require("firebase-functions/v2/https");
const https = __importStar(require("https"));
const db = () => admin.firestore();
/**
 * Fallback static rates for NGN base currency if external API call fails
 * or quota threshold is hit.
 */
const FALLBACK_RATES = {
    NGN: 1.0,
    USD: 0.00063,
    EUR: 0.00058,
    GBP: 0.00049,
    GHS: 0.0098,
    XOF: 0.38,
    XAF: 0.38,
    KES: 0.081,
    ZAR: 0.011,
    CAD: 0.00085,
    AUD: 0.00095,
};
/**
 * Helper to fetch HTTPS GET JSON content.
 */
function fetchHttpsJson(url) {
    return new Promise((resolve, reject) => {
        const req = https.get(url, (res) => {
            let data = "";
            res.on("data", (chunk) => {
                data += chunk;
            });
            res.on("end", () => {
                if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
                    try {
                        resolve(JSON.parse(data));
                    }
                    catch (e) {
                        reject(new Error(`Failed to parse JSON: ${e}`));
                    }
                }
                else {
                    reject(new Error(`HTTP status ${res.statusCode}: ${data}`));
                }
            });
        });
        req.on("error", (err) => reject(err));
        req.setTimeout(10000, () => {
            req.destroy();
            reject(new Error("Request timeout"));
        });
    });
}
/**
 * Core engine logic to sync rates with quota guardrails.
 */
async function performExchangeRateSync() {
    var _a, _b, _c, _d;
    const now = new Date();
    const currentMonthStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
    // 1. Read existing cached exchange rates & quota counter
    const ratesRef = db().collection("system_config").doc("exchange_rates");
    const ratesSnap = await ratesRef.get();
    const ratesData = ratesSnap.exists ? ratesSnap.data() || {} : {};
    let apiCallsThisMonth = Number((_a = ratesData.apiCallsThisMonth) !== null && _a !== void 0 ? _a : 0);
    const lastSyncedMonth = String((_b = ratesData.lastSyncedMonth) !== null && _b !== void 0 ? _b : "");
    // Reset monthly counter on month rollover
    if (lastSyncedMonth !== currentMonthStr) {
        apiCallsThisMonth = 0;
    }
    // 2. HARD QUOTA GUARDRAIL: Cap at 900 calls/month (out of 1,500 free tier limit)
    if (apiCallsThisMonth >= 900) {
        console.warn(`syncGlobalExchangeRates: Monthly quota limit reached (${apiCallsThisMonth}/900 max limit). ` +
            `Halting automated API calls and serving cached rates until month reset.`);
        return {
            success: true,
            quotaHalted: true,
            apiCallsThisMonth,
            rates: ratesData.rates || FALLBACK_RATES,
        };
    }
    // 3. Read exchangeRateApiKey from /system_config/remote_keys
    let apiKey = "ex_live_79a2b8c3d4e5f6g7h8i9_sample";
    try {
        const keysSnap = await db().collection("system_config").doc("remote_keys").get();
        if (keysSnap.exists) {
            const keysData = keysSnap.data() || {};
            const key = String(keysData.exchangeRateApiKey || "").trim();
            if (key.length > 0)
                apiKey = key;
        }
    }
    catch (e) {
        console.warn(`syncGlobalExchangeRates: Warning reading remote_keys doc: ${e}`);
    }
    // 4. Fetch live rates from ExchangeRate-API
    let liveRates = Object.assign({}, FALLBACK_RATES);
    let apiSuccess = false;
    if (apiKey && !apiKey.includes("sample")) {
        try {
            const url = `https://v6.exchangerate-api.com/v6/${apiKey}/latest/NGN`;
            const response = await fetchHttpsJson(url);
            if (response && response.result === "success" && response.conversion_rates) {
                liveRates = response.conversion_rates;
                apiSuccess = true;
                apiCallsThisMonth += 1;
                console.log(`syncGlobalExchangeRates: Successfully fetched live rates from API. Calls this month: ${apiCallsThisMonth}`);
            }
            else {
                console.warn(`syncGlobalExchangeRates: API response did not indicate success: ${JSON.stringify(response)}`);
            }
        }
        catch (err) {
            console.warn(`syncGlobalExchangeRates: HTTPS request failed (${err}). Falling back to cached/default rates.`);
        }
    }
    else {
        console.log("syncGlobalExchangeRates: Sample/mock API key detected. Using fallback exchange rates.");
    }
    // Ensure baseline fallback rates are merged if missing
    for (const [curr, val] of Object.entries(FALLBACK_RATES)) {
        if (typeof liveRates[curr] !== "number") {
            liveRates[curr] = val;
        }
    }
    // 5. Write rates payload to Firestore document /system_config/exchange_rates
    await ratesRef.set({
        baseCurrency: "NGN",
        rates: liveRates,
        lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
        apiCallsThisMonth: apiSuccess ? apiCallsThisMonth : Number((_c = ratesData.apiCallsThisMonth) !== null && _c !== void 0 ? _c : 0),
        lastSyncedMonth: currentMonthStr,
    }, { merge: true });
    return {
        success: true,
        quotaHalted: false,
        apiCallsThisMonth: apiSuccess ? apiCallsThisMonth : Number((_d = ratesData.apiCallsThisMonth) !== null && _d !== void 0 ? _d : 0),
        rates: liveRates,
    };
}
/**
 * Scheduled Cloud Function (strictly every 6 hours = 4 runs/day = ~120 calls/month).
 */
exports.syncGlobalExchangeRates = (0, scheduler_1.onSchedule)({ schedule: "0 */6 * * *", timeZone: "UTC" }, async () => {
    console.log("syncGlobalExchangeRates: Starting scheduled 6-hour sync...");
    await performExchangeRateSync();
});
/**
 * Admin Callable: Manually trigger exchange rate sync.
 */
exports.triggerExchangeRatesSync = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    return await performExchangeRateSync();
});
//# sourceMappingURL=exchangeRates.js.map