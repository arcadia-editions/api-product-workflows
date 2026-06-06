output "kafka_cluster_id" {
  description = "Kafka cluster ID used by the generated resources."
  value       = var.kafka_id
}

output "schema_registry_id" {
  description = "Schema Registry cluster ID used by the generated resources."
  value       = var.schema_registry_id
}

output "default_compatibility" {
  description = "Default compatibility configured for generated schemas."
  value       = var.default_compatibility
}
