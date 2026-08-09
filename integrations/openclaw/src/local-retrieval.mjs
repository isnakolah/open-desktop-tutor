import fs from "node:fs/promises";
import path from "node:path";

const INDEX_FORMAT = "calla-local-pack-index";

function versionParts(version) {
  const match = String(version).trim().match(/^(\d+)(?:\.(\d+))?(?:\.(\d+))?/);
  if (!match) return null;
  return [Number(match[1]), Number(match[2] || 0), Number(match[3] || 0)];
}

function compareVersions(left, right) {
  const a = versionParts(left);
  const b = versionParts(right);
  if (!a || !b) return null;
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
}

export function versionMatchesRange(version, range) {
  if (typeof range !== "string" || !range.trim()) return false;
  const comparisons = range.trim().split(/\s+/);
  return comparisons.every((comparison) => {
    const match = comparison.match(/^(>=|<=|>|<|=)?\s*(\d+(?:\.\d+){0,2})$/);
    if (!match) return false;
    const result = compareVersions(version, match[2]);
    if (result === null) return false;
    switch (match[1] || "=") {
      case ">=": return result >= 0;
      case "<=": return result <= 0;
      case ">": return result > 0;
      case "<": return result < 0;
      default: return result === 0;
    }
  });
}

function requireApplication(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("tutor_retrieve requires an application object");
  }
  for (const field of ["bundle_id", "version"]) {
    if (typeof value[field] !== "string" || !value[field].trim()) {
      throw new TypeError(`tutor_retrieve application.${field} must be a non-empty string`);
    }
  }
  return {
    bundle_id: value.bundle_id.trim(),
    version: value.version.trim(),
    platform: typeof value.platform === "string" && value.platform.trim() ? value.platform.trim() : "macos",
    locale: typeof value.locale === "string" && value.locale.trim() ? value.locale.trim() : null,
  };
}

function supportsApplication(pack, application) {
  const applications = pack?.apps;
  if (!Array.isArray(applications)) return false;
  return applications.some((candidate) => {
    if (!candidate || typeof candidate !== "object") return false;
    if (candidate.platform !== application.platform) return false;
    if (!Array.isArray(candidate.bundle_ids) || !candidate.bundle_ids.includes(application.bundle_id)) return false;
    if (!versionMatchesRange(application.version, candidate.versions)) return false;
    return !application.locale || (Array.isArray(candidate.locales) && candidate.locales.includes(application.locale));
  });
}

function searchableText(entity) {
  return JSON.stringify(entity).toLocaleLowerCase("en-US");
}

function scoreEntity(entity, terms) {
  const text = searchableText(entity);
  let score = 0;
  for (const term of terms) {
    const position = text.indexOf(term);
    if (position < 0) return null;
    score += position === 0 ? 4 : 1;
  }
  return score;
}

async function readIndexes(indexDirectory) {
  let names;
  try {
    names = await fs.readdir(indexDirectory);
  } catch (error) {
    if (error && error.code === "ENOENT") return [];
    throw error;
  }
  const indexes = [];
  for (const name of names.sort()) {
    if (!name.endsWith(".json")) continue;
    try {
      const value = JSON.parse(await fs.readFile(path.join(indexDirectory, name), "utf8"));
      if (value?.format === INDEX_FORMAT && value.format_version === 1) indexes.push(value);
    } catch {
      // A malformed local index is ignored so one damaged pack cannot block teaching.
    }
  }
  return indexes;
}

export async function retrieveLocalPacks(config, payload) {
  const application = requireApplication(payload.application);
  const query = typeof payload.query === "string" ? payload.query.trim() : "";
  if (!query) throw new TypeError("tutor_retrieve query must be a non-empty string");
  const limit = Number.isInteger(payload.limit) ? Math.min(Math.max(payload.limit, 1), 20) : 5;
  const allowedKinds = Array.isArray(payload.entity_types) ? new Set(payload.entity_types) : null;
  const terms = query.toLocaleLowerCase("en-US").match(/[\p{L}\p{N}_.-]+/gu) || [];
  if (!terms.length) throw new TypeError("tutor_retrieve query contains no searchable terms");

  const matches = [];
  for (const index of await readIndexes(path.join(config.stateDirectory, "indexes"))) {
    if (!supportsApplication(index.pack, application)) continue;
    for (const entity of index.entities || []) {
      if (!entity || typeof entity !== "object") continue;
      if (allowedKinds && !allowedKinds.has(entity.kind)) continue;
      if (typeof entity.app_versions === "string" && !versionMatchesRange(application.version, entity.app_versions)) continue;
      const score = scoreEntity(entity, terms);
      if (score === null) continue;
      matches.push({
        pack_id: index.pack.id,
        pack_version: index.pack.pack_version,
        id: entity.id,
        kind: entity.kind,
        title: entity.title,
        source_file: entity.source_file,
        score,
        entity,
      });
    }
  }
  matches.sort((left, right) => right.score - left.score || left.id.localeCompare(right.id));
  return {
    ok: true,
    source: "server-local",
    application,
    results: matches.slice(0, limit),
  };
}
