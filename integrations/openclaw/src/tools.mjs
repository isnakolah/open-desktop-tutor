import {buildTutorEnvelope, unwrapNodePayload} from "./protocol.mjs";
import {requireCanonicalDescriptor, requirePackAuthorizedAction, retrieveLocalPacks} from "./local-retrieval.mjs";

const baseSessionProperty = {
  session_id: {type: "string", minLength: 8, description: "Opaque TutorHost teaching session id."},
};

/// Which applications this lesson is allowed to look at.
///
/// Without this the Mac falls back to its built-in default and only Blender can
/// ever be taught, which defeats the point of a path that needs no authored
/// pack. The Mac still requires one of these to be the focused window; naming an
/// application here grants no access to it.
const allowedBundleIDsProperty = {
  allowed_bundle_ids: {
    type: "array",
    items: {type: "string", minLength: 1, maxLength: 255},
    maxItems: 8,
    description: "Bundle ids this lesson may observe, e.g. [\"org.blenderfoundation.blender\"].",
  },
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
        ...allowedBundleIDsProperty,
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
  tutor_guide: {
    label: "Tutor Guide",
    description:
      "Move the Calla cursor to a region you read off the window capture and say what the learner should do there. This is the pack-free teaching path: no descriptor, no Accessibility, no clicking. Give region normalized to the observed window, and text the learner will read in the tooltip.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "snapshot_id", "region", "text"],
      properties: {
        ...baseSessionProperty,
        ...allowedBundleIDsProperty,
        snapshot_id: {type: "string", minLength: 1},
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
        step: {type: "string", maxLength: 60, description: "Short progress label, for example \"Step 2 of 4\"."},
        text: {type: "string", minLength: 1, maxLength: 240, description: "One instruction, in the learner's words."},
        status: {type: "string", maxLength: 80},
        wait_for_change: {
          type: "boolean",
          default: true,
          description: "Point and then wait for the learner in one call. Leave true: a separate tutor_await_change costs a whole extra round trip.",
        },
        timeout_seconds: {type: "number", minimum: 1, maximum: 25, default: 15},
      },
    },
  },
  tutor_await_change: {
    label: "Tutor Await Change",
    description:
      "Wait until the learner actually does something in the window, then return. This is how a lesson advances: guide a step, wait here, observe again, guide the next one. Returns changed false if the wait ran out, so you can re-word the step or keep waiting.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        ...allowedBundleIDsProperty,
        snapshot_id: {type: "string", minLength: 1},
        timeout_seconds: {type: "number", minimum: 1, maximum: 25, default: 15},
        sensitivity: {
          type: "number",
          minimum: 0.005,
          maximum: 0.5,
          default: 0.02,
          description: "How much of the window must differ to count as a change. Lower notices smaller edits.",
        },
      },
    },
  },
  tutor_narrate: {
    label: "Tutor Narrate",
    description:
      "Re-word the tooltip without moving the cursor. Use it to add a beat about the control you already pointed at, or to say you are still working something out.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "text"],
      properties: {
        ...baseSessionProperty,
        step: {type: "string", maxLength: 60},
        text: {type: "string", minLength: 1, maxLength: 240},
        status: {type: "string", maxLength: 80},
        thinking: {type: "boolean", default: false},
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

/**
 * An observation the model can actually look at.
 *
 * The window JPEG has to reach the model as an image block. Serialised into the
 * JSON text it is both invisible to vision and megabytes of base64 in the
 * transcript, which is why asking for a capture used to accomplish nothing. The
 * base64 is lifted out of the text half entirely and sent once, as an image.
 */
function observationResult(result) {
  // One unwrap may leave either the host's payload or its whole response,
  // depending on how the node transport framed it, so find the capture either
  // way rather than guessing.
  const holder = result?.capture ? result : result?.payload?.capture ? result.payload : null;
  const capture = holder?.capture;
  if (typeof capture?.base64 !== "string") return jsonResult(result);
  const {base64, ...captureMetadata} = capture;
  const redacted = {...holder, capture: {...captureMetadata, delivered_as: "image_content_block"}};
  const summary = holder === result ? redacted : {...result, payload: redacted};
  return {
    content: [
      {type: "text", text: JSON.stringify(summary, null, 2)},
      {type: "image", data: base64, mimeType: capture.mime_type || "image/jpeg"},
    ],
    details: summary,
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
      // Waiting for the learner is the one call that is meant to take a while,
      // so it gets a transport timeout longer than its own wait rather than
      // being cut off mid-wait by the default.
      const waitSeconds = name === "tutor_await_change" ? Number(envelope.payload.timeout_seconds ?? 15) : 0;
      const timeoutMs = waitSeconds > 0
        ? Math.max(config.timeoutMs, Math.round(waitSeconds * 1000) + 5_000)
        : config.timeoutMs;
      const invoked = await api.runtime.nodes.invoke({
        nodeId: config.nodeId,
        command: "desktop-tutor.host",
        params: envelope,
        timeoutMs,
      });
      const result = unwrapNodePayload(invoked);
      return name === "tutor_observe" ? observationResult(result) : jsonResult(result);
    },
  }));
}
