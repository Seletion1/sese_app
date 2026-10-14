import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as https from "https";

const db = () => admin.firestore();

/**
 * Fallback static rates for NGN base currency if external API call fails
 * or quota threshold is hit.
 */
const FALLBACK_RATES: Record<string, number> = {
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
function fetchHttpsJson(url: string): Promise<any> {
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
          } catch (e) {
            reject(new Error(`Failed to parse JSON: ${e}`));
          }
        } else {
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
export async function performExchangeRateSync(): Promise<{
  success: boolean;
  quotaHalted: boolean;
  apiCallsThisMonth: number;
  rates: Record<string, number>;
}> {
  const now = new Date();
  const currentMonthStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;

  // 1. Read existing cached exchange rates & quota counter
  const ratesRef = db().collection("system_config").doc("exchange_rates");
  const ratesSnap = await ratesRef.get();
  const ratesData = ratesSnap.exists ? ratesSnap.data() || {} : {};

  let apiCallsThisMonth = Number(ratesData.apiCallsThisMonth ?? 0);
  const lastSyncedMonth = String(ratesData.lastSyncedMonth ?? "");

  // Reset monthly counter on month rollover
  if (lastSyncedMonth !== currentMonthStr) {
    apiCallsThisMonth = 0;
  }

  // 2. HARD QUOTA GUARDRAIL: Cap at 900 calls/month (out of 1,500 free tier limit)
  if (apiCallsThisMonth >= 900) {
    console.warn(
      `syncGlobalExchangeRates: Monthly quota limit reached (${apiCallsThisMonth}/900 max limit). ` +
      `Halting automated API calls and serving cached rates until month reset.`
    );
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
      if (key.length > 0) apiKey = key;
    }
  } catch (e) {
    console.warn(`syncGlobalExchangeRates: Warning reading remote_keys doc: ${e}`);
  }

  // 4. Fetch live rates from ExchangeRate-API
  let liveRates: Record<string, number> = { ...FALLBACK_RATES };
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
      } else {
        console.warn(`syncGlobalExchangeRates: API response did not indicate success: ${JSON.stringify(response)}`);
      }
    } catch (err) {
      console.warn(`syncGlobalExchangeRates: HTTPS request failed (${err}). Falling back to cached/default rates.`);
    }
  } else {
    console.log("syncGlobalExchangeRates: Sample/mock API key detected. Using fallback exchange rates.");
  }

  // Ensure baseline fallback rates are merged if missing
  for (const [curr, val] of Object.entries(FALLBACK_RATES)) {
    if (typeof liveRates[curr] !== "number") {
      liveRates[curr] = val;
    }
  }

  // 5. Write rates payload to Firestore document /system_config/exchange_rates
  await ratesRef.set(
    {
      baseCurrency: "NGN",
      rates: liveRates,
      lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      apiCallsThisMonth: apiSuccess ? apiCallsThisMonth : Number(ratesData.apiCallsThisMonth ?? 0),
      lastSyncedMonth: currentMonthStr,
    },
    { merge: true }
  );

  return {
    success: true,
    quotaHalted: false,
    apiCallsThisMonth: apiSuccess ? apiCallsThisMonth : Number(ratesData.apiCallsThisMonth ?? 0),
    rates: liveRates,
  };
}

/**
 * Scheduled Cloud Function (strictly every 6 hours = 4 runs/day = ~120 calls/month).
 */
export const syncGlobalExchangeRates = onSchedule(
  { schedule: "0 */6 * * *", timeZone: "UTC" },
  async () => {
    console.log("syncGlobalExchangeRates: Starting scheduled 6-hour sync...");
    await performExchangeRateSync();
  }
);

/**
 * Admin Callable: Manually trigger exchange rate sync.
 */
export const triggerExchangeRatesSync = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  return await performExchangeRateSync();
});
