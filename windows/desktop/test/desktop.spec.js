import {test,expect} from "@playwright/test";
const now=Date.parse("2026-10-01T12:00:00Z");
const id=i=>String(i).repeat(64);
async function fixture(page,preferences={},notices=[1,2,3]) {
  await page.clock.install({time:new Date(now)});
  await page.clock.pauseAt(new Date(now+1000));
  await page.addInitScript(({now,preferences,notices})=>{
    window.__desktopPrefs=preferences;
    window.__acks=[];
    window.__desktopNotices=notices.map(i=>({id:String(i).repeat(64),session:String(i).repeat(64),kind:"inputRequested",source:"cli",
      timestamp:now-i,viewed:false,dismissed:false,resolved:false,restored:false}));
  },{now,preferences,notices});
  await page.route("**/src/bridge.js",async route=>{
    const response=await route.fetch();
    await route.fulfill({response,body:`${await response.text()}
      const baseSnapshot=bridge.snapshot.bind(bridge);
      bridge.snapshot=async()=>{
        const base=await baseSnapshot();
        return {...base,...window.__desktopWidgetState,now:window.__desktopNow??${now},preferences:{...base.preferences,...window.__desktopPrefs},
          accessibility:window.__desktopAccessibility??base.accessibility,
          notices:structuredClone(window.__desktopNotices),
          sessions:window.__desktopSessions??[{id:"f".repeat(64),source:"cli",kind:"active",working:true,observedAt:${now},label:"Working",context:null}]};
      };
      bridge.acknowledge=async(id,dismiss)=>{
        window.__acks.push({id,dismiss});
        const notice=window.__desktopNotices.find(value=>value.id===id);
        notice.viewed=true; if(dismiss) notice.dismissed=true;
      };
      bridge.onWidgetExpansion=async callback=>{
        window.__desktopExpansion=state=>{
          window.__desktopWidgetState={widgetExpanded:state.expanded,widgetVisible:state.visible,widgetDismissed:state.dismissed};
          callback(state);
        };
      };`});
  });
}
test("keyboard opening, tab boundaries and Escape restore the notch; outside click collapses",async({page})=>{
  await page.goto("/?surface=widget");
  const notch=page.locator("#notch");
  await notch.focus();
  await notch.press("Enter");
  const dialog=page.getByRole("dialog",{name:"GitHub Copilot summary"});
  await expect(dialog).toBeVisible();
  await expect(page.getByRole("button",{name:"Close summary",exact:true})).toBeFocused();
  await page.keyboard.press("Shift+Tab");
  await expect(page.getByRole("button",{name:"GitHub model pricing",exact:true})).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button",{name:"Close summary",exact:true})).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","true");
  await expect(page.locator("#card")).toHaveAttribute("inert","");
  await expect(notch).toBeFocused();
  await notch.press("Enter");
  await page.mouse.click(1,1);
  await expect(notch).toHaveAttribute("aria-expanded","false");
});
test("folded native-surface markup is excluded from accessibility and focus",async({page})=>{
  await page.goto("/?surface=card");
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","true");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await page.locator("#summary-close").evaluate(button=>button.focus());
  expect(await page.locator("#summary-close").evaluate(button=>button===document.activeElement)).toBe(false);
});
test("notice rows behind the scroll viewport are not counted as exposed",async({page})=>{
  await fixture(page,{},[3]);
  await page.setViewportSize({width:560,height:200});
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  const target=page.locator(`#notice-${id(3)}`);
  await target.evaluate(node=>{
    const scroll=document.getElementById("card-scroll");
    scroll.scrollTop+=node.getBoundingClientRect().top-scroll.getBoundingClientRect().bottom-2;
  });
  const fraction=await target.evaluate(async node=>{
    const {clippedFraction}=await import("/src/interaction.js");
    return clippedFraction(node);
  });
  expect(fraction).toBe(0);
  await page.clock.runFor(4000);
  expect(await page.evaluate(id=>window.__acks.filter(value=>value.id===id),id(3))).toEqual([]);
});
test("a replacement row cannot dismiss an older row that left the visible list",async({page})=>{
  await fixture(page);
  await page.setViewportSize({width:560,height:1000});
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await page.clock.runFor(1250);
  await page.evaluate(now=>{
    window.__desktopNotices.unshift({id:"4".repeat(64),session:"4".repeat(64),kind:"error",source:"cli",
      timestamp:now,viewed:false,dismissed:false,resolved:false,restored:false});
  },now);
  await page.getByLabel("Usage source",{exact:true}).selectOption("cli");
  await expect(page.locator(`#notice-${id(3)}`)).toHaveCount(0);
  await page.clock.runFor(3500);
  expect(await page.evaluate(id=>window.__acks.filter(value=>value.id===id && value.dismiss),id(3))).toEqual([]);
});
test("always-open preference still permits explicit close and re-opening",async({page})=>{
  await fixture(page,{collapseIdle:false});
  await page.goto("/?surface=widget");
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.getByRole("button",{name:"Close summary",exact:true}).click();
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","true");
  await page.locator("#notch").hover();
  await expect(page.getByRole("dialog")).toBeVisible();
});
test("native fullscreen folding finishes exposure for an always-open card",async({page})=>{
  await fixture(page,{collapseIdle:false},[3]);
  await page.setViewportSize({width:560,height:1000});
  await page.goto("/?surface=widget");
  await page.locator("#card").hover();
  await page.clock.runFor(1250);
  expect(await page.evaluate(()=>window.__acks.some(value=>value.id==="3".repeat(64) && !value.dismiss))).toBe(true);
  await page.evaluate(()=>window.__desktopExpansion({
    expanded:false,automatic:false,pinned:false,dismissed:true,visible:false,alert:null,until:0,
  }));
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","true");
  await expect.poll(()=>page.evaluate(()=>window.__acks.some(value=>value.id==="3".repeat(64) && value.dismiss))).toBe(true);
});
test("an older snapshot cannot reopen a card after a newer native fold",async({page})=>{
  await fixture(page,{},[]);
  await page.goto("/?surface=widget");
  await page.evaluate(()=>window.__desktopExpansion({expanded:true,automatic:false,pinned:false,dismissed:false,visible:true,alert:null,until:0,revision:5}));
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","false");
  await page.evaluate(()=>window.__desktopExpansion({expanded:false,automatic:false,pinned:false,dismissed:false,visible:true,alert:null,until:0,revision:6}));
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","true");
  // A refresh whose snapshot was read before the fold arrives afterwards.
  await page.evaluate(()=>{window.__desktopWidgetState={widgetExpanded:true,widgetVisible:true,widgetDismissed:false,widgetRevision:5};});
  await page.clock.runFor(3100);
  await expect(page.locator("#card")).toHaveAttribute("aria-hidden","true");
  await expect(page.locator("#notch")).toHaveAttribute("aria-expanded","false");
  // A snapshot carrying the fold's revision read at least that new a state and is applied.
  await page.evaluate(()=>{window.__desktopWidgetState={widgetExpanded:true,widgetVisible:true,widgetDismissed:false,widgetRevision:6};});
  await page.clock.runFor(3100);
  await expect(page.locator("#notch")).toHaveAttribute("aria-expanded","true");
  // An event repeating an already-applied revision is ignored.
  await page.evaluate(()=>window.__desktopExpansion({expanded:false,automatic:false,pinned:false,dismissed:false,visible:true,alert:null,until:0,revision:6}));
  await expect(page.locator("#notch")).toHaveAttribute("aria-expanded","true");
});
test("large text keeps card footer reachable and high-contrast/reduced-motion states accessible",async({page})=>{
  await fixture(page,{textScale:2,reduceMotion:true,reduceTransparency:true});
  await page.emulateMedia({forcedColors:"active",reducedMotion:"reduce"});
  await page.setViewportSize({width:360,height:360});
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  await expect(page.getByRole("dialog")).toBeVisible();
  expect(await page.locator(".ring-activity circle").evaluate(node=>window.getComputedStyle(node).animationName)).toBe("none");
  expect(await page.locator("#card-scroll").evaluate(node=>node.clientHeight)).toBeGreaterThan(0);
  const footer=await page.locator(".card-footer").boundingBox();
  expect(footer.y+footer.height).toBeLessThanOrEqual(360);
  const inaccessible=await page.locator("#card button").evaluateAll(buttons=>buttons.filter(button=>
    !button.getAttribute("aria-label") && !button.textContent.trim()).length);
  expect(inaccessible).toBe(0);
  await page.getByRole("button",{name:"Close summary",exact:true}).focus();
  await page.keyboard.press("Escape");
  await expect(page.locator("#notch")).toBeFocused();
});
test("working indicators rotate continuously across status refreshes and stop on idle",async({page})=>{
  await page.emulateMedia({reducedMotion:"no-preference"});
  await fixture(page,{},[]);
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  for (const selector of [".ring-activity circle",".session-row .icon.signal-working",".activity .icon.signal-working"]) {
    const indicator=page.locator(selector);
    const initial=await indicator.evaluate(node=>{
      const animation=node.getAnimations()[0];
      const style=window.getComputedStyle(node);
      return {time:animation?.currentTime,phase:style.rotate+style.transform};
    });
    expect(typeof initial.time).toBe("number");
    await expect.poll(()=>indicator.evaluate(node=>node.getAnimations()[0].currentTime)).toBeGreaterThan(initial.time+100);
    expect(await indicator.evaluate(node=>{
      const style=window.getComputedStyle(node);
      return style.rotate+style.transform;
    })).not.toBe(initial.phase);
  }
  const before=await page.locator(".session-row .icon.signal-working").evaluate(node=>{
    window.__oldSpinner=node;
    return node.getAnimations()[0].currentTime;
  });
  await page.evaluate(now=>{
    window.__desktopNow=now+2000;
    window.__desktopPrefs.scale=1.1;
  },now);
  await page.getByLabel("Usage source",{exact:true}).selectOption("cli");
  expect(await page.evaluate(()=>window.__oldSpinner.isConnected)).toBe(false);
  for (const selector of [".ring-activity circle",".session-row .icon.signal-working"]) {
    const animation=await page.locator(selector).evaluate(node=>({
      start:node.getAnimations()[0].startTime,time:node.getAnimations()[0].currentTime,
    }));
    expect(animation.start).toBe(0);
    expect(animation.time).toBeGreaterThanOrEqual(before);
  }
  await page.evaluate(()=>{window.__desktopPrefs.reduceMotion=true;});
  await page.getByLabel("Usage source",{exact:true}).selectOption("all");
  for (const selector of [".ring-activity circle",".session-row .icon.signal-working"]) {
    expect(await page.locator(selector).evaluate(node=>window.getComputedStyle(node).animationName)).toBe("none");
  }
  await page.evaluate(now=>{
    window.__desktopSessions=[{id:"f".repeat(64),source:"cli",kind:"idle",working:false,observedAt:now,label:"Idle",context:null}];
  },now);
  await page.getByLabel("Usage source",{exact:true}).selectOption("cli");
  await expect(page.locator(".ring-activity,.icon.signal-working")).toHaveCount(0);
});
test("Windows motion suppression no longer freezes transitions or working indicators",async({page})=>{
  await page.emulateMedia({reducedMotion:"reduce"});
  await fixture(page,{},[]);
  await page.addInitScript(()=>{
    window.__desktopAccessibility={textScale:1,animationsEnabled:false,transparencyEnabled:true};
  });
  await page.goto("/?page=general");
  await expect(page.locator("#visual-preferences")).toContainText("Windows animation effects are off");
  await expect(page.getByLabel("Reduce motion",{exact:false})).not.toBeChecked();
  await expect(page.locator("html")).not.toHaveAttribute("data-reduced-motion","");
  await expect(page.locator("html")).not.toHaveAttribute("data-reduced-status-motion","");
  await page.goto("/?surface=widget");
  await page.locator("#notch").hover();
  expect(await page.locator(".notch-cell").evaluate(node=>window.getComputedStyle(node).transitionDuration)).not.toBe("0s");
  for (const [selector,name] of [[".ring-activity circle","notch-spin"],[".session-row .icon.signal-working","session-spin"],[".activity .icon.signal-working","session-spin"]]) {
    const indicator=page.locator(selector);
    expect(await indicator.evaluate(node=>window.getComputedStyle(node).animationName)).toBe(name);
    const initial=await indicator.evaluate(node=>node.getAnimations()[0].currentTime);
    await expect.poll(()=>indicator.evaluate(node=>node.getAnimations()[0].currentTime)).toBeGreaterThan(initial+100);
  }
  // The arc orbits the Copilot glyph, as on macOS.
  for (let sample=0; sample<3; sample++) {
    const [arc,glyph]=await Promise.all([".ring-activity circle",".ring-glyph"].map(selector=>page.locator(selector).boundingBox()));
    expect(Math.abs(arc.x+arc.width/2-(glyph.x+glyph.width/2))).toBeLessThan(arc.width/2);
    expect(Math.abs(arc.y+arc.height/2-(glyph.y+glyph.height/2))).toBeLessThan(arc.height/2);
    await page.waitForTimeout(250);
  }
});
test("settings text and position controls remain usable without a pointer",async({page})=>{
  await page.goto("/?page=general");
  const slider=page.getByLabel("Position along edge",{exact:true});
  await slider.focus();
  await slider.press("End");
  await expect(slider).toHaveAttribute("aria-valuetext","100% along the right edge");
  await slider.press("Home");
  await expect(slider).toHaveAttribute("aria-valuetext","0% along the right edge");
  await page.getByLabel("Text size",{exact:false}).selectOption("2");
  await expect(page.locator("#visual-preferences")).toContainText("200%");
  expect(await page.locator('[data-view="general"] h1').evaluate(node=>parseFloat(window.getComputedStyle(node).fontSize))).toBe(44);
});
