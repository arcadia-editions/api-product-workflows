const { QUALIFIED_NAME, child, createRule, forEachValidOperation, hasOwn } = require('./asyncapiUtils.js');

module.exports = createRule((document, path, report) => {
  forEachValidOperation(document, (operationId, operation) => {
    const kafka = operation.bindings?.kafka;
    if (!kafka || typeof kafka !== 'object') {
      return;
    }

    const kafkaPath = child(path, ['operations', operationId, 'bindings', 'kafka']);

    if (hasOwn(kafka, 'x-principal') && !QUALIFIED_NAME.test(kafka['x-principal'])) {
      report('Kafka x-principal must match <domain>.<subdomain>.<service>.<runtime-layer>.', child(kafkaPath, 'x-principal'));
    }

    if (hasOwn(kafka, 'x-groupId') && !QUALIFIED_NAME.test(kafka['x-groupId'])) {
      report('Kafka x-groupId must match <domain>.<subdomain>.<service>.<runtime-layer>.', child(kafkaPath, 'x-groupId'));
    }
  });
});
