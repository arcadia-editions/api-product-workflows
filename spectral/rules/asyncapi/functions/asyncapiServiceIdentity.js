const { ASYNCAPI_ID, child, createRule, getSourcePath, parseAsyncApiId } = require('./asyncapiUtils.js');

module.exports = createRule((document, path, report, context) => {
  if (typeof document.id !== 'string' || !ASYNCAPI_ID.test(document.id)) {
    report(
      'AsyncAPI id must match urn:com.arcadiaeditions:<domain>:<subdomain>:asyncapi[:client].',
      child(path, 'id')
    );
  }

  const identity = parseAsyncApiId(document.id);
  const sourcePath = getSourcePath(context);
  if (!identity || !sourcePath || !sourcePath.endsWith('/asyncapi.yml')) {
    return;
  }

  const expectedPath = `${identity.service}-api/asyncapi.yml`;
  if (!sourcePath.endsWith(expectedPath)) {
    report(`Provider AsyncAPI file path must end with "${expectedPath}".`, child(path, 'id'));
  }
});
