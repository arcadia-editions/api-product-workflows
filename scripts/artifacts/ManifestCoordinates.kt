//KOTLIN 2.3.0
// manifest-core 0.9.0 uses Kotlin 2.3.0 but references an unpublished
// kotlin-stdlib-common 2.3.0 artifact, so keep the runtime and override only common.
//DEPS io.zenwave360.manifest:manifest-core-jvm:0.9.0
//DEPS org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2
//DEPS org.jetbrains.kotlin:kotlin-stdlib:2.3.0
//DEPS org.jetbrains.kotlin:kotlin-stdlib-common:2.0.21

import io.zenwave360.manifest.ManifestArtifact
import io.zenwave360.manifest.ZenWaveManifestLoader
import kotlinx.coroutines.runBlocking
import java.nio.file.Paths

private fun json(value: String?): String = buildString {
    append('"')
    (value ?: "").forEach { ch ->
        when (ch) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> append(ch)
        }
    }
    append('"')
}

fun main(args: Array<String>) = runBlocking {
    require(args.size == 4) {
        "usage: ManifestCoordinates.kt <manifest> <service-repository> <manifest-type-or-service> <deployment-version>"
    }
    val manifestUri = Paths.get(args[0]).toAbsolutePath().normalize().toUri().toString()
    val repository = args[1]
    val requestedType = args[2]
    val deploymentVersion = args[3]

    val loader = ZenWaveManifestLoader()
    val manifest = loader.load(manifestUri)
    val errors = manifest.diagnostics.filter { it.severity.toString() == "ERROR" }
    check(errors.isEmpty()) { "manifest diagnostics: ${errors.joinToString("; ")}" }
    val services = manifest.services.filter { it.repository == repository }
    check(services.size == 1) { "expected one service for repository $repository, found ${services.size}" }
    val service = services.single()
    val artifact = if (requestedType == "service") {
        // Coordinate adapter only: the service package is not a manifest artifact.
        ManifestArtifact(
            name = service.name,
            artifactId = repository,
            type = "service",
            path = ".arcadia/api-product.yml",
            version = service.version,
        )
    } else {
        val artifacts = service.artifacts.filter { it.type == requestedType }
        check(artifacts.size == 1) {
            "expected one $requestedType artifact for $repository, found ${artifacts.size}"
        }
        artifacts.single()
    }
    val context = loader.artifactResolutionContext(manifest, service, artifact)
    val groupId = requireNotNull(context.groupId) { "manifest-core resolved a null groupId" }
    val artifactId = requireNotNull(context.artifactId) { "manifest-core resolved a null artifactId" }
    check(groupId.isNotBlank()) { "manifest-core resolved an empty groupId" }
    check(artifactId.isNotBlank()) { "manifest-core resolved an empty artifactId" }
    val groupSegments = groupId.split('.')
    check(groupSegments.all { it.matches(Regex("[A-Za-z0-9_][A-Za-z0-9_-]*")) }) {
        "unsupported Maven groupId: $groupId"
    }
    check(artifactId.matches(Regex("[A-Za-z0-9_][A-Za-z0-9_.-]*"))) {
        "unsupported Maven artifactId: $artifactId"
    }

    println(
        "{" +
            "\"serviceId\":" + json(service.id) + "," +
            "\"serviceRepository\":" + json(service.repository) + "," +
            "\"packageUnit\":" + json(requestedType) + "," +
            "\"contentPath\":" + json(artifact.path) + "," +
            "\"groupId\":" + json(groupId) + "," +
            "\"groupPath\":" + json(groupSegments.joinToString("/")) + "," +
            "\"artifactId\":" + json(artifactId) + "," +
            "\"manifestEffectiveVersion\":" +
            json(if (requestedType == "service") service.version else service.resolvedVersion(artifact)) + "," +
            "\"deploymentVersion\":" + json(deploymentVersion) +
        "}"
    )
}
