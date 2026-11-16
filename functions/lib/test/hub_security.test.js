"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const verification_1 = require("../verification");
const trips_1 = require("../trips");
(0, node_test_1.describe)("Hub Security & RBAC Guards", () => {
    (0, node_test_1.describe)("assertHubStaffOrAdmin security verification", () => {
        (0, node_test_1.test)("rejects unauthenticated requests with permission-denied", async () => {
            await node_assert_1.default.rejects(async () => {
                await (0, verification_1.assertHubStaffOrAdmin)(null);
            }, (err) => {
                return err.code === "permission-denied";
            });
            await node_assert_1.default.rejects(async () => {
                await (0, verification_1.assertHubStaffOrAdmin)(undefined);
            }, (err) => {
                return err.code === "permission-denied";
            });
        });
        (0, node_test_1.test)("rejects standard customer and driver accounts without admin claims", async () => {
            const customerAuth = {
                uid: "user_cust_123",
                token: { email: "customer@example.com", role: "CUSTOMER" },
            };
            await node_assert_1.default.rejects(async () => {
                await (0, verification_1.assertHubStaffOrAdmin)(customerAuth);
            }, (err) => {
                return err.code === "permission-denied";
            });
            const driverAuth = {
                uid: "driver_456",
                token: { email: "driver@example.com", role: "DRIVER" },
            };
            await node_assert_1.default.rejects(async () => {
                await (0, verification_1.assertHubStaffOrAdmin)(driverAuth);
            }, (err) => {
                return err.code === "permission-denied";
            });
        });
        (0, node_test_1.test)("allows platform owner and admin accounts", async () => {
            const adminAuth = {
                uid: "admin_789",
                token: { email: "admin@example.com", admin: true, role: "SUPER_ADMIN" },
            };
            await node_assert_1.default.doesNotReject(async () => {
                await (0, verification_1.assertHubStaffOrAdmin)(adminAuth);
            });
        });
    });
    (0, node_test_1.describe)("submitCancellationFeedback authentication and user attribution", () => {
        (0, node_test_1.test)("rejects unauthenticated feedback submission with unauthenticated error", async () => {
            const unauthRequest = {
                data: {
                    tripId: "trip_test_99",
                    userId: "spoofed_user",
                    role: "customer",
                    reason: "driver_taking_too_long",
                },
            };
            await node_assert_1.default.rejects(async () => {
                await trips_1.submitCancellationFeedback.run(unauthRequest);
            }, (err) => {
                return err.code === "unauthenticated";
            });
        });
    });
});
//# sourceMappingURL=hub_security.test.js.map