import { test, expect } from "@playwright/test";
import { emptyUsage, reportingDay } from "../src/usage.js";

const id = number => number.toString(16).padStart(8,"0") + "b".repeat(56);
const now = Date.parse("2026-09-30T12:30:00Z");
function fixture() {
  const day = reportingDay("2026-09-30","UTC");
  const usage = calls => ({...emptyUsage(),input:calls * 10,calls});
  const days = [
    {day:day.day,source:"cli",model:"alpha",usage:usage(2)},
    {day:day.day,source:"cli",model:null,usage:usage(1)},
    {day:day.day,source:"cli",model:"Other models (capacity limit)",usage:usage(1)},
    {day:day.day,source:"vscodeLocal",model:"editor",usage:usage(8)},
  ];
  const history = {generation:"history",capturedAt:now,modelFilter:null,timeZone:"UTC",startedAt:day.start,coverageBegan:day.start,
    calendar:[day],days,totals:[{day:day.day,source:"cli",usage:usage(4)},{day:day.day,source:"vscodeLocal",usage:usage(8)}],
    hours:[{hour:"2026-09-30T12:00:00+00:00",source:"cli",usage:usage(4)}],gaps:[],sourceGaps:[],coverage:[],hourlyCoverage:[],compactions:[],truncated:false};
  const status = {generation:"timelines",capturedAt:now,cutoff:now - 604800000,retentionDays:7,recording:false,pruned:true,interrupted:true,legacy:true};
  const timeline = {status,session:id(100),truncated:true,events:Array.from({length:201},(_,i) => ({
    session:id(100),source:"cli",timestamp:now - 1000 + i,event:{kind:"usage",tokens:{
      input:1,output:2,cacheInput:0,cacheWrite:0,cacheInputReported:false,cacheWriteReported:true,model:"timeline-model",durationMs:12,timeToFirstTokenMs:3},
    compaction:{success:false,before:100,after:80}}}))};
  return {history,timeline,list:{status,sessions:Array.from({length:201},(_,i) => ({session:id(i),sources:["cli"],first:now-1000,last:now,count:201,truncated:true}))},
    snapshot:{now,today:history,archives:{history:"history",timelines:"timelines",live:"live",timelineCutoff:now-604800000},
      sessions:[{id:id(1),source:"cli",working:true,observedAt:now,label:"Working (live)",context:{observedAtUnixMs:now,context:{currentTokens:20,tokenLimit:100}}}],
      samples:[{session:id(1),source:"cli",linked:true,date:now,tokens:{input:10,output:0,cacheInput:0,cacheWrite:0,model:"alpha"}}]}};
}

async function preview(page, seed = fixture()) {
  await page.clock.install({time:new Date(now)});
  await page.addInitScript(value => { window.__fixture = value; },seed);
  await page.route("**/src/bridge.js",async route => {
    const response = await route.fetch();
    await route.fulfill({response,body:`${await response.text()}
      const originalSnapshot = bridge.snapshot.bind(bridge);
      bridge.snapshot = async () => ({...await originalSnapshot(),...structuredClone(window.__fixture.snapshot)});
      bridge.history = async (start,end,model = null) => {
        const history = structuredClone(window.__fixture.comparison && start < "2026-09-24" ? window.__fixture.comparison : window.__fixture.history);
        history.modelFilter = model;
        if (model !== null) history.days = history.days.filter(row => (row.model ?? "") === model);
        return history;
      };
      bridge.timelineSessions = async () => structuredClone(window.__fixture.list);
      bridge.timelineDetail = async (session,source) => {
        window.__timelineQuery = {session,source};
        if (window.__fixture.expiredSession === session) throw new Error("This session has expired or was cleared.");
        return {...structuredClone(window.__fixture.timeline),session};
      };`});
  });
}

test("model rows filter the page like macOS and chart evidence preserves the selected filters",async ({page}) => {
  await preview(page);
  await page.goto("/");
  await page.getByRole("button",{name:"History",exact:true}).click();
  await page.getByLabel("History source",{exact:true}).selectOption("cli");
  await expect(page.locator('#history-results [data-metric="calls"]')).toContainText("4");
  await expect(page.locator("#history-results .models-table")).toContainText("Model unavailable");
  await expect(page.locator("#history-results .models-table")).toContainText("Other models (detail limit)");
  await page.locator('#history-results [data-history-model="alpha"]').click();
  await expect(page.getByLabel("History model",{exact:true})).toHaveValue("name:alpha");
  await expect(page.locator('#history-results [data-metric="calls"]')).toContainText("2");
  await expect(page.locator("#history-results")).toContainText("Select the model again to show all models.");
  await expect(page.locator('#history-results [data-history-model="alpha"]')).toHaveAttribute("aria-pressed","true");
  const bar = page.locator('#history-results [data-detail^="history-chart:"]').first();
  await bar.focus();
  await bar.press("Enter");
  await expect(page.locator("#detail-heading")).toHaveText("Selected history evidence");
  await page.getByRole("button",{name:"Back to previous view",exact:true}).click();
  await expect(page.getByLabel("History source",{exact:true})).toHaveValue("cli");
  await expect(page.getByLabel("History model",{exact:true})).toHaveValue("name:alpha");
  await page.locator('#history-results [data-history-model="alpha"]').click();
  await expect(page.getByLabel("History model",{exact:true})).toHaveValue("all");
  await expect(page.locator('#history-results [data-metric="calls"]')).toContainText("4");
});

test("History reloads in place when new usage is saved, without leaving the page",async ({page}) => {
  const seed = fixture();
  seed.snapshot.archives.historyRevision = 1;
  await preview(page,seed);
  await page.goto("/");
  await page.getByRole("button",{name:"History",exact:true}).click();
  await expect(page.locator('#history-results [data-metric="calls"]')).toContainText("12");
  await page.evaluate(() => {
    window.__fixture.history.totals[0].usage.calls = 10;
    window.__fixture.history.totals[0].usage.input = 100;
  });
  await page.clock.fastForward(3100);
  await expect(page.locator('#history-results [data-metric="calls"]')).toContainText("12");
  await page.evaluate(() => { window.__fixture.snapshot.archives.historyRevision = 2; });
  await page.clock.fastForward(3100);
  await expect(page.locator('#history-results [data-metric="calls"]')).toContainText("18");
  await expect(page.locator('[data-view="history"]')).toBeVisible();
});

test("paused history keeps saved usage visible and explains that new usage isn't saved",async ({page}) => {
  await preview(page);
  await page.goto("/");
  await page.getByRole("button",{name:"History",exact:true}).click();
  await expect(page.locator("#recording-badge")).toHaveText("Off");
  await expect(page.locator("#history-results")).toContainText("History is off");
  await expect(page.locator("#history-results")).toContainText("Saved usage is shown below. New usage isn't being saved.");
  await expect(page.locator('#history-results [data-metric="tokens"]')).toBeVisible();
  await expect(page.getByRole("button",{name:"Turn On\u2026",exact:true})).toBeVisible();
});

test("periods follow macOS: Last 30 days by default, single days use Per call, and choose day offers a comparison date",async ({page}) => {
  await preview(page);
  await page.goto("/");
  await page.getByRole("button",{name:"History",exact:true}).click();
  await expect(page.getByLabel("Period",{exact:true})).toHaveValue("days30");
  await expect(page.locator("#history-results")).toContainText("Daily tokens");
  await expect(page.locator("#history-results")).toContainText("Compared with previous period");
  await expect(page.locator("#history-results")).toContainText("Compares completed days only. Missing days aren't counted as zero.");
  await expect(page.locator("#history-results")).toContainText("Daily breakdown");
  await expect(page.locator("#history-dates")).toBeHidden();
  await page.getByLabel("Period",{exact:true}).selectOption("today");
  await expect(page.locator('#history-results [data-metric="average"]')).toContainText("Per call");
  await expect(page.locator("#history-results")).toContainText("The current period isn't finished, so changes aren't shown yet.");
  await expect(page.locator("#history-results")).not.toContainText("Daily tokens");
  await expect(page.locator("#history-results")).not.toContainText("Daily breakdown");
  await page.getByLabel("Period",{exact:true}).selectOption("day");
  await expect(page.locator("#history-dates")).toBeVisible();
  await expect(page.getByLabel("Compare with",{exact:true})).toHaveValue("2026-08-31");
  await expect(page.getByLabel("Day",{exact:true})).toHaveValue("2026-09-30");
});

test("widget model selection routes a captured source and period into settings",async ({page}) => {
  await preview(page);
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await page.getByLabel("Usage source",{exact:true}).selectOption("cli");
  await page.locator('#widget-models [data-detail="widget-model:alpha"]').click();
  await expect(page.locator("#detail-heading")).toHaveText("Selected history evidence");
  await expect(page.locator("#detail-content")).toContainText("Copilot CLI");
  await expect(page.locator("#detail-content")).toContainText("2026-09-30 through 2026-09-30");
  await expect(page.locator("#detail-content")).toContainText("Selected call share: 50%");
});

test("widget live-only and hourly targets keep the displayed evidence rather than substituting daily models",async ({page}) => {
  const seed = fixture();
  seed.snapshot.today = null;
  await preview(page,seed);
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await page.locator('#widget-models [data-detail="widget-model:alpha"]').click();
  await expect(page.locator("#detail-heading")).toHaveText("Captured live-only usage");
  await expect(page.locator("#detail-content")).toContainText("10 tokens; 1 calls");
  await page.evaluate(() => { window.__fixture.snapshot.samples[0].tokens.input = 999; });
  await page.clock.fastForward(3100);
  await expect(page.locator("#detail-content")).toContainText("10 tokens; 1 calls");
  await page.evaluate(() => {
    window.__fixture.snapshot.today = window.__fixture.history;
  });
  await page.getByRole("button",{name:"Usage",exact:true}).click();
  await page.clock.fastForward(3100);
  await page.locator("#usage-chart [data-current] button").click();
  await expect(page.locator("#detail-content")).toContainText("Daily model totals are not substituted for this hour");
  await expect(page.locator("#detail-content")).toContainText("40 tokens; 4 calls");
});

test("session list and complete captured timeline paginate with explicit pruning and missing targets",async ({page}) => {
  const seed = fixture();
  seed.expiredSession = id(0);
  await preview(page,seed);
  await page.goto("/");
  await page.getByRole("button",{name:"Sessions",exact:true}).click();
  await page.getByRole("button",{name:"Browse saved timelines",exact:true}).click();
  await expect(page.locator("#timeline-results")).toContainText("201 retained sessions");
  await page.locator(`[data-session="${id(0)}"]`).click();
  await expect(page.locator("#error")).toContainText("expired or was cleared");
  await page.locator('[data-timeline-page="1"]').click();
  const selected = page.locator(`#timeline-results [data-session="${id(100)}"]`);
  await selected.click();
  await expect(page.locator("#detail-content")).toContainText("Some events from this session were removed");
  await expect(page.locator("#detail-content")).toContainText("Historical context below is not a live context reading");
  await page.locator('[data-detail-page="1"]').click();
  await page.locator('[data-detail-page="2"]').click();
  await expect(page.locator("#detail-content")).toContainText("Showing 201-201 of 201");
  await expect(page.locator("#detail-content")).toContainText("Failed completion");
  await page.evaluate(() => { window.__fixture.timeline.events = []; });
  await page.clock.fastForward(3100);
  await expect(page.locator("#detail-content")).toContainText("Showing 201-201 of 201");
  await page.getByRole("button",{name:"Back to previous view",exact:true}).click();
  await expect(page.locator("#timeline-results")).toContainText("Page 2 of 3");
  await expect(selected).toBeFocused();
});

test("background refresh preserves expanded live sessions and keyboard focus; cleared evidence cannot reappear",async ({page}) => {
  await preview(page);
  await page.goto("/");
  await page.getByRole("button",{name:"Usage",exact:true}).click();
  const session = page.locator("#usage-sessions .session");
  await session.locator("summary").click();
  const link = session.getByRole("button",{name:"Open saved session timeline"});
  await link.focus();
  await page.evaluate(() => { window.__fixture.snapshot.samples[0].tokens.input = 11; });
  await page.clock.fastForward(3100);
  await expect(session).toHaveAttribute("open","");
  await expect(link).toBeFocused();
  await link.press("Enter");
  expect(await page.evaluate(() => window.__timelineQuery)).toEqual({session:id(1),source:"cli"});
  await expect(page.locator("#detail-heading")).toContainText(id(1).slice(0,8));
  await page.evaluate(() => { window.__fixture.snapshot.archives.timelineCutoff = window.__fixture.snapshot.now + 1; });
  await page.clock.fastForward(3100);
  await expect(page.locator("#detail-heading")).toHaveText("Selected evidence unavailable");
  await page.getByRole("button",{name:"Usage",exact:true}).click();
  await page.locator('#models [data-detail="usage-model:alpha"]').click();
  await page.evaluate(() => {
    window.__fixture.snapshot.archives.history = "cleared";
    window.__fixture.snapshot.today.generation = "cleared";
    window.__fixture.snapshot.today.days = [];
    window.__fixture.snapshot.today.totals = [];
  });
  await page.clock.fastForward(3100);
  await expect(page.locator("#detail-heading")).toHaveText("Selected evidence unavailable");
});

test("each insight opens its captured matched periods and independently sampled source evidence",async ({page}) => {
  const seed = fixture();
  const calendar = Array.from({length:14},(_,i) => {
    const day = `2026-09-${16 + i}`;
    return {day,start:Date.parse(`${day}T00:00:00Z`),end:Date.parse(`${day}T00:00:00Z`)+86400000,hours:[]};
  });
  const days = calendar.map(day => ({day:day.day,source:"cli",model:"alpha",usage:{...emptyUsage(),calls:4,firstTokenSamples:4,firstTokenMs:12,durationSamples:1,durationMs:10}}));
  seed.comparison = {...seed.history,calendar,days,totals:days,compactions:[["2026-09-18",2,1],["2026-09-28",1,2]]};
  await preview(page,seed);
  await page.goto("/");
  await page.getByRole("button",{name:"History",exact:true}).click();
  await page.getByLabel("History source",{exact:true}).selectOption("cli");
  await expect(page.locator("#history-results")).toContainText("Weekly insights");
  await page.getByRole("button",{name:/Open First-token latency evidence/}).click();
  await expect(page.locator("#detail-content")).toContainText("Copilot CLI");
  await expect(page.locator("#detail-content")).toContainText("Previous 2026-09-16 through 2026-09-22; current 2026-09-23 through 2026-09-29");
  await expect(page.locator("#detail-content")).toContainText("Independent field coverage: 28 / 28 calls");
  await page.getByRole("button",{name:"Back to previous view",exact:true}).click();
  await page.getByRole("button",{name:/Open Call duration evidence/}).click();
  await expect(page.locator("#detail-content")).toContainText("Independent field coverage: 7 / 28 calls");
  await page.getByRole("button",{name:"Back to previous view",exact:true}).click();
  await page.getByRole("button",{name:/Open Compaction frequency evidence/}).click();
  await expect(page.locator("#detail-content")).toContainText("Successful completions: 2. Failed completions: 1");
  await page.getByRole("button",{name:"Back to previous view",exact:true}).click();
  await expect(page.locator("#history-results")).toContainText("Context window");
  await expect(page.locator("#history-results")).toContainText("Failed compactions");
  await page.evaluate(() => {
    window.__fixture.snapshot.archives.history = "cleared";
    window.__fixture.snapshot.today.generation = "cleared";
  });
  await page.getByRole("button",{name:/Open Model mix evidence/}).click();
  await expect(page.locator("#error")).toContainText("cleared or expired");
});
