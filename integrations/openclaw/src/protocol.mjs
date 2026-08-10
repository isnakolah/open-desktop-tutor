import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";

export const PROTOCOL_VERSION = 1;
export const NODE_COMMAND = "desktop-tutor.host";
export const CALLA_ROLES = Object.freeze(["gateway", "node", "both"]);
export const TUTOR_TOOL_NAMES = Object.freeze([
  "tutor_observe",
  "tutor_retrieve",
  "tutor_point",
  "tutor_propose_action",
  "tutor_verify",
]);

const TOOL_TO_OPERATION = Object.freeze({
  tutor_observe: "observe",
  tutor_retrieve: "retrieve",
  tutor_point: "point",
  tutor_propose_action: "propose_action",
  tutor_verify: "verify",
});

const FORBIDDEN_COORDINATE_KEYS = new Set([
  "x",
  "y",
  "coordinate",
  "coordinates",
  "screen_x",
  "screen_y",
]);

function requireString(value, name, minimum = 1) {
  if (typeof value !== "string" || value.trim().length < minimum) {
    throw new TypeError(`${name} must be a string of at least ${minimum} characters`);
  }
  return value.trim();
}

export function findForbiddenCoordinatePath(value, path = []) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findForbiddenCoordinatePath(value[index], [...path, String(index)]);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  for (const [key, child] of Object.entries(value)) {
    const next = [...path, key];
    if (FORBIDDEN_COORDINATE_KEYS.has(key.toLowerCase())) return next.join(".");
    const found = findForbiddenCoordinatePath(child, next);
    if (found) return found;
  }
  return null;
}

export function buildTutorEnvelope(toolName, params) {
  const operation = TOOL_TO_OPERATION[toolName];
  if (!operation) throw new TypeError(`unsupported tutor tool: ${toolName}`);
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    throw new TypeError("tool parameters must be an object");
  }
  const forbidden = findForbiddenCoordinatePath(params);
  if (forbidden) {
    throw new TypeError(`raw coordinate field ${forbidden} is forbidden; use semantic_target`);
  }
  const sessionId = requireString(params.session_id, "session_id", 8);
  const payload = {...params};
  delete payload.session_id;
  return {
    protocol_version: PROTOCOL_VERSION,
    request_id: randomUUID(),
    operation,
    session_id: sessionId,
    payload,
  };
}

export function validateNodeEnvelope(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("node request must be an object");
  }
  if (value.protocol_version !== PROTOCOL_VERSION) {
    throw new TypeError("protocol_version must be 1");
  }
  requireString(value.request_id, "request_id", 8);
  requireString(value.session_id, "session_id", 8);
  if (!Object.values(TOOL_TO_OPERATION).includes(value.operation)) {
    throw new TypeError(`unsupported operation: ${String(value.operation)}`);
  }
  const forbidden = findForbiddenCoordinatePath(value.payload);
  if (forbidden) throw new TypeError(`raw coordinate field payload.${forbidden} is forbidden`);
  return value;
}

export function parsePluginConfig(raw) {
  const config = raw && typeof raw === "object" ? raw : {};
  const role = typeof config.role === "string" ? config.role.trim().toLowerCase() : "gateway";
  if (!CALLA_ROLES.includes(role)) {
    throw new TypeError("desktop-tutor role must be gateway, node, or both");
  }
  if (role === "both" && config.developmentMode !== true) {
    throw new TypeError("desktop-tutor role both is development-only; set developmentMode to true explicitly");
  }
  const nodeId =
    typeof config.nodeId === "string" && config.nodeId.trim() ? config.nodeId.trim() : null;
  const timeoutMs = Number.isSafeInteger(config.timeoutMs) ? config.timeoutMs : 10_000;
  if (timeoutMs < 1_000 || timeoutMs > 30_000) {
    throw new TypeError("desktop-tutor timeoutMs must be between 1000 and 30000");
  }
  const configuredStateDirectory =
    typeof config.stateDirectory === "string" && config.stateDirectory.trim()
      ? config.stateDirectory.trim()
      : "~/.openclaw/calla";
  const stateDirectory = expandHomeDirectory(configuredStateDirectory);
  return {
    role,
    nodeId,
    socketPath:
      typeof config.socketPath === "string" && config.socketPath.trim()
        ? config.socketPath.trim()
        : null,
    timeoutMs,
    requireOwnerIdentity: config.requireOwnerIdentity === true,
    stateDirectory,
    developmentMode: config.developmentMode === true,
  };
}

function expandHomeDirectory(value) {
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

export function unwrapNodePayload(result) {
  if (result && typeof result === "object" && result.payload !== undefined) return result.payload;
  if (result && typeof result === "object" && typeof result.payloadJSON === "string") {
    return JSON.parse(result.payloadJSON);
  }
  return result;
}
