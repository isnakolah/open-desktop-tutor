import {buildTutorEnvelope, unwrapNodePayload} from "./protocol.mjs";
import {retrieveLocalPacks} from "./local-retrieval.mjs";

const baseSessionProperty = {
  session_id: {type: "string", minLength: 8, description: "Opaque TutorHost teaching session id."},
};

const normalisedUnit = {type: "number", minimum: 0, maximum: 1};

// A vision hint says where to look, never where to click. Every value is
// normalised to the captured window, so it carries no pixel or screen
// coordinate, and TutorHost re-resolves the real bounds itself.
const targetHintProperty = {
  target_hint: {
    type: "object",
    additionalProperties: false,
    required: ["description", "region"],
    description:
      "Normalised search prior from a vision model. Never authorises an action; TutorHost re-resolves the target locally.",
    properties: {
      description: {type: "string", minLength: 1, maxLength: 200},
      region: {
        type: "object",
        additionalProperties: false,
        required: ["x", "y", "width", "height"],
        properties: {x: normalisedUnit, y: normalisedUnit, width: normalisedUnit, height: normalisedUnit},
      },
    },
  },
};

// The authored `resolve:` contract from the App Pack, forwarded verbatim so
// TutorHost carries no application-specific code.
const targetDescriptorProperty = {
  target_descriptor: {
    type: "object",
    additionalProperties: false,
    description: "Authored App Pack resolver contract for this semantic target.",
    properties: {
      semantic_id: {type: "string", minLength: 1, maxLength: 200},
      bundle_ids: {type: "array", items: {type: "string", maxLength: 255}, maxItems: 16},
      resolve: {
        type: "object",
        additionalProperties: false,
        properties: {
          bridge: {type: "object"},
          accessibility: {
            type: "object",
            additionalProperties: false,
            properties: {
              candidates: {
                type: "array",
                maxItems: 16,
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    role: {type: "string", maxLength: 80},
                    // Bounded: pack content is untrusted and this becomes a regex.
                    label_regex: {type: "string", maxLength: 200},
                    description_regex: {type: "string", maxLength: 200},
                  },
                },
              },
            },
          },
          visual: {type: "object"},
        },
      },
      disambiguate: {type: "object"},
      minimum_confidence: {
        type: "object",
        additionalProperties: false,
        properties: {point: normalisedUnit, act: normalisedUnit},
      },
    },
  },
};

const definitions = {
  tutor_observe: {
    label: "Tutor Observe",
    description: "Read a compact, redacted semantic state snapshot from the allowlisted desktop application.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id"],
      properties: {
        ...baseSessionProperty,
        requested_fields: {type: "array", items: {type: "string"}, maxItems: 32},
        include_crop: {type: "boolean", default: false},
      },
    },
  },
  tutor_retrieve: {
    label: "Tutor Retrieve",
    description: "Retrieve version-matched App Pack entities from the user's TutorHost knowledge store.",
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
    description: "Point the distinct AI cursor at a freshly resolved semantic target without moving the system cursor.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "semantic_target", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        ...targetDescriptorProperty,
        ...targetHintProperty,
        semantic_target: {type: "string", minLength: 1},
        snapshot_id: {type: "string", minLength: 1},
        label: {type: "string", maxLength: 120},
        step: {type: "string", maxLength: 60},
      },
    },
  },
  tutor_propose_action: {
    label: "Tutor Propose Action",
    description: "Propose one bounded semantic action for local approval, execution, and verification. Never accepts raw coordinates.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "action", "semantic_target", "snapshot_id", "expected_state", "rationale"],
      properties: {
        ...baseSessionProperty,
        // Deliberately no target_hint: a model hint can never authorise an action.
        ...targetDescriptorProperty,
        action: {enum: ["move_cursor", "click", "scroll", "keyboard_shortcut", "type_text"]},
        semantic_target: {type: "string", minLength: 1},
        snapshot_id: {type: "string", minLength: 1},
        expected_state: {type: "object"},
        rationale: {type: "string", minLength: 1, maxLength: 500},
        value: {type: "string", maxLength: 2000},
      },
    },
  },
  tutor_verify: {
    label: "Tutor Verify",
    description: "Evaluate an authored expectation against fresh stable local state.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "expectation_id"],
      properties: {
        ...baseSessionProperty,
        expectation_id: {type: "string", minLength: 1},
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
