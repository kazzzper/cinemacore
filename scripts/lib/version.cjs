// Shared version derivation. VERSION is canonical; a tag is only accepted when
// it matches, so a mis-tagged release can never produce different artifacts.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const VERSION_FILE = path.join(ROOT, 'VERSION');

const CHANNEL_OFFSETS = { alpha: 10, beta: 30, rc: 60, stable: 99 };
const CHANNEL_ORDER = { alpha: 0, beta: 1, rc: 2, stable: 3 };

function readVersion(root = ROOT) {
  return fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
}

function parseVersion(raw) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$/.exec(raw);
  if (!match) {
    throw new Error(
      `VERSION must be X.Y.Z or X.Y.Z-(alpha|beta|rc).N, got "${raw}"`,
    );
  }

  const channel = match[4] || 'stable';
  const prerelease = match[5] ? Number(match[5]) : 0;
  if (channel !== 'stable' && (prerelease < 1 || prerelease > 9)) {
    throw new Error(
      `${channel} prerelease must be numbered 1-9; got ${raw}. ` +
        'The build-number formula reserves a single digit for it.',
    );
  }

  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    channel,
    prerelease,
  };
}

function formatVersion(version) {
  const base = `${version.major}.${version.minor}.${version.patch}`;
  return version.channel === 'stable'
    ? base
    : `${base}-${version.channel}.${version.prerelease}`;
}

function marketingVersion(version) {
  return `${version.major}.${version.minor}.${version.patch}`;
}

// Documented in RELEASING.md. The channel offset keeps alpha < beta < rc <
// stable for one base version, and the *100 patch step keeps 0.0.2 above
// 0.0.1's stable build.
function buildNumber(version) {
  const prerelease = version.channel === 'stable' ? 0 : version.prerelease;
  return (
    version.major * 1_000_000 +
    version.minor * 10_000 +
    version.patch * 100 +
    CHANNEL_OFFSETS[version.channel] +
    prerelease
  );
}

function gitShortSha(root = ROOT) {
  try {
    return execFileSync('git', ['rev-parse', '--short=7', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return 'local';
  }
}

function tagFromArgs(args) {
  const index = args.indexOf('--tag');
  if (index !== -1) return args[index + 1];
  if (process.env.GITHUB_REF_TYPE === 'tag') return process.env.GITHUB_REF_NAME;
  if (process.env.GITHUB_REF_NAME?.startsWith('v')) return process.env.GITHUB_REF_NAME;
  return null;
}

function derive({ root = ROOT, tag = null } = {}) {
  const version = parseVersion(readVersion(root));

  if (tag) {
    const expected = `v${formatVersion(version)}`;
    if (tag !== expected) {
      throw new Error(`tag ${tag} does not match VERSION (${expected})`);
    }
  }

  return {
    version,
    full: formatVersion(version),
    tag: `v${formatVersion(version)}`,
    marketing: marketingVersion(version),
    build: buildNumber(version),
    commit: gitShortSha(root),
  };
}

function bumpBase(version, bump, channel) {
  let { major, minor, patch } = version;
  if (bump === 'major') {
    major += 1;
    minor = 0;
    patch = 0;
  } else if (bump === 'minor') {
    minor += 1;
    patch = 0;
  } else if (bump === 'patch') {
    patch += 1;
  } else {
    throw new Error(`bump must be patch, minor or major; got "${bump}"`);
  }

  return { major, minor, patch, channel, prerelease: channel === 'stable' ? 0 : 1 };
}

function nextVersion(current, bump, channel) {
  if (!(channel in CHANNEL_ORDER)) {
    throw new Error(`channel must be alpha, beta, rc or stable; got "${channel}"`);
  }

  if (channel === 'stable') {
    if (current.channel !== 'stable') {
      // Promotion: the prerelease already chose the base version.
      return { ...current, channel: 'stable', prerelease: 0 };
    }
    return bumpBase(current, bump, channel);
  }

  if (current.channel === channel) {
    const next = { ...current, prerelease: current.prerelease + 1 };
    if (next.prerelease > 9) {
      throw new Error(
        `${formatVersion(current)} already used its 9 prerelease slots; ` +
          `use ${bump} to start a new base version.`,
      );
    }
    return next;
  }

  // Alpha -> beta -> rc moves on the same base. Anything else starts a new base.
  if (current.channel !== 'stable' && CHANNEL_ORDER[channel] > CHANNEL_ORDER[current.channel]) {
    return { ...current, channel, prerelease: 1 };
  }

  return bumpBase(current, bump, channel);
}

module.exports = {
  ROOT,
  VERSION_FILE,
  CHANNEL_ORDER,
  readVersion,
  parseVersion,
  formatVersion,
  marketingVersion,
  buildNumber,
  gitShortSha,
  tagFromArgs,
  derive,
  nextVersion,
};
