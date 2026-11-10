const { child, createRule, getChannelIdentity, getLocalRefName, getOperationPrefix, pascalCase } = require('./asyncapiUtils.js');

module.exports = createRule((document, path, report) => {
  const operations = document.operations;
  if (!operations || typeof operations !== 'object') {
    return;
  }

  const isClientSpec = typeof document.id === 'string' && document.id.endsWith(':client');

  for (const [operationId, operation] of Object.entries(operations)) {
    const operationPath = child(path, ['operations', operationId]);

    if (!operation || typeof operation !== 'object') {
      continue;
    }

    if (!['send', 'receive'].includes(operation.action)) {
      report('Operation action must be either send or receive.', child(operationPath, 'action'));
      continue;
    }

    const channelId = getLocalRefName(operation.channel?.$ref, 'channels');
    if (!channelId) {
      report('Operation channel must be a local reference like #/channels/<channel-id>.', child(operationPath, ['channel', '$ref']));
      continue;
    }

    const channelIdentity = getChannelIdentity(channelId, document.channels?.[channelId]);
    if (!channelIdentity) {
      continue;
    }

    const prefix = getOperationPrefix(operation.action, isClientSpec);
    const messageName = pascalCase(channelIdentity.messageName);
    const messageType = pascalCase(channelIdentity.messageType);
    const versionSuffix = channelIdentity.version ? pascalCase(channelIdentity.version) : '';
    const operationIdWithType = `${prefix}${messageName}${messageType}`;
    const operationIdWithoutType = `${prefix}${messageName}`;
    const accepted = [operationIdWithType, operationIdWithoutType];
    if (versionSuffix) {
      accepted.push(`${operationIdWithType}${versionSuffix}`, `${operationIdWithoutType}${versionSuffix}`);
    }

    if (!accepted.includes(operationId)) {
      report(
        `Operation id "${operationId}" must be ${accepted.map((id) => `"${id}"`).join(' or ')} for "${channelIdentity.messageName}-${channelIdentity.messageType}".`,
        operationPath
      );
    }
  }
});
