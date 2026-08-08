//REPOS central=https://repo.maven.apache.org/maven2/,central-snapshots=https://central.sonatype.com/repository/maven-snapshots/
//DEPS io.zenwave360.jsonrefparser:json-schema-ref-parser-kmp-jvm:0.9.23

import io.zenwave360.jsonrefparser.JavaRefParser;
import io.zenwave360.jsonrefparser.io.FileLoader;
import io.zenwave360.jsonrefparser.model.OnCircular;
import io.zenwave360.jsonrefparser.model.OnMissing;
import io.zenwave360.jsonrefparser.model.ParsedDocument;
import io.zenwave360.jsonrefparser.model.RefParserOptions;

import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

class RefResolverTool {
    public static void main(String... args) throws Exception {
        if (args.length != 3 || !args[0].equals("resolve-refs")) {
            throw new IllegalArgumentException("usage: RefResolverTool.java resolve-refs <root> <relative-path>");
        }
        Path root = Path.of(args[1]).toAbsolutePath().normalize();
        Path entry = root.resolve(args[2]).normalize();
        if (!Files.isRegularFile(entry)) {
            throw new IllegalArgumentException("artifact file does not exist: " + entry);
        }

        ParsedDocument doc = JavaRefParser.from(entry.toUri())
            .withLoaders(new FileLoader())
            .withOptions(new RefParserOptions(OnCircular.RESOLVE, OnMissing.SKIP))
            .dereference()
            .getParsedDocument();

        String entryUri = entry.toUri().toString();
        List<String> relativePaths = new ArrayList<>();
        for (String uri : doc.getDocumentLocations().keySet()) {
            if (uri.equals(entryUri) || !uri.startsWith("file:")) {
                continue;
            }
            Path file = Path.of(URI.create(uri)).toAbsolutePath().normalize();
            if (!file.startsWith(root)) {
                throw new IllegalStateException("referenced file escapes artifact root: " + file);
            }
            relativePaths.add(root.relativize(file).toString().replace('\\', '/'));
        }
        relativePaths.sort(String::compareTo);
        relativePaths.forEach(System.out::println);
    }
}
