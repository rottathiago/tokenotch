import { test, expect } from "@playwright/test";

const now = Date.parse("2026-09-30T12:00:00Z");
const notice = {id:"a".repeat(64),session:"b".repeat(64),source:"cli",kind:"inputRequested",timestamp:now,
  viewed:false,dismissed:false,resolved:false,restored:false};
async function fixture(page, automatic = false) {
  await page.clock.install({time:new Date(now)});
  await page.addInitScript(({now,notice,automatic}) => {
    window.__notices = [notice];
    window.__acks = [];
    window.__healthCalls = 0;
    window.__widget = {widgetExpanded:automatic,widgetAutomatic:automatic,widgetVisible:true,
      widgetAlertUntil:now + 60000,widgetAlert:automatic ? {title:"Copilot context is above 80%",body:"Observed crossing",observedAt:now,target:{kind:"usage"}} : null};
  },{now,notice,automatic});
  await page.route("**/src/bridge.js",async route => {
    const response = await route.fetch();
    await route.fulfill({response,body:`${await response.text()}
      const original = bridge.snapshot.bind(bridge);
      bridge.snapshot = async () => ({...await original(),notices:structuredClone(window.__notices),...window.__widget});
      bridge.onWidgetExpansion = async callback => {window.__expansion = callback;};
      bridge.setExpanded = async (expanded,dismiss) => {
        if (expanded) { window.__widget.widgetAutomatic = false; window.__widget.widgetExpanded = true; }
        else if (dismiss) { window.__widget.widgetAutomatic = false; window.__widget.widgetExpanded = false; }
      };
      bridge.acknowledge = async (id,dismiss) => {
        window.__acks.push({id,dismiss});
        const notice = window.__notices.find(notice => notice.id === id);
        notice.viewed = true; notice.dismissed = dismiss;
      };
      bridge.onNotification = async callback => {window.__activation = callback;};
      bridge.takeNotification = async () => {
        const target = window.__target;
        window.__target = null;
        if (target?.kind === "notice" && !window.__notices.some(notice => notice.id === target.id)) throw new Error("This notification target expired or was cleared.");
        return target;
      };
      bridge.health = async () => {window.__healthCalls++;};`});
  });
}

test("notification categories are independent opt-ins and never imply billing alerts or network consent",async ({page}) => {
  await page.goto("/");
  await page.getByRole("button",{name:"Notifications",exact:true}).click();
  for (const name of ["High CLI context crossings","Copilot service incidents","Copilot incident recovery","Mute every notification channel"]) {
    await expect(page.getByLabel(name,{exact:false})).not.toBeChecked();
  }
  await page.getByLabel("High CLI context crossings",{exact:false}).check();
  await page.getByLabel("Copilot service incidents",{exact:false}).check();
  await page.getByLabel("Play sound",{exact:true}).check();
  await page.getByLabel("Desktop banners",{exact:true}).uncheck();
  await expect(page.getByLabel("Play sound",{exact:true})).toBeChecked();
  await expect(page.locator('[data-view="notifications"]')).toContainText("Quota ring thresholds are visual only");
  await page.getByRole("button",{name:"Connections",exact:true}).click();
  await expect(page.getByLabel("Check public GitHub service health",{exact:false})).not.toBeChecked();
});

test("untouched automatic cards ignore hover/focus and only acknowledge after deliberate engagement",async ({page}) => {
  await fixture(page,true);
  await page.goto("/?surface=widget");
  await expect(page.locator(".delivery-card")).toContainText("above 80%");
  await page.locator("#notch").dispatchEvent("mouseenter");
  await page.locator(".notice-row").focus();
  await page.clock.runFor(4500);
  expect(await page.evaluate(() => window.__acks)).toEqual([]);
  await page.locator(".notice-row").scrollIntoViewIfNeeded();
  const reading=await page.locator(".notice-row").evaluate(async node => {
    const {clippedFraction}=await import("/src/interaction.js");
    const ancestors=[];
    for(let parent=node;parent;parent=parent.parentElement) {
      const rect=parent.getBoundingClientRect();
      ancestors.push({id:parent.id,tag:parent.tagName,top:rect.top,bottom:rect.bottom,height:parent.clientHeight,overflow:window.getComputedStyle(parent).overflow});
    }
    return {fraction:clippedFraction(node),ancestors};
  });
  expect(reading.fraction,JSON.stringify(reading)).toBeGreaterThanOrEqual(0.5);
  await page.locator(".notice-row").dispatchEvent("pointerdown");
  await expect.poll(() => page.evaluate(() => window.__widget.widgetAutomatic)).toBe(false);
  await page.clock.runFor(3500);
  await expect.poll(() => page.evaluate(() => window.__acks.map(value => value.dismiss))).toEqual([false]);
  await expect(page.locator(".notice-row")).toBeVisible();
  await page.getByRole("button",{name:"Close summary",exact:true}).click();
  await expect.poll(() => page.evaluate(() => window.__acks.map(value => value.dismiss))).toEqual([false,true]);
  expect(await page.evaluate(() => window.__notices[0].resolved)).toBe(false);
});

for (const [name,close] of [
  ["notch click",async page => page.locator("#notch").click()],
  ["outside click",async page => page.mouse.click(1,1)],
]) test(`closing a pinned card by ${name} clears the seen notice from the notch`,async ({page}) => {
  await fixture(page);
  await page.setViewportSize({width:560,height:1000});
  await page.goto("/?surface=widget");
  await page.locator("#notch").click();
  await expect(page.locator(".notice-row")).toBeVisible();
  await expect(page.locator("#notch .ring-badge")).toHaveCount(1);
  await page.clock.runFor(1500);
  await expect.poll(() => page.evaluate(() => window.__acks)).toEqual([{id:notice.id,dismiss:false}]);
  await close(page);
  await expect.poll(() => page.evaluate(() => window.__acks.map(value => value.dismiss))).toEqual([false,true]);
  await expect(page.locator("#notch .ring-badge")).toHaveCount(0);
});

test("hiding a card interrupts exposure instead of accumulating hidden time",async ({page}) => {
  await fixture(page,true);
  await page.goto("/?surface=widget");
  await page.locator(".notice-row").scrollIntoViewIfNeeded();
  await page.locator(".notice-row").dispatchEvent("pointerdown");
  await page.clock.runFor(1500);
  await page.evaluate(() => {
    window.__widget.widgetVisible = false;
    window.__expansion({expanded:true,automatic:false,visible:false,until:0,alert:null});
  });
  await page.clock.runFor(4000);
  expect(await page.evaluate(() => window.__acks.filter(value => value.dismiss))).toEqual([]);
  await page.evaluate(() => {
    window.__widget.widgetVisible = true;
    window.__expansion({expanded:true,automatic:false,visible:true,until:0,alert:null});
  });
  await page.clock.runFor(2000);
  expect(await page.evaluate(() => window.__acks.filter(value => value.dismiss))).toEqual([]);
});

test("typed notification activation reviews the exact notice and clears it without answering or enabling service checks",async ({page}) => {
  await fixture(page);
  await page.goto("/");
  await page.evaluate(id => {window.__target = {kind:"notice",id};window.__activation();},notice.id);
  await expect(page.locator(`#notice-${notice.id}`)).toBeFocused();
  await expect.poll(() => page.evaluate(() => window.__acks)).toEqual([{id:notice.id,dismiss:true}]);
  expect(await page.evaluate(() => window.__notices[0].resolved)).toBe(false);
  await page.evaluate(() => {window.__target = {kind:"service"};window.__activation();});
  await expect(page.locator("#health")).toBeFocused();
  await expect(page.getByLabel("Check public GitHub service health",{exact:false})).not.toBeChecked();
  expect(await page.evaluate(() => window.__healthCalls)).toBe(0);
  await page.evaluate(id => {window.__notices = [];window.__target = {kind:"notice",id};window.__activation();},notice.id);
  await expect(page.locator("#error")).toContainText("expired or was cleared");
});
