const { KEBAB_CASE, child, createRule, parseAsyncApiId, parseTopicAddress } = require('./asyncapiUtils.js');

module.exports = createRule((document, path, report) => {
  const channels = document.channels;
  if (!channels || typeof channels !== 'object') {
    return;
  }

  const isClientSpec = typeof document.id === 'string' && document.id.endsWith(':client');
  const asyncApiIdentity = parseAsyncApiId(document.id);

  for (const [channelId, channel] of Object.entries(channels)) {
    const channelPath = child(path, ['channels', channelId]);

    if (!KEBAB_CASE.test(channelId)) {
      report(`Channel id "${channelId}" must be kebab-case.`, channelPath);
    }

    if (!channel || typeof channel !== 'object') {
      continue;
    }

    if (isClientSpec && !channel.$ref) {
      report('Client AsyncAPI files must reference provider channels instead of defining them inline.', channelPath);
    }

    if (channel.$ref) {
      continue;
    }

    const topic = parseTopicAddress(channel.address);
    if (!topic) {
      report(
        'Channel address must match <service>.<message-name>.<event|command|response|callback|cdc>.<avro|json>.v<N>.',
        child(channelPath, 'address')
      );
    } else if (channelId !== `${topic.messageName}-${topic.messageType}-${topic.version}`) {
      report(
        `Channel id "${channelId}" must match "${topic.messageName}-${topic.messageType}-${topic.version}".`,
        channelPath
      );
    } else if (
      asyncApiIdentity &&
      !isClientSpec &&
      topic.service !== asyncApiIdentity.service
    ) {
      report(
        `Channel address must start with "${asyncApiIdentity.service}" derived from the AsyncAPI id domain/subdomain.`,
        child(channelPath, 'address')
      );
    }
  }
});
