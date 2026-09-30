import "./styles.css";
import mark from "../../../sources/Resources/Brand/TokenotchMarkDark.png";
import { bridge } from "./bridge.js";
import { product } from "./product.js";
import { runtimeDescription } from "./state.js";

const app = document.querySelector("#app");
const widget = new URLSearchParams(window.location.search).get("surface") === "widget";
let actions = Promise.resolve();

function action(operation) {
  actions = actions.then(operation).catch((error) => {
    const output = document.querySelector("#error");
    output.hidden = false;
    output.textContent = typeof error === "string" ? error :
      error instanceof Error ? error.message : "The operation failed. Restart Tokenotch and retry.";
  });
  return actions;
}

function decorateBrand() {
  for (const image of document.querySelectorAll("[data-brand]")) image.src = mark;
  for (const version of document.querySelectorAll("[data-version]")) version.textContent = product.version;
}

if (widget) {
  document.body.classList.add("widget-surface");
  app.innerHTML = `
    <section class="edge-widget" aria-label="Tokenotch activity">
      <button class="widget-mark" type="button" aria-label="Open Tokenotch settings">
        <img data-brand alt="" width="36" height="36">
        <span class="offline-dot" aria-hidden="true"></span>
      </button>
      <div class="widget-content">
        <strong>Tokenotch</strong><span class="build-label">Development</span>
        <h1>No connections yet</h1>
        <p>This build checks the Windows desktop experience. It does not collect usage.</p>
        <button id="open-settings" type="button">Open settings</button>
      </div>
      <p id="error" class="error" role="alert" hidden></p>
    </section>`;
  const panel = document.querySelector(".edge-widget");
  panel.addEventListener("mouseenter", () => action(async () => {
    await bridge.setExpanded(true);
    panel.classList.add("expanded");
  }));
  panel.addEventListener("mouseleave", () => action(async () => {
    panel.classList.remove("expanded");
    await bridge.setExpanded(false);
  }));
  for (const button of panel.querySelectorAll("button")) {
    button.addEventListener("click", () => action(() => bridge.openSettings()));
  }
} else {
  app.innerHTML = `
    <div class="app-shell">
      <aside class="sidebar">
        <div class="brand"><img data-brand alt="" width="44" height="44"><strong>Tokenotch</strong></div>
        <nav aria-label="Settings sections">
          <button type="button" data-page="connections" aria-current="page">Connections</button>
          <button type="button" data-page="appearance">Appearance</button>
          <button type="button" data-page="about">About</button>
        </nav>
        <div class="sidebar-note"><span class="build-label">Development</span><p>Windows foundation<br><span data-version></span></p></div>
      </aside>
      <main>
        <p id="error" class="error" role="alert" hidden></p>
        <section data-view="connections">
          <header><h1>Connections</h1><p>Keep your coding activity in view, without keeping its content.</p></header>
          <div class="notice"><span class="status-dot" aria-hidden="true"></span><div><h2>Not collecting usage</h2>
            <p>This is a desktop feasibility build. Secure Windows connections are not enabled yet.
            Your Copilot settings and credentials are left untouched.</p></div></div>
          <div class="connection-row"><div><h2>Copilot CLI</h2><p>Live sessions, models and token usage</p></div><span class="state-label">Not available yet</span></div>
          <div class="connection-row"><div><h2>Visual Studio Code</h2><p>Local lifecycle and optional model usage</p></div><span class="state-label">Planned for beta</span></div>
          <p class="privacy-note">No hooks installed. No local receiver. No history saved.<br>
            Missing observations are unavailable, not zero.</p>
        </section>
        <section data-view="appearance" hidden>
          <header><h1>Appearance</h1><p>A small presence at the edge of your screen.</p></header>
          <div class="display-preview" aria-hidden="true"><div class="preview-taskbar"></div><div id="preview-widget" data-edge="right"><img data-brand alt="" width="30" height="30"></div></div>
          <div class="control-row"><label for="edge">Screen edge<span>Position the activity widget on this display.</span></label>
            <select id="edge"><option value="right">Right</option><option value="left">Left</option><option value="top">Top</option><option value="bottom">Bottom</option></select></div>
          <div class="control-row"><label for="show-widget">Show activity widget<span>Settings remain available from the tray.</span></label><input id="show-widget" type="checkbox" checked></div>
          <p class="privacy-note">Placement is session-only in this build. Display recovery, fullscreen hiding
            and saved preferences still require Windows implementation and acceptance.</p>
        </section>
        <section data-view="about" hidden>
          <header><h1>Tokenotch for Windows</h1><p>Visibility into your AI coding usage and patterns.</p></header>
          <dl class="about-list"><dt>Product version</dt><dd data-version></dd><dt>Distribution</dt><dd>Unsigned development build</dd><dt>Targets</dt><dd>Windows 11 x64 and native ARM64</dd><dt>Desktop</dt><dd>Rust, Tauri 2 and JavaScript</dd></dl>
          <div class="notice"><div><h2>Not a supported Windows release</h2><p>The app and helper still need native Windows validation. Compilation and browser previews do not establish live client compatibility.</p></div></div>
          <p class="privacy-note">Independent of GitHub and Microsoft. Existing MIT notices are included with the app.</p>
        </section>
        <footer><p id="runtime" role="status">Checking application status...</p><button id="refresh" type="button">Refresh status</button></footer>
      </main>
    </div>`;
  for (const button of document.querySelectorAll("[data-page]")) {
    button.addEventListener("click", () => {
      for (const item of document.querySelectorAll("[data-page]")) item.removeAttribute("aria-current");
      button.setAttribute("aria-current", "page");
      for (const view of document.querySelectorAll("[data-view]")) {
        view.hidden = view.dataset.view !== button.dataset.page;
      }
    });
  }
  const refresh = async () => {
    const status = await bridge.status();
    document.querySelector("#runtime").textContent = runtimeDescription(status);
    document.querySelector("#edge").value = status.edge;
    document.querySelector("#show-widget").checked = status.widgetVisible;
    document.querySelector("#preview-widget").dataset.edge = status.edge;
    document.querySelector("#preview-widget").hidden = !status.widgetVisible;
  };
  document.querySelector("#edge").addEventListener("change", (event) => action(async () => {
    await bridge.setEdge(event.target.value);
    await refresh();
  }));
  document.querySelector("#show-widget").addEventListener("change", (event) => action(async () => {
    await bridge.setVisible(event.target.checked);
    await refresh();
  }));
  document.querySelector("#refresh").addEventListener("click", () => action(refresh));
  action(refresh);
}
decorateBrand();
