const { TARGET_AUDIENCE, child, createRule, forEachInlineChannel, hasOwn } = require('./asyncapiUtils.js');

const VISIBILITY_VALUES = new Set(['global', 'domain', 'subdomain', 'internal', 'technical']);

module.exports = createRule((document, path, report) => {
  forEachInlineChannel(document, (channelId, channel) => {
    const channelPath = child(path, ['channels', channelId]);
    const hasVisibility = hasOwn(channel, 'x-visibility');
    const hasTargetAudience = hasOwn(channel, 'x-target-audience');

    if (hasVisibility && hasTargetAudience) {
      report('Use either x-visibility or x-target-audience, not both.', child(channelPath, 'x-target-audience'));
    }

    if (!hasVisibility && !hasTargetAudience) {
      report('Channel must define either x-visibility or x-target-audience.', channelPath);
    }

    if (hasVisibility && !VISIBILITY_VALUES.has(channel['x-visibility'])) {
      report('x-visibility must be one of: global, domain, subdomain, internal, technical.', child(channelPath, 'x-visibility'));
    }

    if (!hasTargetAudience) {
      return;
    }

    const targetAudience = channel['x-target-audience'];
    if (!Array.isArray(targetAudience) || targetAudience.length === 0) {
      report('x-target-audience must be a non-empty array.', child(channelPath, 'x-target-audience'));
      return;
    }

    targetAudience.forEach((value, index) => {
      if (!TARGET_AUDIENCE.test(value)) {
        report('x-target-audience entries must match <domain>.<subdomain>.<service>.', child(channelPath, ['x-target-audience', index]));
      }
    });
  });
});
