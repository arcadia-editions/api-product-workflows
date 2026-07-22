//DEPS com.fasterxml.jackson.core:jackson-databind:2.19.2
//DEPS com.fasterxml.jackson.dataformat:jackson-dataformat-yaml:2.19.2

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory
import java.nio.file.Files
import java.nio.file.Paths

fun main(args: Array<String>) {
    require(args.size == 1) { "usage: YamlToJson.kt <yaml-file>" }
    val path = Paths.get(args[0]).toAbsolutePath().normalize()
    require(Files.isRegularFile(path)) { "YAML file does not exist: $path" }
    val yaml = ObjectMapper(YAMLFactory())
    val json = ObjectMapper()
    val document = yaml.readTree(path.toFile())
    println(json.writeValueAsString(document))
}

