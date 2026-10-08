import test from "node:test";
import assert from "node:assert/strict";
import { exposureAllowed } from "../../desktop/src/state.js";

test("automatic card visibility alone never acknowledges a notice", () => {
  const state = {engaged:true,expanded:true,visible:true,automatic:true,interacted:false};
  assert.equal(exposureAllowed(state),false);
  assert.equal(exposureAllowed({...state,interacted:true}),true);
  assert.equal(exposureAllowed({...state,automatic:false}),true);
  for (const field of ["engaged","expanded","visible"]) {
    assert.equal(exposureAllowed({...state,interacted:true,[field]:false}),false);
  }
});
