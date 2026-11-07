#!/usr/bin/env node
// Remove only toolbox-owned hook registrations from a provider config.

const fs = require('fs');

const configPath = process.env.PROVIDER_HOOK_CONFIG;
const hooksRoot = process.env.PROVIDER_HOOKS_ROOT;
const manifestPath = process.env.PROVIDER_HOOK_MANIFEST;

if (!configPath || !hooksRoot || !manifestPath || !fs.existsSync(configPath)) process.exit(0);
if (!fs.existsSync(manifestPath)) process.exit(0);

const managedHookNames = new Set(
  fs.readFileSync(manifestPath, 'utf8').split(/\r?\n/).filter(Boolean)
);
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
  return [...managedHookNames].some((name) =>
    containsPathToken(normalizedCommand, normalizedHooksRoot + '/' + name)
  );
};

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
for (const [event, matchers] of Object.entries(config.hooks || {})) {
  config.hooks[event] = (Array.isArray(matchers) ? matchers : [])
    .map((matcher) => {
      if (!matcher || !Array.isArray(matcher.hooks)) return matcher;
      return {
        ...matcher,
        hooks: matcher.hooks.filter((hook) => !isManagedCommand(hook && hook.command))
      };
    })
    .filter((matcher) => !matcher || !Array.isArray(matcher.hooks) || matcher.hooks.length > 0);
  if (config.hooks[event].length === 0) delete config.hooks[event];
}
if (config.hooks && Object.keys(config.hooks).length === 0) delete config.hooks;
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
