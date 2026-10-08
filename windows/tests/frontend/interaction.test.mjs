import test from "node:test";
import assert from "node:assert/strict";
import { NoticeExposure, visibleFraction, visualPreferences } from "../../desktop/src/interaction.js";

const row = (id = "request", fraction = 1, kind = "inputRequested") => ({id,fraction,kind,viewed:false,dismissed:false,resolved:false});
test("notices are viewed after continuous dwell and stay until the card closes", () => {
  const tracker=new NoticeExposure();
  assert.deepEqual(tracker.update(0,[row()],true),[]);
  for (let at=250;at<1000;at+=250) assert.deepEqual(tracker.update(at,[row()],true),[]);
  assert.deepEqual(tracker.update(1000,[row()],true),[{id:"request",dismiss:false}]);
  for (let at=1250;at<=5000;at+=250) assert.deepEqual(tracker.update(at,[row()],true),[]);
  assert.deepEqual(tracker.finish(),[{id:"request",dismiss:true}]);
  assert.deepEqual(tracker.finish(),[]);
});
test("closing dismisses seen requests and errors but only views stopped notices", () => {
  const tracker=new NoticeExposure();
  const rows=[row("request"),row("error",1,"error"),row("stop",1,"stopped"),row("unseen",0.2,"approvalRequested")];
  tracker.update(0,rows,true);
  tracker.update(250,rows,true);
  tracker.update(500,rows,true);
  tracker.update(750,rows,true);
  assert.deepEqual(tracker.update(1000,rows,true).map(due => due.id),["request","error","stop"]);
  tracker.clear();
  tracker.update(1250,[],false);
  assert.deepEqual(tracker.finish(),[{id:"request",dismiss:true},{id:"error",dismiss:true}]);
});
test("scrolled-away and removed rows cannot accumulate exposure or be acknowledged on exit", () => {
  const tracker=new NoticeExposure();
  tracker.update(0,[row("old")],true);
  tracker.update(250,[row("old")],true);
  assert.deepEqual(tracker.update(500,[row("new")],true,true),[]);
  assert.equal(tracker.rows.has("old"),false);
  tracker.update(750,[row("new",0.49)],true);
  assert.deepEqual(tracker.update(1000,[row("new")],true,true),[]);
  tracker.update(1250,[row("new")],true);
  assert.deepEqual(tracker.update(1500,[row("new")],true,true),[{id:"new",dismiss:false}]);
  assert.deepEqual(tracker.finish(),[{id:"new",dismiss:true}]);
});
test("hidden windows, clock reversals and missed sampling reset dwell", () => {
  const tracker=new NoticeExposure();
  tracker.update(0,[row()],true);
  tracker.update(250,[row()],true);
  tracker.update(500,[row()],false);
  assert.deepEqual(tracker.update(750,[row()],true,true),[]);
  assert.deepEqual(tracker.update(2000,[row()],true),[]);
  assert.deepEqual(tracker.update(1500,[row()],true,true),[]);
  assert.equal(tracker.rows.get("request").began,1500);
});
test("scroll clipping and the exact 50 percent threshold use intersections, not the viewport alone", () => {
  const rect={left:10,top:10,right:110,bottom:110,width:100,height:100};
  assert.equal(visibleFraction(rect,[{left:0,top:0,right:200,bottom:60}]),0.5);
  assert.equal(visibleFraction(rect,[{left:0,top:0,right:200,bottom:59}]),0.49);
  assert.equal(visibleFraction(rect,[{left:0,top:0,right:200,bottom:200},{left:110,top:0,right:200,bottom:200}]),0);
});
test("OS visual settings combine text and transparency, but motion follows only Tokenotch's toggle", () => {
  const value=visualPreferences({preferences:{textScale:1.5,reduceMotion:false,reduceTransparency:true},
    accessibility:{textScale:1.25,animationsEnabled:false,transparencyEnabled:true}});
  assert.deepEqual(value,{textScale:1.875,reduceMotion:false,reduceStatusMotion:false,reduceTransparency:true});
  assert.deepEqual(visualPreferences({preferences:{reduceMotion:true},accessibility:{animationsEnabled:true}}),
    {textScale:1,reduceMotion:true,reduceStatusMotion:true,reduceTransparency:false});
  assert.throws(()=>visualPreferences({preferences:{textScale:NaN}}),/Unsupported/);
});
