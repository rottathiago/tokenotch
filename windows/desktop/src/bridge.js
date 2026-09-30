import { invoke, isTauri } from "@tauri-apps/api/core";
import { product } from "./product.js";
import { validateEdge, validateStatus } from "./state.js";

const native = isTauri();
let previewEdge = "right";
let previewVisible = true;

export const bridge = {
  native,
  async status() {
    return validateStatus(native ? await invoke("runtime_status") : {
      version: product.version,
      channel: "development",
      runtime: { platform: "browser", executableArchitecture: "not-applicable", windowsBuild: null },
      minimumWindowsBuild: product.minimumWindowsBuild,
      connectionsEnabled: false,
      edge: previewEdge,
      widgetVisible: previewVisible,
    });
  },
  async setEdge(edge) {
    validateEdge(edge);
    if (native) await invoke("set_edge", { edge });
    else previewEdge = edge;
  },
  async setVisible(visible) {
    if (typeof visible !== "boolean") throw new Error("Widget visibility must be a Boolean.");
    if (native) await invoke("set_widget_visible", { visible });
    else previewVisible = visible;
  },
  async setExpanded(expanded) {
    if (native) await invoke("set_expanded", { expanded });
  },
  async openSettings() {
    if (native) await invoke("open_settings");
    else window.location.search = "";
  },
};
