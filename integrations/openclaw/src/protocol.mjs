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

const HINT_REGION_KEYS = Object.freeze(["x", "y", "width", "height"]);
const MAX_HINT_DESCRIPTION = 200;

/**
 * A vision model may suggest *where to look* but never *where to click*. A hint
 * is therefore normalised to the captured window (0..1), carries no pixel or
 * screen coordinate, and is accepted only by tutor_point. The Mac re-resolves
 * the real bounds itself, so this stays a search prior rather than an
 * instruction.
 */
export function validateNormalisedHint(hint) {
  if (!hint || typeof hint !== "object" || Array.isArray(hint)) {
    throw new TypeError("target_hint must be an object");
  }
  const description = requireString(hint.description, "target_hint.description");
  if (description.length > MAX_HINT_DESCRIPTION) {
    throw new TypeError(`target_hint.description must be ${MAX_HINT_DESCRIPTION} characters or fewer`);
  }
  const region = hint.region;
  if (!region || typeof region !== "object" || Array.isArray(region)) {
    throw new TypeError("target_hint.region must be an object");
  }
  const keys = Object.keys(region);
  if (keys.length !== HINT_REGION_KEYS.length || !HINT_REGION_KEYS.every((key) => keys.includes(key))) {
    throw new TypeError("target_hint.region must contain exactly x, y, width and height");
  }
  for (const key of HINT_REGION_KEYS) {
    const value = region[key];
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) {
      throw new TypeError(`target_hint.region.${key} must be a number between 0 and 1`);
    }
  }
  if (region.width <= 0 || region.height <= 0) {
    throw new TypeError("target_hint.region must have a positive width and height");
  }
  if (region.x + region.width > 1 || region.y + region.height > 1) {
    throw new TypeError("target_hint.region must stay inside the captured window");
  }
  return {
    description,
    region: {x: region.x, y: region.y, width: region.width, height: region.height},
  };
}

/** The hint is validated separately, so exclude it from the coordinate scan
 *  rather than weakening the scan itself. */
function withoutHint(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const {target_hint: _ignored, ...rest} = value;
  return rest;
}

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
  let hint = null;
  if (params.target_hint !== undefined) {
    if (toolName !== "tutor_point") {
      throw new TypeError("target_hint is accepted only by tutor_point; a hint can never authorise an action");
    }
    hint = validateNormalisedHint(params.target_hint);
  }
  const forbidden = findForbiddenCoordinatePath(withoutHint(params));
  if (forbidden) {
    throw new TypeError(`raw coordinate field ${forbidden} is forbidden; use semantic_target`);
  }
  const sessionId = requireString(params.session_id, "session_id", 8);
  const payload = {...params};
  delete payload.session_id;
  if (hint) payload.target_hint = hint;
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
  const payload = value.payload;
  if (payload && typeof payload === "object" && payload.target_hint !== undefined) {
    if (value.operation !== "point") {
      throw new TypeError("target_hint is accepted only by the point operation");
    }
    validateNormalisedHint(payload.target_hint);
  }
  const forbidden = findForbiddenCoordinatePath(withoutHint(payload));
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
