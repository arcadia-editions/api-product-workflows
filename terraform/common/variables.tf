variable "confluent_cloud_api_key" {
  description = "Confluent Cloud control-plane API key."
  type        = string
  sensitive   = true
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud control-plane API secret."
  type        = string
  sensitive   = true
}

variable "kafka_id" {
  description = "Target Kafka cluster ID for topic and ACL operations."
  type        = string
}

variable "kafka_rest_endpoint" {
  description = "Kafka REST endpoint for the target cluster."
  type        = string
}

variable "kafka_api_key" {
  description = "Kafka API key for the target cluster."
  type        = string
  sensitive   = true
}

variable "kafka_api_secret" {
  description = "Kafka API secret for the target cluster."
  type        = string
  sensitive   = true
}

variable "schema_registry_id" {
  description = "Schema Registry cluster ID used by the target environment."
  type        = string
}

variable "schema_registry_rest_endpoint" {
  description = "Schema Registry REST endpoint for the target environment."
  type        = string
}

variable "schema_registry_api_key" {
  description = "Schema Registry API key for the target environment."
  type        = string
  sensitive   = true
}

variable "schema_registry_api_secret" {
  description = "Schema Registry API secret for the target environment."
  type        = string
  sensitive   = true
}

variable "default_compatibility" {
  description = "Default schema compatibility applied when the generated resources do not override it."
  type        = string
}
