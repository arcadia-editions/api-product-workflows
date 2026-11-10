const {
  child,
  createRule,
  escapeRegExp,
  forEachInlineChannel,
  messageKeyAllowed,
  messageKeyStems,
  namesWithTypeSuffixes,
  parseTopicAddress,
  pascalCase,
} = require('./asyncapiUtils.js');

module.exports = createRule((document, path, report) => {
  forEachInlineChannel(document, (channelId, channel) => {
    const topic = parseTopicAddress(channel.address);
    if (!topic || !channel.messages || typeof channel.messages !== 'object') {
      return;
    }

    const messageName = pascalCase(topic.messageName);
    const acceptedKeys = namesWithTypeSuffixes(messageName, topic.messageType);

    for (const [messageKey, message] of Object.entries(channel.messages)) {
      const messagePath = child(path, ['channels', channelId, 'messages', messageKey]);

      if (!messageKeyAllowed(messageKey, messageName, topic.messageType)) {
        report(
          `Channel message key "${messageKey}" must be ${acceptedKeys.map((id) => `"${id}"`).join(' or ')}, or end with "Command" or "Response".`,
          messagePath
        );
      }

      const schemaNames = new Set([...acceptedKeys, ...messageKeyStems(messageKey)]);
      const expectedSchemaRef = new RegExp(
        `^\\./avro/v[0-9]+/(${[...schemaNames].map(escapeRegExp).join('|')})\\.avsc$`
      );
      const schemaRef = message?.payload?.schema?.$ref;
      if (schemaRef !== undefined && !expectedSchemaRef.test(schemaRef)) {
        report(
          `Avro schema $ref must match ./avro/vN/<message key>.avsc for ${[...schemaNames].map((id) => `"${id}"`).join(' or ')}.`,
          child(messagePath, ['payload', 'schema', '$ref'])
        );
      }
    }
  });
});
