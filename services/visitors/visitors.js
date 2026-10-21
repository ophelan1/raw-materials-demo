// Simulated shoppers for the storefront: a real (headless) Chromium browses the
// React app, so AppSignal for Browser sees genuine page loads, web vitals,
// clicks and errors, and the storefront_* behaviour metrics have data.
//
// One visit every VISIT_MINUTES (randomised ±50%). A visit costs at most four
// API requests, so the default adds roughly 1,000 requests a day.
import puppeteer from "puppeteer-core";

const STOREFRONT_URL = process.env.STOREFRONT_URL || "http://storefront";
const VISIT_MINUTES = Number(process.env.VISIT_MINUTES || 3.5);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chance = (p) => Math.random() < p;
const pick = (list) => list[Math.floor(Math.random() * list.length)];
const think = () => sleep(1500 + Math.random() * 4000);

const VIEWPORTS = [
  { kind: "desktop", width: 1440, height: 900, weight: 0.6 },
  { kind: "tablet", width: 820, height: 1180, weight: 0.1 },
  { kind: "mobile", width: 390, height: 844, weight: 0.3, isMobile: true, hasTouch: true },
];

function viewport() {
  let r = Math.random();
  for (const v of VIEWPORTS) { if ((r -= v.weight) < 0) return v; }
  return VIEWPORTS[0];
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium-browser",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
// A shared context keeps localStorage, so some visitors come back as "returning".
const regulars = await browser.createBrowserContext();

async function visit() {
  const context = chance(0.35) ? regulars : await browser.createBrowserContext();
  const page = await context.newPage();
  const v = viewport();
  await page.setViewport(v);
  const log = [v.kind, context === regulars ? "returning" : "new"];

  try {
    await page.goto(`${STOREFRONT_URL}/`, { waitUntil: "networkidle0", timeout: 20_000 });
    await think();
    if (chance(0.15)) return log.push("bounced");

    const products = await page.$$("a.button");
    await pick(products).click();
    await page.waitForSelector("form", { timeout: 10_000 });
    log.push(new URL(page.url()).pathname);
    await think();
    if (chance(0.2)) return log.push("abandoned");

    await page.select("select", pick(await page.$$eval("select option", (os) => os.map((o) => o.value))));
    const quantity = await page.$('input[type="number"]');
    await quantity.click({ clickCount: 3 });
    await quantity.type(String(1 + Math.floor(Math.random() * 12)));
    if (chance(0.25)) await page.click('label.inline:nth-of-type(2) input');
    await think();

    const outcome = await submit(page);
    log.push(outcome);
    if (outcome === "failed") {
      // What people do when the payment fails: retry, hammer the button, or pay by invoice.
      await think();
      if (chance(0.35)) {
        await page.click('label.inline:nth-of-type(2) input');
        log.push("invoice", await submit(page));
      } else if (chance(0.5)) {
        log.push("rage", await submit(page, 3));
      } else {
        log.push("retry", await submit(page));
      }
    }
    await think();
  } catch (error) {
    log.push(`error: ${error.message}`);
  } finally {
    // Leaving the page fires visibilitychange, which flushes the SDK and the
    // behaviour beacons before the tab closes.
    await page.goto("about:blank").catch(() => {});
    await sleep(500);
    await page.close().catch(() => {});
    if (context !== regulars) await context.close().catch(() => {});
    console.log(new Date().toISOString(), log.join(" → "));
  }
}

async function submit(page, clicks = 1) {
  const button = await page.$('button[type="submit"]');
  for (let i = 0; i < clicks; i++) await button.click({ delay: 20 }).catch(() => {});
  const result = await page.waitForFunction(() => {
    if (location.pathname.startsWith("/orders/")) return "paid";
    const notice = document.querySelector("form + .notice");
    if (!notice) return false;
    return notice.textContent.includes("couldn't take the payment") ? "failed" : "rejected";
  }, { timeout: 15_000 });
  return result.jsonValue();
}

for (;;) {
  await visit();
  await sleep(VISIT_MINUTES * 60_000 * (0.5 + Math.random()));
}
