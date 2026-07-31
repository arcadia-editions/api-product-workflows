//DEPS io.zenwave360.dsl:dsl-kotlin-jvm:1.8.0

import io.zenwave360.language.zdl.ZdlModel;
import io.zenwave360.language.zdl.ZdlParser;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

class ValidateZdl {
    public static void main(String... args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ValidateZdl.java <domain-model.zdl>");
        }

        Path path = Path.of(args[0]).toAbsolutePath().normalize();
        if (!Files.isRegularFile(path)) {
            throw new IllegalArgumentException("ZDL file does not exist: " + path);
        }

        PrintStream originalError = System.err;
        ByteArrayOutputStream parserErrors = new ByteArrayOutputStream();
        ZdlModel model;
        try (PrintStream capturedError = new PrintStream(parserErrors, true, StandardCharsets.UTF_8)) {
            System.setErr(capturedError);
            model = new ZdlParser().parseModel(Files.readString(path));
        } finally {
            System.setErr(originalError);
        }

        String parserDiagnostics = parserErrors.toString(StandardCharsets.UTF_8);
        if (!parserDiagnostics.isBlank()) {
            originalError.print(parserDiagnostics);
        }

        List<Map<String, Object>> problems = model.getProblems();
        for (Map<String, Object> problem : problems) {
            int[] location = problem.get("location") instanceof int[] value ? value : null;
            String line = location != null && location.length > 2 ? Integer.toString(location[2]) : "?";
            String character = location != null && location.length > 3 ? Integer.toString(location[3] + 1) : "?";
            String modelPath = String.valueOf(problem.getOrDefault("path", ""));
            String message = String.valueOf(problem.getOrDefault("message", "unknown ZDL validation error"));
            System.err.printf("%s:%s:%s: ZDL error [%s]: %s%n", path, line, character, modelPath, message);
        }

        if (!parserDiagnostics.isBlank() || !problems.isEmpty()) {
            System.exit(1);
        }

        System.out.println(path + " parsed successfully with ZenWave ZDL parser 1.8.0");
    }
}
