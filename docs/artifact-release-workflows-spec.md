# API-first artifact workflows

The architecture manifest is the artifact inventory and coordinate authority. Validation and release workflows load it directly from its HTTPS URI with ManifestCore. API repositories never check out or download the architecture repository for read access. The architecture repository's update workflow resolves against its checked-out manifest and runs a locally checked-out copy of the manifest tooling.

Every manifest artifact is normally an independent release unit. `asyncapi-all` is the release identity for every `asyncapi` and `asyncapi-client` artifact owned by the repository. `service-all` is a service snapshot release: it packages every tracked repository file without changing the individual artifact versions and advances only the service version in the architecture manifest.

## Validation lifecycle

- Pull requests and pushes lint and validate affected manifest artifacts. Selecting either AsyncAPI bundle member, or changing any `.avsc` file, resolves `asyncapi-all` and validates every member.
- A manual run validates every artifact owned by the repository.
- A push to `main` performs the same lint and validation only. It does not publish a snapshot.
- Workflow-only changes validate the complete repository inventory.
- AsyncAPI bundle members must expose the same `info.version` whenever both exist.

Malformed YAML fails in the OpenAPI or AsyncAPI validator. Spectral applies Arcadia policy. AJV and YAML-to-JSON conversion are not part of the workflow.

## Release lifecycle

Inputs are `artifact` and `version`. `artifact=asyncapi-all` selects the complete Kafka-contract bundle; direct `asyncapi` and `asyncapi-client` releases are rejected. `artifact=service-all` selects the complete service repository and marks the resulting GitHub release as latest.

1. Resolve the release plan from the HTTPS manifest. For `asyncapi-all`, require its concrete members to have a shared current version. For `service-all`, resolve every artifact owned by the service while allowing their current versions to differ.
2. Create `release/{artifactId}/v{version}` from `main`.
3. For artifact releases, write the release version to every selected source. For `service-all`, leave every source unchanged. Validate the complete plan, commit it, and push the release branch.
4. Open a PR containing the release-version change, merge it into `main` after required checks, and delete the release branch.
5. Create the identically named tag on the resulting `main` merge commit.
6. Package one artifact. Maven JAR payload entries are rooted under the Java package path derived from their `groupId`; `META-INF` remains at the archive root. The `asyncapi-all` JAR contains every bundle source and referenced schema. The `service-all` JAR and generic tree contain every Git-tracked repository file, and its individual artifacts are not republished to Apicurio.
7. Create a GitHub release from the tag. Only `service-all` is marked as the latest release.
8. For `asyncapi-all`, attach one combined Terraform ZIP generated from the same release tag.
9. Dispatch one architecture-manifest update. Artifact releases update their selected artifact versions; `service-all` updates only the owning service's version through ManifestCore.
10. The architecture repository updates every member in one PR, then dispatches one EventCatalog `api-updated` event.

`main` retains the released version. There is no next-version input or post-release version commit.

Coordinates are never reconstructed in shell. ManifestCore applies explicit values and configured default expressions, and the workflow fails if default `artifactId` values collide inside a repository.

`ManifestTool update` accepts one or more `<selector> <version>` pairs. It resolves every pair
before returning any changes and persists the single validated document update only after the
complete editor operation succeeds.
