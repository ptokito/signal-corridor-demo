/**
 * New Relic Synthetics: Scripted Browser monitor
 * Name:      Corridor - Timing compliance check (Thompson Ln)
 * Runtime:   Chrome browser, latest (Node.js based) runtime
 * Frequency: every 5 minutes, from 3 US public locations
 *
 * WHY THIS MONITOR EXISTS
 *   A ping monitor only proves the portal answers. This script proves the corridor
 *   is SAFE: it opens the Murfreesboro Pk & Thompson Ln page the way an engineer
 *   would, reads the live yellow interval from the active timing plan, and fails if
 *   it is below 3.0 seconds. During the timing plan 2026.2 incident every server
 *   still returns HTTP 200, so this business assertion is what turns the problem
 *   into an alert within minutes.
 *
 * SETUP
 *   Synthetic monitoring > Create monitor > Scripted browser. Paste this file and
 *   replace REPLACE_WITH_PORTAL_URL with the terraform output "portal_url"
 *   (for example http://3.91.20.14 with no trailing slash).
 */
const assert = require('assert');
const By = $selenium.By;
const until = $selenium.until;

const PORTAL = 'REPLACE_WITH_PORTAL_URL';
const INTERSECTION_ID = 2;            // Murfreesboro Pk & Thompson Ln, 45 mph
const MIN_YELLOW_SECONDS = 3.0;

// Step 1: the corridor overview loads and lists the intersections.
await $webDriver.get(`${PORTAL}/`);
await $webDriver.wait(until.elementLocated(By.id('corridor')), 10000);
console.log('Corridor overview loaded');

// Step 2: open the intersection page through its link, like a user would.
await $webDriver.findElement(By.id(`link-${INTERSECTION_ID}`)).click();
await $webDriver.wait(until.elementLocated(By.id('yellow-seconds')), 10000);

// Step 3: read the active plan and its yellow interval.
const planVersion = (await $webDriver.findElement(By.id('plan-version')).getText()).trim();
const yellow = parseFloat(
  await $webDriver.findElement(By.id('yellow-seconds')).getAttribute('data-seconds'));
console.log(`Plan ${planVersion}: yellow interval ${yellow} s`);

// Step 4: the business rule. A failed assertion fails the check (and the alert fires).
assert.ok(!Number.isNaN(yellow), 'Yellow interval not found on the page');
assert.ok(yellow >= MIN_YELLOW_SECONDS,
  `UNSAFE TIMING: plan ${planVersion} sets a ${yellow} s yellow at Thompson Ln (minimum ${MIN_YELLOW_SECONDS} s)`);
