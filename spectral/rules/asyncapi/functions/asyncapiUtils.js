const KEBAB_CASE = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/;
const ASYNCAPI_ID =
  /^urn:com\.arcadiaeditions:[a-z][a-z0-9-]*:[a-z][a-z0-9-]*:asyncapi(?::client)?$/;
const QUALIFIED_NAME = /^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$/;
const TARGET_AUDIENCE = /^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$/;
const TOPIC_MESSAGE_TYPES = new Set(['event', 'command', 'response', 'callback', 'cdc']);
const TOPIC_CONTENT_TYPES = new Set(['avro', 'json']);

function createRule(validate) {
  return function asyncapiRule(document, _options, context) {
    const results = [];
    const rootPath = context.path || [];
    const report = (message, path = rootPath) => results.push({ message, path });

    if (!document || typeof document !== 'object' || !/^3\./.test(String(document.asyncapi))) {
      return results;
    }

    validate(document, rootPath, report, context);
    return results;
  };
}

function parseTopicAddress(address) {
  if (typeof address !== 'string') {
    return undefined;
  }

  const parts = address.split('.');
  if (parts.length !== 5) {
    return undefined;
  }

  const [service, messageName, messageType, contentType, version] = parts;
  if (
    !KEBAB_CASE.test(service) ||
    !KEBAB_CASE.test(messageName) ||
    !TOPIC_MESSAGE_TYPES.has(messageType) ||
    !TOPIC_CONTENT_TYPES.has(contentType) ||
    !/^v[0-9]+$/.test(version)
  ) {
    return undefined;
  }

  return { service, messageName, messageType, contentType, version };
}

function parseAsyncApiId(id) {
  if (typeof id !== 'string') {
    return undefined;
  }

  const match = id.match(
    /^urn:com\.arcadiaeditions:([a-z][a-z0-9-]*):([a-z][a-z0-9-]*):asyncapi(?::client)?$/
  );
  if (!match) {
    return undefined;
  }

  const domain = match[1];
  const subdomain = match[2];
  return { domain, subdomain, service: `${domain}-${subdomain}` };
}

function getLocalRefName(ref, collectionName) {
  const prefix = `#/${collectionName}/`;
  if (typeof ref !== 'string' || !ref.startsWith(prefix)) {
    return undefined;
  }

  return decodeURIComponent(ref.slice(prefix.length).replace(/~1/g, '/').replace(/~0/g, '~'));
}

function getChannelIdentity(channelId, channel) {
  const topic = parseTopicAddress(channel?.address);
  if (topic) {
    return { messageName: topic.messageName, messageType: topic.messageType };
  }

  const match = channelId.match(/^(.+)-(event|command|response|callback|cdc)-(v[0-9]+)$/);
  return match ? { messageName: match[1], messageType: match[2] } : undefined;
}

function forEachInlineChannel(document, callback) {
  if (!document.channels || typeof document.channels !== 'object') {
    return;
  }

  for (const [channelId, channel] of Object.entries(document.channels)) {
    if (channel && typeof channel === 'object' && !channel.$ref) {
      callback(channelId, channel);
    }
  }
}

function forEachValidOperation(document, callback) {
  if (!document.operations || typeof document.operations !== 'object') {
    return;
  }

  for (const [operationId, operation] of Object.entries(document.operations)) {
    if (!operation || typeof operation !== 'object' || !['send', 'receive'].includes(operation.action)) {
      continue;
    }

    const channelId = getLocalRefName(operation.channel?.$ref, 'channels');
    if (!channelId) {
      continue;
    }

    const channelIdentity = getChannelIdentity(channelId, document.channels?.[channelId]);
    if (channelIdentity) {
      callback(operationId, operation, channelIdentity);
    }
  }
}

function getOperationPrefix(action, isClientSpec) {
  if (isClientSpec) {
    return action === 'send' ? 'do' : 'on';
  }

  return action === 'send' ? 'on' : 'do';
}

function getSourcePath(context) {
  const source = context.document?.source;
  return typeof source === 'string' ? source.replace(/\\/g, '/') : undefined;
}

function pascalCase(value) {
  return value
    .split('-')
    .filter(Boolean)
    .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
    .join('');
}

function child(path, segment) {
  return path.concat(Array.isArray(segment) ? segment : [segment]);
}

function hasOwn(object, property) {
  return Object.prototype.hasOwnProperty.call(object ?? {}, property);
}

function isPositiveInteger(value) {
  return Number.isInteger(value) && value >= 1;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

module.exports = {
  ASYNCAPI_ID,
  KEBAB_CASE,
  QUALIFIED_NAME,
  TARGET_AUDIENCE,
  child,
  createRule,
  escapeRegExp,
  forEachInlineChannel,
  forEachValidOperation,
  getChannelIdentity,
  getLocalRefName,
  getOperationPrefix,
  getSourcePath,
  hasOwn,
  isPositiveInteger,
  parseAsyncApiId,
  parseTopicAddress,
  pascalCase,
};
