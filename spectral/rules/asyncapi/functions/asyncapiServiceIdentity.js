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
  const githubRepository = globalThis.process?.env?.GITHUB_REPOSITORY?.split('/').pop();
  if (githubRepository) {
    if (githubRepository !== `${identity.service}-api`) {
      report(
        `Provider repository must be "${identity.service}-api", found "${githubRepository}".`,
        child(path, 'id')
      );
    }
    return;
  }

  if (!sourcePath.endsWith(expectedPath)) {
    report(`Provider AsyncAPI file path must end with "${expectedPath}".`, child(path, 'id'));
  }
});
