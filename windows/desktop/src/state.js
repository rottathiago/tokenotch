const edges = new Set(["top", "right", "bottom", "left"]);

export function validateStatus(value) {
  if (!value || typeof value !== "object" ||
      typeof value.version !== "string" || !/^\d+\.\d+\.\d+$/.test(value.version) ||
      !["development", "release"].includes(value.channel) || typeof value.connectionsEnabled !== "boolean" ||
      !edges.has(value.edge) || typeof value.widgetVisible !== "boolean" ||
      !Number.isInteger(value.minimumWindowsBuild) || value.minimumWindowsBuild < 22000 ||
      !value.runtime || typeof value.runtime.platform !== "string" ||
      typeof value.runtime.executableArchitecture !== "string" ||
      !(value.runtime.windowsBuild === null ||
        Number.isInteger(value.runtime.windowsBuild) && value.runtime.windowsBuild > 0)) {
    throw new Error("Tokenotch returned an unsupported application status. Restart the app.");
  }
  return value;
}

export function runtimeDescription(status) {
  const { platform, executableArchitecture, windowsBuild } = status.runtime;
  if (platform === "browser") {
    return "Browser preview. Window controls here do not change your desktop.";
  }
  if (platform !== "windows") {
    return "Development host only. This does not verify Windows compatibility.";
  }
  const architecture = { x86_64: "x64", aarch64: "ARM64" }[executableArchitecture];
  if (!architecture || windowsBuild === null) {
    return "Windows architecture or build is unavailable. Native acceptance is required.";
  }
  return `Windows build ${windowsBuild}. ${architecture} executable; native OS architecture must be verified separately.`;
}

export function validateEdge(edge) {
  if (!edges.has(edge)) throw new Error("Choose a supported screen edge.");
  return edge;
}

export function exposureAllowed({ engaged, expanded, visible, automatic, interacted }) {
  return engaged && expanded && visible && (!automatic || interacted);
}
