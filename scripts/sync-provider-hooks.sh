#!/usr/bin/env bash
# Install and configure the toolbox-owned hooks for one provider host.
#
# hooks/hooks-config.json is the single source of truth. The only provider
# adaptation is the destination hook directory; Codex does not consume
# Claude's permissions section, so that host-only section is omitted there.

set -euo pipefail

usage() {
  echo "usage: $0 --source HOOKS_DIR --destination HOOKS_DIR --config CONFIG_FILE --provider claude|codex" >&2
  exit 2
}

SOURCE=""
DESTINATION=""
CONFIG=""
PROVIDER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) [[ $# -ge 2 ]] || usage; SOURCE="$2"; shift 2 ;;
    --destination) [[ $# -ge 2 ]] || usage; DESTINATION="$2"; shift 2 ;;
    --config) [[ $# -ge 2 ]] || usage; CONFIG="$2"; shift 2 ;;
    --provider) [[ $# -ge 2 ]] || usage; PROVIDER="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$PROVIDER" == "claude" || "$PROVIDER" == "codex" ]] || usage
[[ -d "$SOURCE" ]] || { echo "hook source directory is missing: $SOURCE" >&2; exit 1; }
[[ -f "$SOURCE/hooks-config.json" ]] || { echo "hook config is missing: $SOURCE/hooks-config.json" >&2; exit 1; }
mkdir -p "$DESTINATION"
mkdir -p "$(dirname "$CONFIG")"

HOOK_FILES=()
while IFS= read -r source_hook; do
  HOOK_FILES[${#HOOK_FILES[@]}]="$source_hook"
done < <(find "$SOURCE" -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
(( ${#HOOK_FILES[@]} > 0 )) || { echo "no managed hooks found in: $SOURCE" >&2; exit 1; }

MANIFEST="$DESTINATION/.toolbox-hook-manifest"
OLD_MANIFEST="$MANIFEST.previous"
if [[ -f "$MANIFEST" ]]; then
  cp "$MANIFEST" "$OLD_MANIFEST"
fi

TMP_HOOK=""
cleanup() {
  [[ -z "$TMP_HOOK" || ! -e "$TMP_HOOK" ]] || rm -f "$TMP_HOOK"
  rm -f "$OLD_MANIFEST"
}
trap cleanup EXIT

for source_hook in "${HOOK_FILES[@]}"; do
  hook_name="$(basename "$source_hook")"
  TMP_HOOK="$(mktemp "$DESTINATION/.${hook_name}.XXXXXX")"
  cp "$source_hook" "$TMP_HOOK"
  chmod 755 "$TMP_HOOK"
  mv -f "$TMP_HOOK" "$DESTINATION/$hook_name"
  TMP_HOOK=""
done

{
  for source_hook in "${HOOK_FILES[@]}"; do
    basename "$source_hook"
  done
} | LC_ALL=C sort > "$MANIFEST"

# Remove hooks that this installer managed in an older version but that the
# current source no longer owns. Unrelated host hooks remain untouched.
if [[ -f "$OLD_MANIFEST" ]]; then
  while IFS= read -r old_hook; do
    [[ -n "$old_hook" ]] || continue
    if ! grep -Fxq -- "$old_hook" "$MANIFEST"; then
      rm -f "$DESTINATION/$old_hook"
    fi
  done < "$OLD_MANIFEST"
fi

SOURCE_CONFIG="$SOURCE/hooks-config.json" \
DEST_CONFIG="$CONFIG" \
HOOKS_ROOT="$DESTINATION" \
PROVIDER="$PROVIDER" \
MANIFEST="$MANIFEST" \
node <<'NODE'
const fs = require('fs');
const path = require('path');

const sourceConfig = process.env.SOURCE_CONFIG;
const destinationConfig = process.env.DEST_CONFIG;
const hooksRoot = process.env.HOOKS_ROOT;
const provider = process.env.PROVIDER;

const template = JSON.parse(fs.readFileSync(sourceConfig, 'utf8'));
const replaceHookPaths = (value) => {
  if (typeof value === 'string') {
    return value.replaceAll('~/.claude/hooks', hooksRoot);
  }
  if (Array.isArray(value)) return value.map(replaceHookPaths);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, replaceHookPaths(item)]));
  }
  return value;
};

const managed = replaceHookPaths(template);
if (provider === 'codex') {
  delete managed.permissions;
  // Codex has no Claude CronCreate or AskUserQuestion tool surface. Its
  // heartbeat and host UI provide those responsibilities, so do not emit
  // unsupported matchers into hooks.json.
  delete managed.hooks.CronCreate;
  delete managed.hooks.AskUserQuestion;
}

const manifestFiles = [process.env.MANIFEST, process.env.MANIFEST + '.previous'];
const managedHookNames = new Set();
for (const manifestFile of manifestFiles) {
  if (!manifestFile || !fs.existsSync(manifestFile)) continue;
  for (const name of fs.readFileSync(manifestFile, 'utf8').split(/\r?\n/)) {
    if (name) managedHookNames.add(name);
  }
}
const normalizedHooksRoot = hooksRoot.replaceAll('\\', '/').replace(/\/+$/, '');
const isBoundary = (character, before) => {
  if (character === undefined) return true;
  return before
    ? /[\s"'`=;&|()<>]/.test(character)
    : /[\s"'`;&|()<>]/.test(character);
};
const containsPathToken = (command, candidate) => {
  let offset = command.indexOf(candidate);
  while (offset >= 0) {
    const after = offset + candidate.length;
    if (isBoundary(command[offset - 1], true) && isBoundary(command[after], false)) return true;
    offset = command.indexOf(candidate, offset + 1);
  }
  return false;
};
const isManagedCommand = (command) => {
  if (typeof command !== 'string') return false;
  const normalizedCommand = command.replaceAll('\\', '/');
  // An empty manifest provides no ownership proof. Preserve registrations
  // until a subsequent install writes a trustworthy manifest.
  if (managedHookNames.size === 0) return false;
  return [...managedHookNames].some((name) =>
    containsPathToken(normalizedCommand, normalizedHooksRoot + '/' + path.basename(name))
  );
};
const removeManagedHooks = (matchers) => (Array.isArray(matchers) ? matchers : [])
  .map((matcher) => {
    if (!matcher || !Array.isArray(matcher.hooks)) return matcher;
    return {
      ...matcher,
      hooks: matcher.hooks.filter((hook) => !isManagedCommand(hook && hook.command))
    };
  })
  .filter((matcher) => !matcher || !Array.isArray(matcher.hooks) || matcher.hooks.length > 0);

let existing = {};
if (fs.existsSync(destinationConfig)) {
  existing = JSON.parse(fs.readFileSync(destinationConfig, 'utf8'));
}
if (!existing.hooks || typeof existing.hooks !== 'object' || Array.isArray(existing.hooks)) {
  existing.hooks = {};
}

// First remove all registrations owned by this destination, including events
// that the current provider no longer supports. This is what clears stale
// Claude-only matchers from a previously refreshed Codex configuration.
for (const event of Object.keys(existing.hooks)) {
  existing.hooks[event] = removeManagedHooks(existing.hooks[event]);
  if (existing.hooks[event].length === 0) delete existing.hooks[event];
}

for (const [event, matchers] of Object.entries(managed.hooks || {})) {
  if (!Array.isArray(existing.hooks[event])) existing.hooks[event] = [];
  for (const matcher of matchers) {
    const index = existing.hooks[event].findIndex((item) => item && item.matcher === matcher.matcher);
    if (index >= 0) {
      existing.hooks[event][index] = {
        ...existing.hooks[event][index],
        ...matcher,
        hooks: [
          ...(existing.hooks[event][index].hooks || []),
          ...(matcher.hooks || [])
        ]
      };
    }
    else existing.hooks[event].push(matcher);
  }
}

const configContents = JSON.stringify(existing, null, 2) + '\n';
let configTarget = destinationConfig;
let destinationStat;
try {
  destinationStat = fs.lstatSync(destinationConfig);
  if (destinationStat.isSymbolicLink()) {
    try {
      configTarget = fs.realpathSync(destinationConfig);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      // Keep a dangling symlink intact and refresh the path it names. The
      // target's parent must already exist; otherwise fail without replacing
      // the link, which is safer than silently destroying host configuration.
      const linkTarget = fs.readlinkSync(destinationConfig);
      configTarget = path.isAbsolute(linkTarget)
        ? linkTarget
        : path.resolve(path.dirname(destinationConfig), linkTarget);
    }
    const expectedConfigDirectory = fs.realpathSync(path.dirname(destinationConfig));
    let configTargetDirectory;
    try {
      configTargetDirectory = fs.realpathSync(path.dirname(configTarget));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      configTargetDirectory = path.resolve(path.dirname(configTarget));
    }
    if (configTargetDirectory !== expectedConfigDirectory) {
      throw new Error(`refusing to refresh config symlink outside ${expectedConfigDirectory}`);
    }
    try {
      destinationStat = fs.lstatSync(configTarget);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      destinationStat = undefined;
    }
    // If the outer link was dangling, a second symlink may still hide an
    // external target whose final path cannot be resolved yet. Refuse chained
    // links in that case; only a direct in-directory target is safe to create.
    if (destinationStat && destinationStat.isSymbolicLink()) {
      throw new Error('refusing to refresh a chained config symlink');
    }
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const tempConfig = configTarget + '.tmp.' + process.pid;
fs.writeFileSync(tempConfig, configContents, { mode: 0o600 });

// POSIX rename is atomic for a regular file, but Windows refuses to replace an
// existing destination. A symlink must be written through so the link and its
// target survive refresh. Keep both cases explicit instead of unconditionally
// deleting the destination, which would make interrupted refreshes destructive.
if (process.platform === 'win32' && destinationStat) {
  fs.copyFileSync(tempConfig, configTarget);
  fs.unlinkSync(tempConfig);
} else {
  fs.renameSync(tempConfig, configTarget);
}
NODE

echo "synchronized ${#HOOK_FILES[@]} managed hooks for $PROVIDER in $DESTINATION"
