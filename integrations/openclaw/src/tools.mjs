import {buildTutorEnvelope, unwrapNodePayload} from "./protocol.mjs";
import {requireCanonicalDescriptor, requirePackAuthorizedAction, retrieveLocalPacks} from "./local-retrieval.mjs";

const baseSessionProperty = {
  session_id: {type: "string", minLength: 8, description: "Opaque TutorHost teaching session id."},
};

const definitions = {
  tutor_observe: {
    label: "Tutor Observe",
    description: "Read a compact semantic state snapshot. With include_capture true, returns only the focused allowlisted window as an in-memory JPEG bound to snapshot_id; never request a display capture.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id"],
      properties: {
        ...baseSessionProperty,
        requested_fields: {type: "array", items: {type: "string"}, maxItems: 32},
        include_capture: {type: "boolean", default: false},
      },
    },
  },
  tutor_retrieve: {
    label: "Tutor Retrieve",
    description: "Retrieve version-matched App Pack entities from the user's TutorHost knowledge store. Preserve a returned target_descriptor or detector_descriptor verbatim for later calls.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "query", "application"],
      properties: {
        ...baseSessionProperty,
        query: {type: "string", minLength: 1, maxLength: 1000},
        application: {
          type: "object",
          additionalProperties: false,
          required: ["bundle_id", "version"],
          properties: {
            bundle_id: {type: "string", minLength: 1, maxLength: 255},
            version: {type: "string", minLength: 1, maxLength: 80},
            platform: {enum: ["macos", "windows", "linux"], default: "macos"},
            locale: {type: "string", minLength: 2, maxLength: 20},
          },
        },
        entity_types: {type: "array", items: {type: "string"}, maxItems: 16},
        limit: {type: "integer", minimum: 1, maximum: 20, default: 5},
      },
    },
  },
  tutor_point: {
    label: "Tutor Point",
    description: "Point the distinct AI cursor at a freshly resolved canonical target_descriptor without moving the system cursor. After capture, a vision model may provide only target_hint.region normalized to the focused window; it is a local search prior, not authority.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "target_descriptor", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        target_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
        target_hint: {
          type: "object",
          additionalProperties: false,
          required: ["region"],
          properties: {
            region: {
              type: "object",
              additionalProperties: false,
              required: ["left", "top", "width", "height"],
              properties: {
                left: {type: "number", minimum: 0, maximum: 1},
                top: {type: "number", minimum: 0, maximum: 1},
                width: {type: "number", exclusiveMinimum: 0, maximum: 1},
                height: {type: "number", exclusiveMinimum: 0, maximum: 1},
              },
            },
          },
        },
        label: {type: "string", maxLength: 120},
      },
    },
  },
  tutor_propose_action: {
    label: "Tutor Propose Action",
    description: "Propose one bounded semantic action using the same canonical target_descriptor and a canonical expected_state detector. Never accepts target_hint or raw coordinates; TutorHost requires independent local evidence and one-shot approval.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "action", "target_descriptor", "snapshot_id", "expected_state", "rationale"],
      properties: {
        ...baseSessionProperty,
        action: {enum: ["move_cursor", "click", "scroll", "keyboard_shortcut", "type_text"]},
        target_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
        expected_state: {type: "object"},
        rationale: {type: "string", minLength: 1, maxLength: 500},
        value: {type: "string", maxLength: 2000},
      },
    },
  },
  tutor_verify: {
    label: "Tutor Verify",
    description: "Evaluate a canonical detector_descriptor against a freshly locally resolved canonical target_descriptor.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "target_descriptor", "detector_descriptor", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        target_descriptor: {type: "object"},
        detector_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
      },
    },
  },
};

function jsonResult(payload) {
  return {
    content: [{type: "text", text: JSON.stringify(payload, null, 2)}],
    details: payload,
  };
}

export function createTutorTools(api, config) {
  return Object.entries(definitions).map(([name, definition]) => ({
    name,
    ...definition,
    async execute(_toolCallId, params) {
      const envelope = buildTutorEnvelope(name, params);
      if (name === "tutor_retrieve") {
        return jsonResult(await retrieveLocalPacks(config, envelope.payload));
      }
      if (name === "tutor_point") {
        envelope.payload.target_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
      }
      if (name === "tutor_propose_action") {
        const target = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
        const detector = await requireCanonicalDescriptor(
          config, envelope.payload.expected_state, "detector", "expected_state");
        await requirePackAuthorizedAction(config, envelope.payload.action, target, detector);
        envelope.payload.target_descriptor = target;
        envelope.payload.expected_state = detector;
      }
      if (name === "tutor_verify") {
        envelope.payload.target_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
        envelope.payload.detector_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.detector_descriptor, "detector", "detector_descriptor");
      }
      if (!config.nodeId) {
        throw new Error(
          "desktop-tutor is not configured: set plugins.entries.desktop-tutor.config.nodeId to the paired Mac node id",
        );
      }
      const invoked = await api.runtime.nodes.invoke({
        nodeId: config.nodeId,
        command: "desktop-tutor.host",
        params: envelope,
        timeoutMs: config.timeoutMs,
      });
      return jsonResult(unwrapNodePayload(invoked));
    },
  }));
}
