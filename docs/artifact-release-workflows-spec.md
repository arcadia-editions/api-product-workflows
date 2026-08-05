# API-first artifact workflows

The architecture manifest is the artifact inventory and coordinate authority. Validation and release workflows load it directly from its HTTPS URI with ManifestCore. API repositories never check out or download the architecture repository for read access. The architecture repository's update workflow instead resolves against its checked-out manifest, using the HTTPS URI only when a local source is unavailable.

Every manifest artifact is an independent release unit, including two artifacts with the same `type`. The release selector is the resolved `artifactId`; `groupId`, owner, type, path, and current manifest version are derived from ManifestCore.

## Validation lifecycle

- Pull requests and pushes to every branch lint and validate only affected manifest artifacts.
- A manual run validates every artifact owned by the repository.
- A push to `main` performs the same lint and validation only. It does not publish a snapshot.
- Workflow-only changes validate the complete repository inventory.
- An Avro change affects the repository's `asyncapi` and `asyncapi-client` artifacts.

Malformed YAML fails in the OpenAPI or AsyncAPI validator. Spectral applies Arcadia policy. AJV and YAML-to-JSON conversion are not part of the workflow.

## Release lifecycle

Inputs are `artifact`, `version`, and `nextVersion`. `artifact` is a resolved manifest `artifactId`.

1. Resolve the artifact from the HTTPS manifest and require exactly one match in the caller repository.
2. Create `release/{artifactId}/v{version}` from `main`.
3. Write the release version to the selected source, validate it, commit it, and create the identically named tag.
4. Package and publish only the selected artifact to its configured destinations.
5. Create a GitHub release from the tag.
6. Dispatch an architecture-manifest update identified by repository and `artifactId`.
7. Write `nextVersion`, commit it to the release branch, open a PR to `main`, merge after required checks, and delete the branch.
8. After the manifest PR merges, the architecture repository dispatches the existing EventCatalog `api-updated` receiver.

Coordinates are never reconstructed in shell. ManifestCore applies explicit values and configured default expressions, and the workflow fails if default `artifactId` values collide inside a repository.
