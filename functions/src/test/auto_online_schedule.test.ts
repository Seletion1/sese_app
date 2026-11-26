import test from "node:test";
import assert from "node:assert/strict";
import { watHHMM, watDateString, hasReachedOrPassed } from "../autoOnlineSchedule";

test("watHHMM formats UTC timestamps strictly in Africa/Lagos (UTC+1)", () => {
  // 05:00 UTC -> 06:00 WAT
  assert.equal(watHHMM(new Date("2026-11-26T05:00:00.000Z")), "06:00");
  // 21:00 UTC -> 22:00 WAT
  assert.equal(watHHMM(new Date("2026-11-26T21:00:00.000Z")), "22:00");
  // 23:05 UTC -> 00:05 WAT next day (must be 00:05, never 24:05)
  assert.equal(watHHMM(new Date("2026-11-26T23:05:00.000Z")), "00:05");
});

test("watDateString formats UTC timestamps in WAT YYYY-MM-DD", () => {
  // 22:59 UTC is 23:59 WAT same day
  assert.equal(watDateString(new Date("2026-11-26T22:59:00.000Z")), "2026-11-26");
  // 23:00 UTC is 00:00 WAT next day
  assert.equal(watDateString(new Date("2026-11-26T23:00:00.000Z")), "2026-11-27");
});

test("hasReachedOrPassed compares HH:MM strings accurately", () => {
  assert.equal(hasReachedOrPassed("05:59", "06:00"), false);
  assert.equal(hasReachedOrPassed("06:00", "06:00"), true);
  assert.equal(hasReachedOrPassed("07:30", "06:00"), true);
  assert.equal(hasReachedOrPassed("21:59", "22:00"), false);
  assert.equal(hasReachedOrPassed("22:00", "22:00"), true);
});
