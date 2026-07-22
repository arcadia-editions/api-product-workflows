//DEPS io.zenwave360.manifest:manifest-core-jvm:0.9.0
//DEPS org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2
//DEPS org.apache.maven:maven-artifact:3.9.11

import io.zenwave360.manifest.ManifestArtifact
import io.zenwave360.manifest.ManifestService
import io.zenwave360.manifest.ZenWaveManifest
import io.zenwave360.manifest.ZenWaveManifestLoader
import kotlinx.coroutines.runBlocking
import org.apache.maven.artifact.versioning.ComparableVersion
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

private fun loadManifest(path: Path): ZenWaveManifest = runBlocking {
    ZenWaveManifestLoader().load(path.toAbsolutePath().normalize().toUri().toString())
}

private fun requireValidManifest(manifest: ZenWaveManifest) {
    val errors = manifest.diagnostics.filter { it.severity.toString() == "ERROR" }
    check(errors.isEmpty()) { "manifest diagnostics: ${errors.joinToString("; ")}" }
}

private fun selectService(manifest: ZenWaveManifest, repository: String): ManifestService {
    val matches = manifest.services.filter { it.repository == repository }
    check(matches.size == 1) {
        "expected exactly one service with repository $repository, found ${matches.size}"
    }
    return matches.single()
}

private fun selectArtifacts(service: ManifestService, type: String): List<ManifestArtifact> =
    service.artifacts.filter { it.type == type }

private fun checkNotNewer(existing: String?, proposed: String, label: String) {
    if (existing.isNullOrBlank()) return
    check(ComparableVersion(existing) <= ComparableVersion(proposed)) {
        "existing $label version $existing is newer than proposed $proposed"
    }
}

private fun indentation(line: String): Int = line.indexOfFirst { !it.isWhitespace() }.let {
    if (it == -1) line.length else it
}

private fun unquote(value: String): String = value.trim().removeSurrounding("\"").removeSurrounding("'")

private fun replaceOrInsertArtifactVersion(
    lines: MutableList<String>,
    serviceStart: Int,
    serviceEnd: Int,
    type: String,
    proposed: String,
) {
    val typePattern = Regex("""^\s+- type:\s*["']?${Regex.escape(type)}["']?\s*$""")
    val typeLines = (serviceStart until serviceEnd).filter { typePattern.matches(lines[it]) }
    check(typeLines.size == 1) { "expected exactly one $type artifact, found ${typeLines.size}" }
    val start = typeLines.single()
    val entryIndent = indentation(lines[start])
    val finish = ((start + 1) until serviceEnd).firstOrNull {
        indentation(lines[it]) == entryIndent && lines[it].trimStart().startsWith("- type:")
    } ?: serviceEnd
    val versionLine = ((start + 1) until finish).firstOrNull {
        lines[it].trimStart().startsWith("version:")
    }
    if (versionLine != null) {
        val existing = unquote(lines[versionLine].substringAfter("version:"))
        checkNotNewer(existing, proposed, type)
        lines[versionLine] = " ".repeat(indentation(lines[versionLine])) + "version: \"$proposed\""
    } else {
        lines.add(finish, " ".repeat(entryIndent + 2) + "version: \"$proposed\"")
    }
}

private fun validateRequestedArtifacts(service: ManifestService, family: String) {
    if (family == "api-product") {
        listOf("zdl", "openapi", "asyncapi").forEach { type ->
            val entries = selectArtifacts(service, type)
            check(entries.size == 1) { "expected exactly one $type artifact before API-product release" }
            check(!entries.single().version.isNullOrBlank()) {
                "$type must have an explicit audited version before an API-product release"
            }
        }
        val clients = selectArtifacts(service, "asyncapi-client")
        check(clients.size <= 1) { "duplicate asyncapi-client artifacts" }
        if (clients.size == 1) {
            check(!clients.single().version.isNullOrBlank()) {
                "asyncapi-client must have an explicit audited version before an API-product release"
            }
        }
        return
    }

    val types = if (family == "asyncapi") listOf("asyncapi", "asyncapi-client") else listOf(family)
    types.forEach { type ->
        val entries = selectArtifacts(service, type)
        if (type == "asyncapi-client" && entries.isEmpty()) return@forEach
        check(entries.size == 1) { "expected exactly one $type artifact, found ${entries.size}" }
    }
}

private fun updateManifest(path: Path, repository: String, family: String, proposed: String) {
    val original = loadManifest(path)
    requireValidManifest(original)
    val service = selectService(original, repository)
    validateRequestedArtifacts(service, family)

    val lines = Files.readAllLines(path).toMutableList()
    val repositoryPattern = Regex("""^\s+repository:\s*["']?${Regex.escape(repository)}["']?\s*$""")
    val repositoryLines = lines.indices.filter { repositoryPattern.matches(lines[it]) }
    check(repositoryLines.size == 1) { "expected exactly one repository line for $repository" }
    val repositoryLine = repositoryLines.single()
    val propertyIndent = indentation(lines[repositoryLine])
    val serviceIndent = propertyIndent - 2
    val serviceStart = (repositoryLine downTo 0).firstOrNull {
        indentation(lines[it]) == serviceIndent && lines[it].trimEnd().endsWith(":")
    } ?: error("service block start not found")
    val serviceEnd = ((serviceStart + 1) until lines.size).firstOrNull {
        val trimmed = lines[it].trim()
        trimmed.isNotEmpty() && !trimmed.startsWith("#") && indentation(lines[it]) <= serviceIndent
    } ?: lines.size

    if (family == "api-product") {
        val serviceVersionLines = (serviceStart until serviceEnd).filter {
            indentation(lines[it]) == propertyIndent && lines[it].trimStart().startsWith("version:")
        }
        check(serviceVersionLines.size == 1) { "expected exactly one service version" }
        val versionLine = serviceVersionLines.single()
        checkNotNewer(unquote(lines[versionLine].substringAfter("version:")), proposed, "service")
        lines[versionLine] = " ".repeat(propertyIndent) + "version: \"$proposed\""

        if (selectArtifacts(service, "api-product").isEmpty()) {
            val artifactsLine = (serviceStart until serviceEnd).firstOrNull {
                indentation(lines[it]) == propertyIndent && lines[it].trim() == "artifacts:"
            } ?: error("artifacts block not found")
            val insertion = ((artifactsLine + 1) until serviceEnd).firstOrNull {
                indentation(lines[it]) == propertyIndent &&
                    (lines[it].trimStart().startsWith("consumers:") || lines[it].trimStart().startsWith("docs:"))
            } ?: serviceEnd
            lines.add(insertion, " ".repeat(propertyIndent + 2) + "- type: api-product")
            lines.add(insertion + 1, " ".repeat(propertyIndent + 4) + "path: \".arcadia/api-product.yml\"")
            lines.add(insertion + 2, " ".repeat(propertyIndent + 4) + "artifactId: \"$repository\"")
        } else {
            check(selectArtifacts(service, "api-product").size == 1) { "duplicate api-product artifacts" }
        }
    } else {
        val types = if (family == "asyncapi") listOf("asyncapi-client", "asyncapi") else listOf(family)
        types.forEach { type ->
            if (type == "asyncapi-client" && selectArtifacts(service, type).isEmpty()) return@forEach
            replaceOrInsertArtifactVersion(lines, serviceStart, serviceEnd, type, proposed)
        }
    }

    Files.writeString(path, lines.joinToString("\n", postfix = "\n"))
    val updated = loadManifest(path)
    requireValidManifest(updated)
    val updatedService = selectService(updated, repository)
    if (family == "api-product") {
        check(updatedService.version == proposed) { "service version was not updated" }
        check(selectArtifacts(updatedService, "api-product").size == 1) { "api-product artifact was not created" }
    } else {
        val types = if (family == "asyncapi") listOf("asyncapi", "asyncapi-client") else listOf(family)
        types.forEach { type ->
            val artifacts = selectArtifacts(updatedService, type)
            if (type == "asyncapi-client" && artifacts.isEmpty()) return@forEach
            check(artifacts.single().version == proposed) { "$type version was not updated" }
        }
    }
}

fun main(args: Array<String>) {
    require(args.size == 4) {
        "usage: UpdateArchitectureManifest.kt <manifest> <service-repository> <artifact-family> <version>"
    }
    val path = Paths.get(args[0]).toAbsolutePath().normalize()
    require(Files.isRegularFile(path)) { "architecture manifest is missing: $path" }
    updateManifest(path, args[1], args[2], args[3])
}

