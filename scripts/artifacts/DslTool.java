//REPOS central=https://repo.maven.apache.org/maven2/,central-snapshots=https://central.sonatype.com/repository/maven-snapshots/
//DEPS io.zenwave360.dsl:dsl-kotlin-jvm:1.9.0-SNAPSHOT

import io.zenwave360.language.zdl.ZdlEditor;
import io.zenwave360.language.zdl.ZdlModel;
import io.zenwave360.language.zdl.ZdlParser;
import io.zenwave360.language.zfl.ZflModel;
import io.zenwave360.language.zfl.ZflParser;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

class DslTool {
    public static void main(String... args) throws Exception {
        if (args.length < 3) {
            throw new IllegalArgumentException(
                "usage: DslTool.java <validate|read-version|write-version> <zdl|zfl> <file> [version]"
            );
        }
        String command = args[0];
        String type = args[1];
        Path path = Path.of(args[2]).toAbsolutePath().normalize();
        if (!Files.isRegularFile(path)) {
            throw new IllegalArgumentException("DSL file does not exist: " + path);
        }
        if (!type.equals("zdl") && !type.equals("zfl")) {
            throw new IllegalArgumentException("unsupported DSL type: " + type);
        }

        switch (command) {
            case "validate" -> validate(type, path);
            case "read-version" -> System.out.println(readVersion(type, path));
            case "write-version" -> {
                if (args.length != 4 || args[3].isBlank()) {
                    throw new IllegalArgumentException("write-version requires a non-empty version");
                }
                writeVersion(type, path, args[3]);
                if (!readVersion(type, path).equals(args[3])) {
                    throw new IllegalStateException("version update did not persist: " + path);
                }
            }
            default -> throw new IllegalArgumentException("unsupported command: " + command);
        }
    }

    private static void validate(String type, Path path) throws Exception {
        ParseOutcome outcome = parse(type, path);
        outcome.problems().forEach(problem -> printProblem(path, type, problem));
        if (!outcome.parserDiagnostics().isBlank()) {
            System.err.print(outcome.parserDiagnostics());
        }
        if (!outcome.parserDiagnostics().isBlank() || !outcome.problems().isEmpty()) {
            System.exit(1);
        }
        System.out.println(path + " parsed successfully with the ZenWave " + type.toUpperCase() + " parser");
    }

    private static ParseOutcome parse(String type, Path path) throws Exception {
        PrintStream originalError = System.err;
        ByteArrayOutputStream parserErrors = new ByteArrayOutputStream();
        Map<String, Object> model;
        List<Map<String, Object>> problems;
        try (PrintStream capturedError = new PrintStream(parserErrors, true, StandardCharsets.UTF_8)) {
            System.setErr(capturedError);
            String source = Files.readString(path);
            if (type.equals("zdl")) {
                ZdlModel zdl = new ZdlParser().parseModel(source);
                model = zdl;
                problems = zdl.getProblems();
            } else {
                ZflModel zfl = new ZflParser().parseModel(source);
                model = zfl;
                problems = zfl.getProblems();
            }
        } finally {
            System.setErr(originalError);
        }
        return new ParseOutcome(model, new ArrayList<>(problems), parserErrors.toString(StandardCharsets.UTF_8));
    }

    private static String readVersion(String type, Path path) throws Exception {
        Object configValue = parse(type, path).model().get("config");
        if (!(configValue instanceof Map<?, ?> config)) {
            throw new IllegalArgumentException(type.toUpperCase() + " config block is missing: " + path);
        }
        Object value = config.get("version");
        if (!(value instanceof String version) || version.isBlank()) {
            throw new IllegalArgumentException(type.toUpperCase() + " config.version must be a non-empty string: " + path);
        }
        return version;
    }

    private static void writeVersion(String type, Path path, String version) throws Exception {
        if (type.equals("zdl")) {
            new ZdlEditor().setConfigString(path, "version", version);
            return;
        }
        List<String> lines = Files.readAllLines(path);
        int configStart = -1;
        int configIndent = -1;
        int versionLine = -1;
        for (int index = 0; index < lines.size(); index++) {
            String line = lines.get(index);
            String trimmed = line.trim();
            int indent = indentation(line);
            if (configStart < 0 && trimmed.equals("config {")) {
                configStart = index;
                configIndent = indent;
                continue;
            }
            if (configStart >= 0 && indent == configIndent && trimmed.equals("}")) {
                break;
            }
            if (configStart >= 0 && trimmed.startsWith("version ")) {
                if (versionLine >= 0) {
                    throw new IllegalArgumentException("duplicate ZFL config.version: " + path);
                }
                versionLine = index;
            }
        }
        if (configStart < 0 || versionLine < 0) {
            throw new IllegalArgumentException("ZFL config.version is missing: " + path);
        }
        lines.set(versionLine, " ".repeat(indentation(lines.get(versionLine))) + "version \"" + version + "\"");
        Files.writeString(path, String.join("\n", lines) + "\n");
    }

    private static int indentation(String value) {
        int index = 0;
        while (index < value.length() && Character.isWhitespace(value.charAt(index))) index++;
        return index;
    }

    private static void printProblem(Path path, String type, Map<String, Object> problem) {
        int[] location = problem.get("location") instanceof int[] value ? value : null;
        String line = location != null && location.length > 2 ? Integer.toString(location[2]) : "?";
        String character = location != null && location.length > 3 ? Integer.toString(location[3] + 1) : "?";
        String modelPath = String.valueOf(problem.getOrDefault("path", ""));
        String message = String.valueOf(problem.getOrDefault("message", "unknown validation error"));
        System.err.printf("%s:%s:%s: %s error [%s]: %s%n", path, line, character, type.toUpperCase(), modelPath, message);
    }

    private record ParseOutcome(
        Map<String, Object> model,
        List<Map<String, Object>> problems,
        String parserDiagnostics
    ) {}
}
