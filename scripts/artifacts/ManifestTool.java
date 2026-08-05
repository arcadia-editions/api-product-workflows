//REPOS central=https://repo.maven.apache.org/maven2/,central-snapshots=https://central.sonatype.com/repository/maven-snapshots/
//DEPS io.zenwave360.manifest:manifest-core-jvm:1.0.0-SNAPSHOT
//DEPS org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2
//DEPS org.jetbrains.kotlin:kotlin-stdlib:2.3.0
//DEPS org.jetbrains.kotlin:kotlin-stdlib-common:2.0.21

import io.zenwave360.manifest.BlockingZenWaveManifestLoader;
import io.zenwave360.manifest.ManifestArtifact;
import io.zenwave360.manifest.ManifestArtifactOwner;
import io.zenwave360.manifest.ManifestResolutionContext;
import io.zenwave360.manifest.ZenWaveManifest;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

class ManifestTool {
    private static final BlockingZenWaveManifestLoader LOADER = new BlockingZenWaveManifestLoader();

    public static void main(String... args) throws Exception {
        if (args.length < 1) throw usage();
        switch (args[0]) {
            case "list" -> {
                if (args.length != 3) throw usage();
                System.out.println(toJson(resolveHttpInventory(args[1], args[2])));
            }
            case "resolve" -> {
                if (args.length != 4) throw usage();
                List<ResolvedArtifact> matches = resolveHttpInventory(args[1], args[2]).stream()
                    .filter(value -> value.artifactId().equals(args[3])).toList();
                if (matches.size() != 1) {
                    throw new IllegalStateException(
                        "expected artifactId " + args[3] + " exactly once in " + args[2] + ", found " + matches.size()
                    );
                }
                System.out.println(matches.getFirst().toJson());
            }
            case "update" -> {
                if (args.length != 6) throw usage();
                update(args[1], Path.of(args[2]).toAbsolutePath().normalize(), args[3], args[4], args[5]);
            }
            default -> throw usage();
        }
    }

    private static IllegalArgumentException usage() {
        return new IllegalArgumentException(
            "usage: ManifestTool.java <list|resolve> <manifest-http-uri> <repository> [artifactId] | " +
                "ManifestTool.java update <manifest-source> <manifest-file> <repository> <artifactId> <version>"
        );
    }

    private static List<ResolvedArtifact> resolveHttpInventory(String uri, String repository) {
        if (!uri.startsWith("https://") && !uri.startsWith("http://")) {
            throw new IllegalArgumentException("manifest must be read directly from an HTTP URI");
        }
        return resolveInventory(load(uri), repository);
    }

    private static List<ResolvedArtifact> resolveUpdateInventory(String source, String repository) {
        if (source.startsWith("https://") || source.startsWith("http://")) {
            return resolveHttpInventory(source, repository);
        }
        Path path = Path.of(source).toAbsolutePath().normalize();
        if (!Files.isRegularFile(path)) {
            throw new IllegalArgumentException("architecture manifest source is missing: " + path);
        }
        return resolveInventory(load(path.toUri().toString()), repository);
    }

    private static ZenWaveManifest load(String uri) {
        ZenWaveManifest manifest = LOADER.load(uri);
        List<?> errors = manifest.getDiagnostics().stream()
            .filter(value -> value.getSeverity().toString().equals("ERROR")).toList();
        if (!errors.isEmpty()) throw new IllegalStateException("manifest diagnostics: " + errors);
        return manifest;
    }

    private static List<ResolvedArtifact> resolveInventory(ZenWaveManifest manifest, String repository) {
        List<ManifestArtifactOwner> owners = manifest.getArtifactOwners().stream()
            .filter(owner -> repository.equals(owner.getRepository())).toList();
        if (owners.size() != 1) {
            throw new IllegalStateException(
                "expected exactly one artifact owner for repository " + repository + ", found " + owners.size()
            );
        }
        ManifestArtifactOwner owner = owners.getFirst();
        List<ResolvedArtifact> resolved = owner.getArtifacts().stream().map(artifact -> {
            ManifestResolutionContext context = LOADER.getDelegate().artifactResolutionContext(manifest, owner, artifact);
            if (context.getGroupId() == null || context.getArtifactId() == null) {
                throw new IllegalStateException("ManifestCore did not resolve coordinates for " + artifact.getPath());
            }
            return new ResolvedArtifact(owner, artifact, context.getGroupId(), context.getArtifactId());
        }).toList();
        Map<String, Integer> counts = new HashMap<>();
        resolved.forEach(value -> counts.merge(value.artifactId(), 1, Integer::sum));
        List<String> collisions = counts.entrySet().stream()
            .filter(entry -> entry.getValue() > 1).map(Map.Entry::getKey).sorted().toList();
        if (!collisions.isEmpty()) {
            throw new IllegalStateException(
                "duplicate resolved artifactId(s) for " + repository + ": " + String.join(", ", collisions)
            );
        }
        return resolved;
    }

    private static String toJson(List<ResolvedArtifact> values) {
        return "[" + String.join(",", values.stream().map(ResolvedArtifact::toJson).toList()) + "]";
    }

    private static void update(String source, Path path, String repository, String artifactId, String version) throws Exception {
        if (!Files.isRegularFile(path)) throw new IllegalArgumentException("architecture manifest is missing: " + path);
        ResolvedArtifact selected = resolveUpdateInventory(source, repository).stream()
            .filter(value -> value.artifactId().equals(artifactId)).findFirst()
            .orElseThrow(() -> new IllegalStateException("artifactId not found: " + artifactId));

        List<String> lines = new ArrayList<>(Files.readAllLines(path));
        Pattern repositoryPattern = Pattern.compile(
            "^\\s+repository:\\s*[\"']?" + Pattern.quote(repository) + "[\"']?\\s*$"
        );
        List<Integer> repositoryLines = new ArrayList<>();
        for (int index = 0; index < lines.size(); index++) {
            if (repositoryPattern.matcher(lines.get(index)).matches()) repositoryLines.add(index);
        }
        if (repositoryLines.size() != 1) {
            throw new IllegalStateException("expected exactly one repository line for " + repository);
        }
        int repositoryLine = repositoryLines.getFirst();
        int propertyIndent = indentation(lines.get(repositoryLine));
        int ownerIndent = propertyIndent - 2;
        int ownerStart = -1;
        for (int index = repositoryLine; index >= 0; index--) {
            if (indentation(lines.get(index)) == ownerIndent && lines.get(index).trim().endsWith(":")) {
                ownerStart = index;
                break;
            }
        }
        if (ownerStart < 0) throw new IllegalStateException("artifact owner block not found");
        int ownerEnd = lines.size();
        for (int index = ownerStart + 1; index < lines.size(); index++) {
            String trimmed = lines.get(index).trim();
            if (!trimmed.isEmpty() && !trimmed.startsWith("#") && indentation(lines.get(index)) <= ownerIndent) {
                ownerEnd = index;
                break;
            }
        }
        List<ArtifactEntry> entries = artifactEntries(lines, ownerStart, ownerEnd).stream().filter(entry ->
            selected.artifact().getType().equals(artifactProperty(lines, entry, "type")) &&
                selected.artifact().getPath().equals(artifactProperty(lines, entry, "path"))
        ).toList();
        if (entries.size() != 1) throw new IllegalStateException("expected one YAML entry for " + artifactId);
        ArtifactEntry entry = entries.getFirst();
        List<Integer> versionLines = new ArrayList<>();
        for (int index = entry.start(); index < entry.finish(); index++) {
            if (lines.get(index).trim().startsWith("version:")) versionLines.add(index);
        }
        if (versionLines.size() != 1) throw new IllegalStateException("expected one version field for " + artifactId);
        int versionLine = versionLines.getFirst();
        lines.set(versionLine, " ".repeat(indentation(lines.get(versionLine))) + "version: \"" + version + "\"");
        Files.writeString(path, String.join("\n", lines) + "\n");

        if (!version.equals(unquote(lines.get(versionLine).substring(lines.get(versionLine).indexOf(':') + 1)))) {
            throw new IllegalStateException("manifest version update did not persist");
        }
    }

    private static List<ArtifactEntry> artifactEntries(List<String> lines, int ownerStart, int ownerEnd) {
        List<Integer> starts = new ArrayList<>();
        for (int index = ownerStart; index < ownerEnd; index++) {
            if (lines.get(index).stripLeading().startsWith("- type:")) starts.add(index);
        }
        List<ArtifactEntry> result = new ArrayList<>();
        for (int index = 0; index < starts.size(); index++) {
            result.add(new ArtifactEntry(starts.get(index), index + 1 < starts.size() ? starts.get(index + 1) : ownerEnd));
        }
        return result;
    }

    private static String artifactProperty(List<String> lines, ArtifactEntry entry, String name) {
        List<String> values = new ArrayList<>();
        for (int index = entry.start(); index < entry.finish(); index++) {
            String trimmed = lines.get(index).stripLeading();
            String listPrefix = "- " + name + ":";
            String propertyPrefix = name + ":";
            if (trimmed.startsWith(listPrefix)) values.add(trimmed.substring(listPrefix.length()));
            else if (trimmed.startsWith(propertyPrefix)) values.add(trimmed.substring(propertyPrefix.length()));
        }
        if (values.size() > 1) throw new IllegalStateException("duplicate " + name + " property");
        return values.isEmpty() ? null : unquote(values.getFirst());
    }

    private static int indentation(String value) {
        int index = 0;
        while (index < value.length() && Character.isWhitespace(value.charAt(index))) index++;
        return index;
    }

    private static String unquote(String value) {
        String result = value.trim();
        if (result.length() >= 2 && ((result.startsWith("\"") && result.endsWith("\"")) ||
            (result.startsWith("'") && result.endsWith("'")))) {
            return result.substring(1, result.length() - 1);
        }
        return result;
    }

    private static String json(String value) {
        if (value == null) value = "";
        return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\"";
    }

    private record ArtifactEntry(int start, int finish) {}

    private record ResolvedArtifact(
        ManifestArtifactOwner owner,
        ManifestArtifact artifact,
        String groupId,
        String artifactId
    ) {
        String toJson() {
            return "{" +
                "\"ownerId\":" + json(owner.getId()) + "," +
                "\"ownerRef\":" + json(owner.getArtifactOwnerRef()) + "," +
                "\"repository\":" + json(owner.getRepository()) + "," +
                "\"type\":" + json(artifact.getType()) + "," +
                "\"path\":" + json(artifact.getPath()) + "," +
                "\"version\":" + json(artifact.getResolvedVersion()) + "," +
                "\"groupId\":" + json(groupId) + "," +
                "\"groupPath\":" + json(groupId.replace('.', '/')) + "," +
                "\"artifactId\":" + json(artifactId) +
                "}";
        }
    }
}
