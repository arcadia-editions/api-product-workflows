# Run Kafka provisioning on your laptop

One command reads two AsyncAPI files and turns them into a Terraform plan with 31 Confluent Cloud resources. Nobody writes that Terraform by hand. It is generated from the contract into `target/terraform`, and it is thrown away and rebuilt on every run.

The idea behind it is simple. In an event driven system, part of the API lives in the broker. Partitions shape ordering, retention decides how far back a consumer can replay, schema compatibility decides how producers and consumers evolve, and ACLs decide who may talk to whom. When those things are written only in Terraform or in a console, they slowly drift away from the contract. So we write them once, in AsyncAPI, and let the platform follow.

This guide runs the whole thing from your machine against a real Confluent Cloud cluster, with [orders-checkout-api](https://github.com/arcadia-editions/orders-checkout-api) as the example. CI runs the same script, so what you see here is what the pipeline does.

1. [What gets provisioned, and what does not](#what-gets-provisioned-and-what-does-not)
2. [Before you start](#before-you-start)
3. [Reading the contract](#reading-the-contract)
4. [Generate and plan](#generate-and-plan)
5. [Check what the platform says](#check-what-the-platform-says)
6. [Change the contract, read the plan](#change-the-contract-read-the-plan)
7. [The same run, in GitHub Actions](#the-same-run-in-github-actions)

## What gets provisioned, and what does not

`orders-checkout-api` has two contracts, and they play very different roles.

`asyncapi.yml` describes what the service **owns**. It publishes four events, so for each of them we create the topic, register the schema, and give the service permission to write. `asyncapi-client.yml` describes what the service **consumes** from other teams. Those topics and schemas belong to their owners, so here we create nothing. We only ask for permission to read.

| Resource | From `asyncapi.yml` (owned) | From `asyncapi-client.yml` (consumed) |
| --- | --- | --- |
| Kafka topic, with partitions and config | Created, 4 topics | Not created |
| Schema subject in Schema Registry | Registered, 4 subjects | Not registered |
| Subject compatibility level | Set to `BACKWARD` | Not touched |
| Topic ACLs | `WRITE` and `DESCRIBE` per `send` operation | `READ` and `DESCRIBE` per `receive` operation |
| Schema Registry access | `DeveloperRead` role binding per subject | `DeveloperRead` role binding per subject |
| Service account for the principal | Created once, `orders_checkout` | Shared with the owned side |

Both files are merged into one bundle, one service account and one Terraform workspace, named `orders-checkout-api-develop`. The first plan adds 31 resources: 1 service account, 4 topics, 4 schemas, 4 subject configs, 12 topic ACLs and 6 role bindings.

The ACLs follow the operations. An operation with `action: send` becomes write access to its channel, and `action: receive` becomes read access. The principal comes from `x-principal` in the operation traits.

## Before you start

You need a few tools on your machine and two accounts in the cloud. The scripts are Bash, so on Windows run them from Git Bash.

- [JBang](https://www.jbang.dev), to run the ZenWave generator as `jbang zw`
- [Terraform](https://developer.hashicorp.com/terraform) 1.2 or newer
- The [Confluent CLI](https://docs.confluent.io/confluent-cli/current/overview.html)
- `jq`, optional, used to write a sanitized copy of the plan
- A Confluent Cloud account with one environment, one Kafka cluster and Schema Registry enabled
- An HCP Terraform account, where the state and the plan live

Clone the two repositories side by side, because the service calls the pipeline scripts with a relative path:

```bash
git clone https://github.com/arcadia-editions/api-product-workflows.git
git clone https://github.com/arcadia-editions/orders-checkout-api.git
```

### Bootstrap Confluent once

This step creates a service account for Terraform itself, with enough rights to manage the cluster and the Schema Registry subjects. You do it once, and then you only repeat it when you want to rotate keys.

1. Log in to Confluent Cloud with `confluent login`.
2. Create an HCP Terraform API token at `https://app.terraform.io/app/settings/tokens`.
3. Create `api-product-workflows/.env.terraform-cloud` by hand, with your organization and that token.
4. Run the bootstrap script from the pipeline repository:

```bash
cd api-product-workflows
./scripts/terraform/bootstrap-confluent-ci.sh --rotate-keys
```

The script reuses your environment and cluster, finds the Schema Registry, creates the `zenwave-ci-sa` service account, grants it `CloudClusterAdmin` on the cluster and `ResourceOwner` on all subjects, and writes three API keys into `.env.confluent-ci`. It does not print the secrets. Add `--github-secrets` when you also want them stored in GitHub for the pipeline.

```text
[bootstrap-confluent-ci] Reusing Kafka cluster 'arcadia_editions_cluster' (lkc-22r2gky)
[bootstrap-confluent-ci] Creating service account 'zenwave-ci-sa'
[bootstrap-confluent-ci] Granting CloudClusterAdmin on Kafka cluster 'lkc-22r2gky' to 'User:sa-m8n5oj1'
[bootstrap-confluent-ci] Granting ResourceOwner on all Schema Registry subjects in 'lsrc-0x9xzk6' to 'User:sa-m8n5oj1'
[bootstrap-confluent-ci] Wrote Terraform exports to '.env.confluent-ci'
```

Both `.env` files are in `.gitignore`. Keep it that way, they hold live credentials.

## Reading the contract

Everything the platform needs is already in the AsyncAPI file. We only have to know where to look.

### The channel becomes a topic

The channel `address` is the topic name. The Kafka binding gives partitions, replicas and topic configuration, and `x-env-server-overrides` lets each server ask for something smaller.

```yaml
channels:
  order-created-event-v1:
    address: orders-checkout.order-created.event.avro.v1
    messages:
      OrderCreatedEvent:
        $ref: "#/components/messages/OrderCreatedEvent"
    bindings:
      kafka:
        partitions: 3
        replicas: 3
        topicConfiguration:
          cleanup.policy: [ "delete" ]
          retention.ms: 604800000
          retention.bytes: 1000000000
          delete.retention.ms: 86400000
          max.message.bytes: 1048588
        x-env-server-overrides:
          develop:
            partitions: 1
            replicas: 1
            topicConfiguration:
              retention.ms: 604800
```

We run against the `develop` server, so the override wins. Each topic gets 1 partition, and its `retention.ms` comes from the override, while the other settings come from the base block. This is how a single contract can describe a small topic for development and a larger one for production.

### The message becomes a schema subject

Each message points to an Avro file and carries a trait with its Schema Registry settings:

```yaml
KafkaSchemaCompatibility:
  bindings:
    kafka:
      bindingVersion: '0.5.0'
      schemaIdLocation: 'payload'
      schemaLookupStrategy: 'TopicNameStrategy'
      x-compatibility: 'BACKWARD'
```

The generator registers `avro/OrderCreated.avsc` under the subject `orders-checkout.order-created.event.avro.v1-OrderCreatedEvent-value` and sets its compatibility level to `BACKWARD`. With `BACKWARD`, a new version of the schema must still read data written with the old one.

### The operation becomes an ACL

The operations say who does what. All four owned operations are `send`, and they share one trait:

```yaml
operations:
  onOrderCreated:
    action: send
    channel:
      $ref: "#/channels/order-created-event-v1"
    traits:
    - $ref: "#/components/operationTraits/clientIdAndPrincipal"

components:
  operationTraits:
    clientIdAndPrincipal:
      bindings:
        kafka:
          clientId: { const: orders_checkout }
          groupId: { const: orders_checkout }
          x-principal: orders_checkout
```

`x-principal` names the identity that runs the service. The generator creates a service account with that name and grants it `WRITE` and `DESCRIBE` on each topic it sends to. `groupId` names the consumer group the service uses when it reads.

### The client file only asks for access

`asyncapi-client.yml` does not define channels of its own. It points at the channels in the owners' contracts, so the topic names and schemas stay where they belong:

```yaml
channels:
  payment-authorized-event-v1:
    $ref: https://raw.githubusercontent.com/arcadia-editions/payments-processing-api/main/asyncapi.yml#/channels/payment-authorized-event-v1
  stock-released-event-v1:
    $ref: https://raw.githubusercontent.com/arcadia-editions/catalog-inventory-api/main/asyncapi.yml#/channels/stock-released-event-v1

operations:
  onPaymentAuthorizedEvent:
    action: receive
    channel:
      $ref: "#/channels/payment-authorized-event-v1"
    traits:
    - $ref: "#/components/operationTraits/clientIdAndPrincipal"
```

Because the operation is `receive` and the channel is a `$ref` to another team's contract, the generator emits `READ` and `DESCRIBE` on `payments-processing.payment-authorized.event.avro.v1` and `catalog-inventory.stock-released.event.avro.v1`, plus a `DeveloperRead` role binding on their subjects. It does not create those topics, and it does not register those schemas. The payments team and the inventory team own them.

## Generate and plan

Go into the service repository, load the credentials, and run the local provisioning script with the name of the server:

```bash
cd orders-checkout-api
source ../api-product-workflows/.env.confluent-ci
source ../api-product-workflows/.env.terraform-cloud

ASYNCAPI_FILE="asyncapi.yml,asyncapi-client.yml" \
  ../api-product-workflows/scripts/terraform/provision-kafka-local.sh develop
```

`ASYNCAPI_FILE` is optional. When it is not set, the script picks up `asyncapi.yml` and `asyncapi-client.yml` on its own. Writing it out makes the bundle visible on screen, which helps when you show it to someone.

The script does the work in four steps:

1. It checks that it runs inside a `*-api` repository and that `jbang` and `terraform` are installed.
2. It calls [`provision-kafka.sh`](../scripts/terraform/provision-kafka.sh), which runs the ZenWave generator, `jbang zw -p AsyncAPIOpsGeneratorPlugin templates=TerraformConfluent serviceAccountMode=managed server=develop`. The generator writes `topics.tf`, `schemas.tf` and `acls.tf` into `target/terraform`, and copies the Avro files next to them.
3. It copies the shared overlay from [`terraform/common`](../terraform/common): the provider, the variables, the defaults and a `cloud.tf` that points at the workspace `orders-checkout-api-develop`.
4. It runs `terraform init`, `terraform validate` and `terraform plan`, and saves the plan as `tfplan.txt` and `tfplan.sanitized.json`.

The plan runs in HCP Terraform, so the state never lives on your laptop. On a fresh cluster, the end of the output reads:

```text
  # confluent_kafka_topic.orders_checkout_order_created_event_avro_v1 will be created
  # confluent_schema.orders_checkout_order_created_event_avro_v1_OrderCreatedEvent_value will be created
  # confluent_kafka_acl.TOPIC_orders_checkout_order_created_event_avro_v1_orders_checkout_Write_LITERAL will be created
  # confluent_kafka_acl.TOPIC_payments_processing_payment_authorized_event_avro_v1_orders_checkout_Read_LITERAL will be created
  # confluent_role_binding.schema_registry_payments_processing_payment_authorized_event_avro_v1_PaymentAuthorizedMessage_value_orders_checkout_DeveloperRead will be created
  ...
Plan: 31 to add, 0 to change, 0 to destroy.
```

Read the plan before anything else. You will find topics, schemas and subject configs only for the four `orders-checkout` topics, and only ACLs and role bindings for the two topics we consume. That is the whole story of owned and client contracts, written by Terraform.

### Apply

By default the script only plans. To apply, run it again with `APPLY_MODE=true`:

```bash
APPLY_MODE=true \
  ../api-product-workflows/scripts/terraform/provision-kafka-local.sh develop
```

The generated Terraform looks like this. Notice that the principal is a reference to the service account, never a hard coded id:

```hcl
resource "confluent_kafka_acl" "TOPIC_orders_checkout_order_created_event_avro_v1_orders_checkout_Write_LITERAL" {
  resource_type = "TOPIC"
  resource_name = "orders-checkout.order-created.event.avro.v1"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.orders_checkout.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
}
```

## Check what the platform says

Terraform says it is done, but the proof is in the cluster. Ask Confluent Cloud directly, with the CLI, and compare each answer with the contract. Replace the cluster id with yours.

The topics, with their partitions and configuration:

```bash
confluent kafka topic list --cluster lkc-22r2gky | grep orders-checkout
confluent kafka topic describe orders-checkout.order-created.event.avro.v1 --cluster lkc-22r2gky
```

The schema subjects and their compatibility:

```bash
confluent schema-registry subject list --prefix orders-checkout
confluent schema-registry subject describe orders-checkout.order-created.event.avro.v1-OrderCreatedEvent-value
confluent schema-registry configuration describe --subject orders-checkout.order-created.event.avro.v1-OrderCreatedEvent-value
```

The service account and its ACLs. You should see `WRITE` and `DESCRIBE` on the four owned topics, and `READ` and `DESCRIBE` on the two consumed ones:

```bash
confluent iam service-account list | grep orders_checkout
confluent kafka acl list --cluster lkc-22r2gky --service-account sa-xxxxxx
```

Now look for what is absent. There is no topic called `payments-processing.payment-authorized.event.avro.v1` in our workspace, and no schema registered by us under that name. If the payments team has not provisioned their topic yet, our `READ` ACL still exists and simply waits for it.

## Change the contract, read the plan

The first apply is only the beginning. The real value shows up on the second run, when the contract changes and the plan tells you what that change means for the platform.

### A config change

Open `asyncapi.yml` and change the `develop` retention of one topic, for example `order-created-event-v1`, to one day:

```yaml
        x-env-server-overrides:
          develop:
            topicConfiguration:
              retention.ms: 86400000
```

Run the script again, without `APPLY_MODE`. Only that topic changes, in place:

```text
  # confluent_kafka_topic.orders_checkout_order_created_event_avro_v1 will be updated in-place
      ~ config = {
          ~ "retention.ms" = "604800" -> "86400000"
        }
Plan: 0 to add, 1 to change, 0 to destroy.
```

The other three topics, the schemas and the ACLs do not appear. The plan is narrow because the change was narrow. This is the moment where drift becomes visible: a reviewer sees one line in the contract and one line in the plan, and both say the same thing.

### A new consumer

Now add a `receive` operation to `asyncapi-client.yml`, pointing at another channel owned by someone else. The next plan adds only two topic ACLs and one role binding for the new topic. Again, no topic and no schema, because we do not own them.

### Drift from the other side

If someone changes the retention by hand in the Confluent console, the next plan shows the same diff in reverse, and the apply puts the value back to what the contract says. The contract wins, because it is the only place where the intent is written.

### Clean up

To remove everything this guide created, destroy from the generated folder with both `.env` files loaded:

```bash
cd orders-checkout-api/target/terraform
terraform destroy
```

Destroy first, then delete the HCP Terraform workspace if you want a clean slate. The script [`wipe-terraform-workspaces.sh`](../scripts/terraform/wipe-terraform-workspaces.sh) deletes every workspace in the organization, but it does not destroy the resources they manage, so running it alone leaves topics and ACLs behind with no state to track them.

## The same run, in GitHub Actions

The local script is a thin wrapper around [`provision-kafka.sh`](../scripts/terraform/provision-kafka.sh), and the pipeline calls exactly the same file.

In daily work nobody provisions by hand. The service's normal `artifact-ci.yml` calls the shared [`artifact-ci.yml`](../.github/workflows/artifact-ci.yml), and when an AsyncAPI contract changes it plans on every push and pull request with [`provision-kafka-plan.yml`](../.github/workflows/provision-kafka-plan.yml), and applies on every push to `develop` with [`provision-kafka-develop.yml`](../.github/workflows/provision-kafka-develop.yml). That workflow:

1. Checks out the `develop` branch of the service repository and this pipeline repository side by side.
2. Installs Java 21, JBang, the ZenWave CLI alias and Terraform.
3. Asks the [architecture manifest](https://github.com/arcadia-editions/arcadia-editions-architecture/blob/main/zenwave-architecture.yml) which contracts belong to the service. For `orders-checkout-api`, the `asyncapi-all` bundle resolves to `asyncapi.yml` and `asyncapi-client.yml`, so CI never needs `ASYNCAPI_FILE`.
4. Runs `provision-kafka.sh` with those files and the `develop` server.
5. Runs `terraform init`, `validate` and `plan` in the workspace `orders-checkout-api-develop`, the same workspace your local run uses.
6. Applies the plan right away. There is no approval gate on `develop`.
7. Uploads the generated Terraform as a build artifact, so every run can be inspected later.

The credentials come from the GitHub secrets and variables that `bootstrap-confluent-ci.sh --github-secrets` wrote for you. CI also sets `TF_VAR_provisioned_from` to `develop@<commit sha>`, so the workspace output tells you which commit the platform came from.

When you want to provision without a commit, each service also has a small manual entry point, [`orders-checkout-api/.github/workflows/provision-kafka.yml`](https://github.com/arcadia-editions/orders-checkout-api/blob/main/.github/workflows/provision-kafka.yml):

```bash
gh workflow run provision-kafka.yml --repo arcadia-editions/orders-checkout-api
```

Since local and CI share one workspace, run one or the other for `develop`, never both at the same moment. HCP Terraform locks the state, and the second run waits.

Releases and promotion to `pre` and `prod` are described in the [README](../README.md). The generator options are in the [AsyncAPI Ops plugin docs](https://www.zenwave360.io/zenwave-sdk/plugins/asyncapi-ops/).
