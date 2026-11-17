import * as admin from "firebase-admin";
import { onMessagePublished } from "firebase-functions/v2/pubsub";

const db = () => admin.firestore();

/**
 * Pub/Sub Cloud Function Handler for GCP Cloud Billing Budget Notifications.
 *
 * Listens on Pub/Sub topic `billing-budget-alerts`. Parses GCP budget event payloads
 * (notifying at 50%, 80%, 100%+ of budget) and automatically engages global emergency
 * circuit-breaking when 100% of the budget threshold is reached to prevent unexpected
 * API cost spikes.
 */
export const handleBillingBudgetAlert = onMessagePublished(
  "billing-budget-alerts",
  async (event) => {
    try {
      const pubsubMessage = event.data?.message;
      if (!pubsubMessage) return;

      const messageData = pubsubMessage.data
        ? Buffer.from(pubsubMessage.data, "base64").toString("utf-8")
        : "{}";
      const notification = JSON.parse(messageData);

      const costAmount = Number(notification.costAmount ?? 0);
      const budgetAmount = Number(notification.budgetAmount ?? 0);
      const budgetName = String(notification.budgetDisplayName ?? "GCP Billing Budget");
      const currencyCode = String(notification.currencyCode ?? "USD");

      const thresholdRatio =
        budgetAmount > 0 ? costAmount / budgetAmount : 0;
      const percentage = (thresholdRatio * 100).toFixed(1);

      console.log(
        JSON.stringify({
          severity: thresholdRatio >= 1.0 ? "CRITICAL" : thresholdRatio >= 0.8 ? "WARNING" : "INFO",
          message: `[BillingAlert] Budget notification received for ${budgetName}: ${percentage}% used (${costAmount}/${budgetAmount} ${currencyCode}).`,
          costAmount,
          budgetAmount,
          thresholdRatio,
          currencyCode,
        })
      );

      // Emergency Circuit Breaking: Engage global Google Maps kill-switch if budget reaches 100%
      if (thresholdRatio >= 1.0) {
        console.error(
          JSON.stringify({
            severity: "CRITICAL",
            message: `[BillingAlert] CRITICAL: 100% Cloud Billing budget threshold reached (${percentage}%). Engaging emergency circuit breaker!`,
          })
        );

        await db().collection("system_config").doc("remote_keys").set(
          {
            emergencyCircuitBreakerActive: true,
            emergencyCircuitBreakerReason: `Cloud Billing budget threshold reached (${percentage}% of ${budgetAmount} ${currencyCode})`,
            emergencyCircuitBreakerEngagedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        await db().collection("system_configs").doc("global_default").set(
          {
            googleMapsDisabled: true,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }
    } catch (err) {
      console.error("[BillingAlert] Error processing budget notification:", err);
    }
  }
);
