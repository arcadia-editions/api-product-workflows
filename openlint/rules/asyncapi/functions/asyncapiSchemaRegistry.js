const { child, createRule, forEachInlineChannel, hasOwn } = require('./asyncapiUtils.js');

const SCHEMA_LOOKUP_STRATEGIES = new Set(['TopicNameStrategy', 'TopicRecordNameStrategy']);
const SCHEMA_COMPATIBILITIES = new Set(['BACKWARD', 'FORWARD', 'FULL']);
const SCHEMA_TYPES = new Set(['AVRO', 'JSON']);

module.exports = createRule((document, path, report) => {
  forEachInlineChannel(document, (channelId, channel) => {
    const registryPath = child(path, ['channels', channelId, 'bindings', 'kafka', 'x-kafka-schema-registry']);
    const registry = channel.bindings?.kafka?.['x-kafka-schema-registry'];
    if (!registry || typeof registry !== 'object') {
      return;
    }

    validateLookupStrategy(registry.schemaLookupStrategy, child(registryPath, 'schemaLookupStrategy'), report);
    validateCompatibility(registry.compatibility, child(registryPath, 'compatibility'), report);
    validateType(registry.type, child(registryPath, 'type'), report);

    if (hasOwn(registry, 'normalize') && typeof registry.normalize !== 'boolean') {
      report('Schema registry normalize must be a boolean.', child(registryPath, 'normalize'));
    }
  });

  const traits = document.components?.messageTraits;
  if (!traits || typeof traits !== 'object') {
    return;
  }

  for (const [traitId, trait] of Object.entries(traits)) {
    const kafkaPath = child(path, ['components', 'messageTraits', traitId, 'bindings', 'kafka']);
    const kafka = trait?.bindings?.kafka;
    if (!kafka || typeof kafka !== 'object') {
      continue;
    }

    if (hasOwn(kafka, 'schemaLookupStrategy')) {
      validateLookupStrategy(kafka.schemaLookupStrategy, child(kafkaPath, 'schemaLookupStrategy'), report);
    }

    if (hasOwn(kafka, 'x-schemaCompatibility')) {
      validateCompatibility(kafka['x-schemaCompatibility'], child(kafkaPath, 'x-schemaCompatibility'), report);
    }

    if (hasOwn(kafka, 'x-normalize') && typeof kafka['x-normalize'] !== 'boolean') {
      report('Kafka x-normalize must be a boolean.', child(kafkaPath, 'x-normalize'));
    }
  }
});

function validateLookupStrategy(value, path, report) {
  if (value !== undefined && !SCHEMA_LOOKUP_STRATEGIES.has(value)) {
    report('schemaLookupStrategy must be TopicNameStrategy or TopicRecordNameStrategy.', path);
  }
}

function validateCompatibility(value, path, report) {
  if (value !== undefined && !SCHEMA_COMPATIBILITIES.has(value)) {
    report('Schema compatibility must be BACKWARD, FORWARD, or FULL.', path);
  }
}

function validateType(value, path, report) {
  if (value !== undefined && !SCHEMA_TYPES.has(value)) {
    report('Schema registry type must be AVRO or JSON.', path);
  }
}
