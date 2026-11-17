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
exports.handleBillingBudgetAlert = void 0;
const admin = __importStar(require("firebase-admin"));
const pubsub_1 = require("firebase-functions/v2/pubsub");
const db = () => admin.firestore();
/**
 * Pub/Sub Cloud Function Handler for GCP Cloud Billing Budget Notifications.
 *
 * Listens on Pub/Sub topic `billing-budget-alerts`. Parses GCP budget event payloads
 * (notifying at 50%, 80%, 100%+ of budget) and automatically engages global emergency
 * circuit-breaking when 100% of the budget threshold is reached to prevent unexpected
 * API cost spikes.
 */
exports.handleBillingBudgetAlert = (0, pubsub_1.onMessagePublished)("billing-budget-alerts", async (event) => {
    var _a, _b, _c, _d, _e;
    try {
        const pubsubMessage = (_a = event.data) === null || _a === void 0 ? void 0 : _a.message;
        if (!pubsubMessage)
            return;
        const messageData = pubsubMessage.data
            ? Buffer.from(pubsubMessage.data, "base64").toString("utf-8")
            : "{}";
        const notification = JSON.parse(messageData);
        const costAmount = Number((_b = notification.costAmount) !== null && _b !== void 0 ? _b : 0);
        const budgetAmount = Number((_c = notification.budgetAmount) !== null && _c !== void 0 ? _c : 0);
        const budgetName = String((_d = notification.budgetDisplayName) !== null && _d !== void 0 ? _d : "GCP Billing Budget");
        const currencyCode = String((_e = notification.currencyCode) !== null && _e !== void 0 ? _e : "USD");
        const thresholdRatio = budgetAmount > 0 ? costAmount / budgetAmount : 0;
        const percentage = (thresholdRatio * 100).toFixed(1);
        console.log(JSON.stringify({
            severity: thresholdRatio >= 1.0 ? "CRITICAL" : thresholdRatio >= 0.8 ? "WARNING" : "INFO",
            message: `[BillingAlert] Budget notification received for ${budgetName}: ${percentage}% used (${costAmount}/${budgetAmount} ${currencyCode}).`,
            costAmount,
            budgetAmount,
            thresholdRatio,
            currencyCode,
        }));
        // Emergency Circuit Breaking: Engage global Google Maps kill-switch if budget reaches 100%
        if (thresholdRatio >= 1.0) {
            console.error(JSON.stringify({
                severity: "CRITICAL",
                message: `[BillingAlert] CRITICAL: 100% Cloud Billing budget threshold reached (${percentage}%). Engaging emergency circuit breaker!`,
            }));
            await db().collection("system_config").doc("remote_keys").set({
                emergencyCircuitBreakerActive: true,
                emergencyCircuitBreakerReason: `Cloud Billing budget threshold reached (${percentage}% of ${budgetAmount} ${currencyCode})`,
                emergencyCircuitBreakerEngagedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            await db().collection("system_configs").doc("global_default").set({
                googleMapsDisabled: true,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        }
    }
    catch (err) {
        console.error("[BillingAlert] Error processing budget notification:", err);
    }
});
//# sourceMappingURL=billingAlert.js.map