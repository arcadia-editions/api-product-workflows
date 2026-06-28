const { KEBAB_CASE, child, createRule, forEachValidOperation, hasOwn, isPositiveInteger } = require('./asyncapiUtils.js');

const ERROR_TOPIC_TEMPLATE = '${groupId}.__.${channel.address}.${suffix}';
const ERROR_TOPIC_FIELDS = new Set(['addressTemplate', 'retryTopics', 'retrySuffixes', 'retry', 'dlq']);
const ERROR_TOPIC_PLAN_FIELDS = new Set([
  '$ref',
  'partitions',
  'replicas',
  'topicConfiguration',
  'env-server-overrides',
]);

module.exports = createRule((document, path, report) => {
  forEachValidOperation(document, (operationId, operation) => {
    const kafka = operation.bindings?.kafka;
    if (kafka && typeof kafka === 'object' && hasOwn(kafka, 'x-error-topics')) {
      validateErrorTopics(document, operation, kafka, child(path, ['operations', operationId, 'bindings', 'kafka', 'x-error-topics']), report);
    }
  });

  validateReusablePlans(document, child(path, ['components', 'x-error-topics']), report);
});

function validateErrorTopics(document, operation, kafka, errorTopicsPath, report) {
  const errorTopics = kafka['x-error-topics'];

  if (operation.action !== 'receive') {
    report('Kafka x-error-topics is only allowed on receive operations.', errorTopicsPath);
  }

  if (!errorTopics || typeof errorTopics !== 'object') {
    report('Kafka x-error-topics must be an object.', errorTopicsPath);
    return;
  }

  reportUnknownFields(errorTopics, ERROR_TOPIC_FIELDS, errorTopicsPath, 'x-error-topics', report);

  if (typeof errorTopics.addressTemplate !== 'string') {
    report('x-error-topics.addressTemplate is required and must be a string.', child(errorTopicsPath, 'addressTemplate'));
  } else if (errorTopics.addressTemplate !== ERROR_TOPIC_TEMPLATE) {
    report(`x-error-topics.addressTemplate must be "${ERROR_TOPIC_TEMPLATE}".`, child(errorTopicsPath, 'addressTemplate'));
  }

  if (errorTopics.addressTemplate?.includes('${groupId}') && !hasOwn(kafka, 'groupId') && !hasOwn(kafka, 'x-groupId')) {
    report(
      'x-error-topics.addressTemplate uses ${groupId}, so bindings.kafka must define groupId or x-groupId.',
      child(errorTopicsPath, 'addressTemplate')
    );
  }

  if (!hasOwn(errorTopics, 'retry') && !hasOwn(errorTopics, 'dlq')) {
    report('x-error-topics must define at least retry or dlq.', errorTopicsPath);
  }

  if (hasOwn(errorTopics, 'retry') && !hasOwn(errorTopics, 'retryTopics')) {
    report('x-error-topics.retryTopics is required when retry is present.', child(errorTopicsPath, 'retryTopics'));
  }

  if (hasOwn(errorTopics, 'retryTopics') && !isPositiveInteger(errorTopics.retryTopics)) {
    report('x-error-topics.retryTopics must be a positive integer.', child(errorTopicsPath, 'retryTopics'));
  }

  if (hasOwn(errorTopics, 'retrySuffixes')) {
    validateRetrySuffixes(errorTopics.retrySuffixes, errorTopics.retryTopics, child(errorTopicsPath, 'retrySuffixes'), report);
  }

  if (hasOwn(errorTopics, 'retry')) {
    validatePlan(document, errorTopics.retry, child(errorTopicsPath, 'retry'), 'retry', report);
  }

  if (hasOwn(errorTopics, 'dlq')) {
    validatePlan(document, errorTopics.dlq, child(errorTopicsPath, 'dlq'), 'dlq', report);
  }
}

function validateReusablePlans(document, plansPath, report) {
  const plans = document.components?.['x-error-topics'];
  if (!plans || typeof plans !== 'object') {
    return;
  }

  reportUnknownFields(plans, new Set(['retry', 'dlq']), plansPath, 'components.x-error-topics', report);
  validateReusablePlanSection(document, plans.retry, child(plansPath, 'retry'), 'retry', report);
  validateReusablePlanSection(document, plans.dlq, child(plansPath, 'dlq'), 'dlq', report);
}

function validateReusablePlanSection(document, section, sectionPath, sectionName, report) {
  if (section === undefined) {
    return;
  }

  if (!section || typeof section !== 'object' || Array.isArray(section)) {
    report(`components.x-error-topics.${sectionName} must be an object keyed by plan name.`, sectionPath);
    return;
  }

  for (const [planId, plan] of Object.entries(section)) {
    const planPath = child(sectionPath, planId);
    if (!KEBAB_CASE.test(planId)) {
      report(`x-error-topics ${sectionName} plan id "${planId}" must be kebab-case.`, planPath);
    }

    validatePlan(document, plan, planPath, sectionName, report);
  }
}

function validatePlan(document, plan, planPath, planName, report) {
  if (!plan || typeof plan !== 'object') {
    report(`x-error-topics.${planName} must be an object or a $ref.`, planPath);
    return;
  }

  reportUnknownFields(plan, ERROR_TOPIC_PLAN_FIELDS, planPath, `x-error-topics.${planName}`, report);

  if (hasOwn(plan, '$ref')) {
    if (Object.keys(plan).length > 1) {
      report(`x-error-topics.${planName} must not combine $ref with inline fields.`, planPath);
    }

    if (typeof plan.$ref !== 'string') {
      report(`x-error-topics.${planName} $ref must be a string.`, child(planPath, '$ref'));
    }

    return;
  }

  validatePositiveInteger(plan.partitions, child(planPath, 'partitions'), `${planName}.partitions`, report);
  validatePositiveInteger(plan.replicas, child(planPath, 'replicas'), `${planName}.replicas`, report);

  if (hasOwn(plan, 'topicConfiguration') && (!plan.topicConfiguration || typeof plan.topicConfiguration !== 'object')) {
    report(`${planName}.topicConfiguration must be an object.`, child(planPath, 'topicConfiguration'));
  }

  validateEnvServerOverrides(document, plan['env-server-overrides'], child(planPath, 'env-server-overrides'), report);
}

function validateEnvServerOverrides(document, overrides, overridesPath, report) {
  if (overrides === undefined) {
    return;
  }

  if (!overrides || typeof overrides !== 'object' || Array.isArray(overrides)) {
    report('env-server-overrides must be an object.', overridesPath);
    return;
  }

  for (const [serverName, override] of Object.entries(overrides)) {
    const overridePath = child(overridesPath, serverName);

    if (!document.servers || !hasOwn(document.servers, serverName)) {
      report(`env-server-overrides key "${serverName}" must match a server defined in the AsyncAPI servers section.`, overridePath);
    }

    if (!override || typeof override !== 'object' || Array.isArray(override)) {
      report(`env-server-overrides.${serverName} must be an object.`, overridePath);
      continue;
    }

    validatePositiveInteger(override.partitions, child(overridePath, 'partitions'), `env-server-overrides.${serverName}.partitions`, report);
    validatePositiveInteger(override.replicas, child(overridePath, 'replicas'), `env-server-overrides.${serverName}.replicas`, report);

    if (hasOwn(override, 'topicConfiguration') && (!override.topicConfiguration || typeof override.topicConfiguration !== 'object')) {
      report(`env-server-overrides.${serverName}.topicConfiguration must be an object.`, child(overridePath, 'topicConfiguration'));
    }
  }
}

function validatePositiveInteger(value, path, fieldName, report) {
  if (value !== undefined && !isPositiveInteger(value)) {
    report(`${fieldName} must be a positive integer.`, path);
  }
}

function validateRetrySuffixes(retrySuffixes, retryTopics, retrySuffixesPath, report) {
  if (!Array.isArray(retrySuffixes) || retrySuffixes.length === 0) {
    report('x-error-topics.retrySuffixes must be a non-empty array of strings.', retrySuffixesPath);
    return;
  }

  retrySuffixes.forEach((suffix, index) => {
    if (typeof suffix !== 'string' || suffix.length === 0) {
      report('x-error-topics.retrySuffixes entries must be non-empty strings.', child(retrySuffixesPath, index));
    }
  });

  if (isPositiveInteger(retryTopics) && retrySuffixes.length !== retryTopics) {
    report('x-error-topics.retrySuffixes must contain one entry per retry topic.', retrySuffixesPath);
  }
}

function reportUnknownFields(object, allowedFields, path, objectName, report) {
  for (const field of Object.keys(object)) {
    if (!allowedFields.has(field)) {
      report(`${objectName}.${field} is not defined by the x-error-topics specification.`, child(path, field));
    }
  }
}
