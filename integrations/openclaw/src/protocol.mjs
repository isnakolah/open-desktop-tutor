import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";

import {validateDetectorDescriptor, validateTargetDescriptor} from "./descriptors.mjs";

export const PROTOCOL_VERSION = 2;
export const NODE_COMMAND = "desktop-tutor.host";
export const CALLA_ROLES = Object.freeze(["gateway", "node", "both"]);
export const TUTOR_TOOL_NAMES = Object.freeze([
  "tutor_observe",
  "tutor_retrieve",
  "tutor_guide",
  "tutor_await_change",
  "tutor_narrate",
  "tutor_point",
  "tutor_propose_action",
  "tutor_verify",
]);

const TOOL_TO_OPERATION = Object.freeze({
  tutor_observe: "observe",
  tutor_retrieve: "retrieve",
  tutor_guide: "guide",
  tutor_await_change: "await_change",
  tutor_narrate: "narrate",
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
  "left",
  "top",
  "width",
  "height",
  "bounds",
  "frame",
]);

function requireString(value, name, minimum = 1) {
  if (typeof value !== "string" || value.trim().length < minimum) {
    throw new TypeError(`${name} must be a string of at least ${minimum} characters`);
  }
  return value.trim();
}

/**
 * @param exemptRegionPath the one path, relative to the payload, at which a
 *   normalized region may appear: `["target_hint", "region"]` for pointing and
 *   `["region"]` for guiding. Everywhere else a coordinate-shaped key is a
 *   rejection, and no exemption is ever granted to an operation that can act.
 */
export function findForbiddenCoordinatePath(value, path = [], exemptRegionPath = null) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findForbiddenCoordinatePath(value[index], [...path, String(index)], exemptRegionPath);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  for (const [key, child] of Object.entries(value)) {
    const next = [...path, key];
    if (exemptRegionPath && next.length === exemptRegionPath.length && next.every((part, index) => part === exemptRegionPath[index])) {
      continue;
    }
    if (FORBIDDEN_COORDINATE_KEYS.has(key.toLowerCase())) return next.join(".");
    const found = findForbiddenCoordinatePath(child, next, exemptRegionPath);
    if (found) return found;
  }
  return null;
}

/** Where each tool is allowed to carry its one normalized region, if at all. */
export function exemptRegionPath(toolName, params) {
  if (toolName === "tutor_point" && params?.target_hint !== undefined) return ["target_hint", "region"];
  if (toolName === "tutor_guide") return ["region"];
  return null;
}

export function validateNormalizedRegion(region, name = "region") {
  if (!region || typeof region !== "object" || Array.isArray(region) || Object.keys(region).length !== 4) {
    throw new TypeError(`${name} must contain left, top, width, and height only`);
  }
  for (const field of ["left", "top", "width", "height"]) {
    if (typeof region[field] !== "number" || !Number.isFinite(region[field])) {
      throw new TypeError(`${name}.${field} must be a finite normalized number`);
    }
  }
  if (region.left < 0 || region.top < 0 || region.width <= 0 || region.height <= 0 || region.left + region.width > 1 || region.top + region.height > 1) {
    throw new TypeError(`${name} must be in [0,1], have positive size, and remain inside the focused window`);
  }
  return region;
}

export function validateNormalizedTargetHint(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length !== 1) {
    throw new TypeError("target_hint must contain a region only");
  }
  validateNormalizedRegion(value.region, "target_hint.region");
  return value;
}

function validateSnapshot(value, name = "snapshot_id") {
  return requireString(value, name);
}

export function validateToolPayload(toolName, payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new TypeError("tool parameters must be an object");
  if (toolName === "tutor_observe") {
    if (payload.include_capture !== undefined && typeof payload.include_capture !== "boolean") {
      throw new TypeError("include_capture must be a boolean");
    }
    if (Object.hasOwn(payload, "include_crop")) throw new TypeError("include_crop was replaced by include_capture in protocol v2");
  }
  if (toolName === "tutor_guide") {
    validateNormalizedRegion(payload.region);
    validateSnapshot(payload.snapshot_id);
    requireString(payload.text, "text");
    if (Object.hasOwn(payload, "target_descriptor")) {
      throw new TypeError("tutor_guide never carries a descriptor; it points at what the model saw in the capture");
    }
  }
  if (toolName === "tutor_await_change") {
    validateSnapshot(payload.snapshot_id);
  }
  if (toolName === "tutor_narrate") {
    requireString(payload.text, "text");
  }
  if (toolName === "tutor_point") {
    validateTargetDescriptor(payload.target_descriptor);
    validateSnapshot(payload.snapshot_id);
    if (payload.target_hint !== undefined) validateNormalizedTargetHint(payload.target_hint);
  }
  if (toolName === "tutor_propose_action") {
    if (Object.hasOwn(payload, "target_hint")) throw new TypeError("tutor_propose_action never accepts target_hint");
    validateTargetDescriptor(payload.target_descriptor);
    validateDetectorDescriptor(payload.expected_state);
    validateSnapshot(payload.snapshot_id);
  }
  if (toolName === "tutor_verify") {
    validateTargetDescriptor(payload.target_descriptor);
    validateDetectorDescriptor(payload.detector_descriptor);
    validateSnapshot(payload.snapshot_id);
  }
  const forbidden = findForbiddenCoordinatePath(payload, [], exemptRegionPath(toolName, payload));
  if (forbidden) throw new TypeError(`raw coordinate field ${forbidden} is forbidden; use an App-Pack descriptor`);
  return payload;
}

export function buildTutorEnvelope(toolName, params) {
  const operation = TOOL_TO_OPERATION[toolName];
  if (!operation) throw new TypeError(`unsupported tutor tool: ${toolName}`);
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    throw new TypeError("tool parameters must be an object");
  }
  const sessionId = requireString(params.session_id, "session_id", 8);
  const payload = {...params};
  delete payload.session_id;
  validateToolPayload(toolName, payload);
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
    throw new TypeError("protocol_version must be 2");
  }
  requireString(value.request_id, "request_id", 8);
  requireString(value.session_id, "session_id", 8);
  if (!Object.values(TOOL_TO_OPERATION).includes(value.operation)) {
    throw new TypeError(`unsupported operation: ${String(value.operation)}`);
  }
  const toolName = Object.entries(TOOL_TO_OPERATION).find(([, operation]) => operation === value.operation)?.[0];
  if (!toolName) throw new TypeError(`unsupported operation: ${String(value.operation)}`);
  validateToolPayload(toolName, value.payload);
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
