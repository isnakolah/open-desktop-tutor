import {findForbiddenCoordinatePath, TUTOR_TOOL_NAMES, validateNormalizedTargetHint} from "./protocol.mjs";

const TUTOR_TOOLS = new Set(TUTOR_TOOL_NAMES);

export function createBeforeToolCallPolicy(config) {
  return async (event, context) => {
    if (!TUTOR_TOOLS.has(event.toolName)) return undefined;

    if (config.requireOwnerIdentity && context?.requester?.senderIsOwner !== true) {
      return {
        block: true,
        blockReason: "Desktop Tutor tools require a host-verified owner requester identity.",
      };
    }

    if (event.toolName === "tutor_point" && event.params?.target_hint !== undefined) {
      try {
        validateNormalizedTargetHint(event.params.target_hint);
      } catch (error) {
        return {block: true, blockReason: error.message};
      }
    }
    const coordinatePath = findForbiddenCoordinatePath(
      event.params,
      [],
      event.toolName === "tutor_point" && event.params?.target_hint !== undefined,
    );
    if (coordinatePath) {
      return {
        block: true,
        blockReason: `Raw coordinate field ${coordinatePath} is forbidden; resolve a semantic target locally.`,
      };
    }

    if (event.toolName === "tutor_propose_action") {
      if (Object.hasOwn(event.params || {}, "target_hint")) {
        return {
          block: true,
          blockReason: "tutor_propose_action never accepts a model target_hint; local evidence is required.",
        };
      }
      const action = typeof event.params?.action === "string" ? event.params.action : "unknown";
      const target =
        typeof event.params?.target_descriptor?.id === "string" ? event.params.target_descriptor.id : "unknown target";
      return {
        requireApproval: {
          title: `Tutor action: ${action}`,
          description: `Allow one bounded ${action} on semantic target ${target}. TutorHost will resolve and approve it again locally.`,
          severity: action === "move_cursor" ? "info" : "warning",
          timeoutMs: 30_000,
          timeoutReason: "Tutor action approval timed out; no action was sent to the Mac.",
          allowedDecisions: ["allow-once", "deny"],
        },
      };
    }

    return undefined;
  };
}
