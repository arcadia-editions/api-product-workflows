const { child, createRule, escapeRegExp, forEachInlineChannel, parseTopicAddress, pascalCase } = require('./asyncapiUtils.js');

module.exports = createRule((document, path, report) => {
  forEachInlineChannel(document, (channelId, channel) => {
    const topic = parseTopicAddress(channel.address);
    if (!topic || !channel.messages || typeof channel.messages !== 'object') {
      return;
    }

    const messageKeyWithType = `${pascalCase(topic.messageName)}${pascalCase(topic.messageType)}`;
    const messageKeyWithoutType = pascalCase(topic.messageName);
    const expectedSchemaRef = new RegExp(
      `^\\./avro/v[0-9]+/(${escapeRegExp(messageKeyWithType)}|${escapeRegExp(messageKeyWithoutType)})\\.avsc$`
    );

    for (const [messageKey, message] of Object.entries(channel.messages)) {
      const messagePath = child(path, ['channels', channelId, 'messages', messageKey]);

      if (messageKey !== messageKeyWithType && messageKey !== messageKeyWithoutType) {
        report(
          `Channel message key "${messageKey}" must be "${messageKeyWithType}" or "${messageKeyWithoutType}".`,
          messagePath
        );
      }

      const schemaRef = message?.payload?.schema?.$ref;
      if (schemaRef !== undefined && !expectedSchemaRef.test(schemaRef)) {
        report(
          `Avro schema $ref must match ./avro/vN/${messageKeyWithType}.avsc or ./avro/vN/${messageKeyWithoutType}.avsc.`,
          child(messagePath, ['payload', 'schema', '$ref'])
        );
      }
    }
  });
});
