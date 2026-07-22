//DEPS io.zenwave360.manifest:manifest-core-jvm:0.9.0
//DEPS org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2

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
        "usage: ManifestCoordinates.kt <manifest> <service-repository> <artifact-type> <deployment-version>"
    }
    val manifestUri = Paths.get(args[0]).toAbsolutePath().normalize().toUri().toString()
    val repository = args[1]
    val artifactType = args[2]
    val deploymentVersion = args[3]

    val loader = ZenWaveManifestLoader()
    val manifest = loader.load(manifestUri)
    val errors = manifest.diagnostics.filter { it.severity.toString() == "ERROR" }
    check(errors.isEmpty()) { "manifest diagnostics: ${errors.joinToString("; ")}" }
    val services = manifest.services.filter { it.repository == repository }
    check(services.size == 1) { "expected one service for repository $repository, found ${services.size}" }
    val service = services.single()
    val artifacts = service.artifacts.filter { it.type == artifactType }
    check(artifacts.size == 1) { "expected one $artifactType artifact for $repository, found ${artifacts.size}" }
    val artifact = artifacts.single()
    val context = loader.artifactResolutionContext(manifest, service, artifact)
    val groupId = context.groupId
    val artifactId = context.artifactId
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
            "\"manifestType\":" + json(artifact.type) + "," +
            "\"artifactPath\":" + json(artifact.path) + "," +
            "\"groupId\":" + json(groupId) + "," +
            "\"groupPath\":" + json(groupSegments.joinToString("/")) + "," +
            "\"artifactId\":" + json(artifactId) + "," +
            "\"manifestEffectiveVersion\":" + json(service.resolvedVersion(artifact)) + "," +
            "\"deploymentVersion\":" + json(deploymentVersion) +
        "}"
    )
}

