//REPOS central=https://repo.maven.apache.org/maven2/,central-snapshots=https://central.sonatype.com/repository/maven-snapshots/
//DEPS io.zenwave360.manifest:manifest-core-jvm:1.0.0-SNAPSHOT
//DEPS org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.10.2
//DEPS org.jetbrains.kotlin:kotlin-stdlib:2.3.0
//DEPS org.jetbrains.kotlin:kotlin-stdlib-common:2.0.21

import io.zenwave360.manifest.BlockingZenWaveManifestLoader;
import io.zenwave360.manifest.BlockingZenWaveManifestEditor;
import io.zenwave360.manifest.ManifestArtifactCatalog;
import io.zenwave360.manifest.ManifestArtifactSelection;
import io.zenwave360.manifest.ManifestArtifactSelector;
import io.zenwave360.manifest.ManifestArtifactVersionUpdate;
import io.zenwave360.manifest.ManifestDocumentTextUpdate;
import io.zenwave360.manifest.ManifestScalarTarget;
import io.zenwave360.manifest.ManifestScalarUpdate;
import io.zenwave360.manifest.ManifestService;
import io.zenwave360.manifest.ManifestValidation;
import io.zenwave360.manifest.ResolvedManifestArtifact;
import io.zenwave360.manifest.ZenWaveManifest;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

class ManifestTool {
    private static final String SERVICE_ALL = "service-all";
    private static final BlockingZenWaveManifestLoader LOADER = new BlockingZenWaveManifestLoader();
    private static final BlockingZenWaveManifestEditor EDITOR = new BlockingZenWaveManifestEditor();

    public static void main(String... args) throws Exception {
        if (args.length < 1) throw usage();
        switch (args[0]) {
            case "list" -> {
                if (args.length != 3) throw usage();
                System.out.println(toJson(resolveHttpInventory(args[1], args[2])));
            }
            case "resolve" -> {
                if (args.length != 4) throw usage();
                if (SERVICE_ALL.equals(args[3])) {
                    System.out.println(toJson(resolveHttpServiceInventory(args[1], args[2])));
                    break;
                }
                ManifestArtifactSelection selection = selectHttp(args[1], args[2], args[3]);
                if (selection instanceof ManifestArtifactSelection.ByType) {
                    System.out.println(toJson(selection.getArtifacts()));
                } else {
                    System.out.println(toJson(selection.getArtifacts().getFirst()));
                }
            }
            case "update" -> {
                if (args.length < 5 || (args.length - 3) % 2 != 0) throw usage();
                List<ManifestArtifactVersionUpdate> updates = new ArrayList<>();
                for (int index = 3; index < args.length; index += 2) {
                    ManifestArtifactSelector selector =
                        ManifestArtifactSelector.parseInRepository(args[2], args[index]);
                    updates.add(new ManifestArtifactVersionUpdate(selector, args[index + 1]));
                }
                update(
                    Path.of(args[1]).toAbsolutePath().normalize(),
                    updates
                );
            }
            case "update-service-version" -> {
                if (args.length != 4) throw usage();
                updateServiceVersion(
                    Path.of(args[1]).toAbsolutePath().normalize(),
                    args[2],
                    args[3]
                );
            }
            default -> throw usage();
        }
    }

    private static IllegalArgumentException usage() {
        return new IllegalArgumentException(
            "usage: ManifestTool.java list <manifest-http-uri> <repository> | " +
                "ManifestTool.java resolve <manifest-http-uri> <repository> <artifactId|type:<type>|asyncapi-all|service-all> | " +
                "ManifestTool.java update <manifest-file> <repository> " +
                "<artifactId|type:<type>|asyncapi-all> <version> [...] | " +
                "ManifestTool.java update-service-version <manifest-file> <repository> <version>"
        );
    }

    private static List<ResolvedManifestArtifact> resolveHttpInventory(String uri, String repository) {
        if (!uri.startsWith("https://") && !uri.startsWith("http://")) {
            throw new IllegalArgumentException("manifest must be read directly from an HTTP URI");
        }
        return resolveInventory(load(uri), repository);
    }

    private static ManifestArtifactSelection selectHttp(String uri, String repository, String selector) {
        if (!uri.startsWith("https://") && !uri.startsWith("http://")) {
            throw new IllegalArgumentException("manifest must be read directly from an HTTP URI");
        }
        ZenWaveManifest manifest = load(uri);
        return catalog(manifest).resolve(ManifestArtifactSelector.parseInRepository(repository, selector));
    }

    private static List<ResolvedManifestArtifact> resolveHttpServiceInventory(String uri, String repository) {
        List<ResolvedManifestArtifact> inventory = resolveHttpInventory(uri, repository);
        List<String> ownerRefs = inventory.stream().map(ResolvedManifestArtifact::getOwnerRef).distinct().toList();
        if (ownerRefs.size() != 1 || !(inventory.getFirst().getOwner() instanceof ManifestService)) {
            throw new IllegalArgumentException(
                "service-all requires exactly one service owner for repository " + repository
            );
        }
        return inventory;
    }

    private static ZenWaveManifest load(String uri) {
        return ManifestValidation.requireValid(LOADER.load(uri));
    }

    private static ManifestArtifactCatalog catalog(ZenWaveManifest manifest) {
        return ManifestArtifactCatalog.resolve(manifest, LOADER.getDelegate());
    }

    private static List<ResolvedManifestArtifact> resolveInventory(ZenWaveManifest manifest, String repository) {
        return catalog(manifest).repository(repository)
            .requireNotEmpty("repository " + repository)
            .requireUniqueArtifactIds()
            .getArtifacts();
    }

    private static String toJson(List<ResolvedManifestArtifact> values) {
        return "[" + String.join(",", values.stream().map(ManifestTool::toJson).toList()) + "]";
    }

    private static void update(
        Path path,
        List<ManifestArtifactVersionUpdate> updates
    ) throws Exception {
        if (!Files.isRegularFile(path)) throw new IllegalArgumentException("architecture manifest is missing: " + path);
        var result = EDITOR.updateArtifactVersions(
            path.toUri(),
            updates
        );
        persist(path, result.getDocuments());
    }

    private static void updateServiceVersion(Path path, String repository, String version) throws Exception {
        if (!Files.isRegularFile(path)) throw new IllegalArgumentException("architecture manifest is missing: " + path);
        List<ResolvedManifestArtifact> inventory = resolveInventory(load(path.toUri().toString()), repository);
        List<String> ownerRefs = inventory.stream().map(ResolvedManifestArtifact::getOwnerRef).distinct().toList();
        if (ownerRefs.size() != 1 || !(inventory.getFirst().getOwner() instanceof ManifestService)) {
            throw new IllegalArgumentException(
                "service version update requires exactly one service owner for repository " + repository
            );
        }
        var result = EDITOR.updateScalars(
            path.toUri(),
            List.of(new ManifestScalarUpdate(
                new ManifestScalarTarget.Owner(ownerRefs.getFirst()),
                "version",
                version
            ))
        );
        persist(path, result.getDocuments());
    }

    private static void persist(Path path, List<ManifestDocumentTextUpdate> documents) throws Exception {
        if (documents.size() > 1) {
            throw new IllegalStateException("ManifestTool cannot atomically persist updates across multiple source documents");
        }
        if (documents.isEmpty()) return;
        ManifestDocumentTextUpdate document = documents.getFirst();
        Path documentPath = Path.of(URI.create(document.getUri())).toAbsolutePath().normalize();
        if (!documentPath.equals(path)) {
            throw new IllegalStateException("selected artifact version is declared in a different document: " + documentPath);
        }
        String current = Files.readString(documentPath, StandardCharsets.UTF_8);
        if (!current.equals(document.getOriginalText())) {
            throw new IllegalStateException("manifest changed while artifact versions were being edited: " + documentPath);
        }
        Files.writeString(documentPath, document.getUpdatedText(), StandardCharsets.UTF_8);
    }

    private static String json(String value) {
        if (value == null) value = "";
        return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\"";
    }

    private static String toJson(ResolvedManifestArtifact value) {
        return "{" +
            "\"ownerId\":" + json(value.getOwnerId()) + "," +
            "\"ownerRef\":" + json(value.getOwnerRef()) + "," +
            "\"repository\":" + json(value.getRepository()) + "," +
            "\"type\":" + json(value.getArtifact().getType()) + "," +
            "\"path\":" + json(value.getArtifact().getPath()) + "," +
            "\"version\":" + json(value.getVersion()) + "," +
            "\"ownerVersion\":" + json(value.getOwner().getVersion()) + "," +
            "\"ownerKind\":" + json(value.getOwner() instanceof ManifestService ? "service" : "domain") + "," +
            "\"groupId\":" + json(value.getGroupId()) + "," +
            "\"groupPath\":" + json(value.getGroupId().replace('.', '/')) + "," +
            "\"artifactId\":" + json(value.getArtifactId()) +
            "}";
    }
}
