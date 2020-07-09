terraform {
  required_version = ">= 0.12.0"
  required_providers {
    aws = "~> 2.67"
  }
}

locals {

  spinnaker_version = "1.9.5"
  redis_port        = 6379
  tags = {
    spinnaker_version = local.spinnaker_version
    managed_by        = "terraform"
  }
  # https://www.spinnaker.io/reference/architecture/
  services = {
    clouddriver = {
      port = 7002
      backends = [
        "fiat",
      ]
    }
    deck = {
      port = 9000
      backends = [
        "gate",
      ]
    }
    echo = {
      port = 8089
      backends = [
        "front50",
        "orca",
      ]
    }
    fiat = {
      port     = 7003
      backends = []
    }
    front50 = {
      port     = 8080
      backends = ["fiat"]
    }
    gate = {
      port = 8084
      backends = [
        "clouddriver",
        "echo",
        "fiat",
        "front50",
        "igor",
        "kayenta",
        "orca",
        "rosco",
      ]
    }
    igor = {
      port = 8088
      backends = [
        "echo",
      ]
    }
    kayenta = {
      port     = 8090
      backends = []
    }
    orca = {
      port = 8083
      backends = [
        "clouddriver",
        "fiat",
        "front50",
        "kayenta",
        "rosco",
      ]
    }
    rosco = {
      port     = 8087
      backends = []
    }
  }

  # Dynamically construct the Docker image names from the Halyard BOM file
  bom             = yamldecode(file("./files/bom/${local.spinnaker_version}.yml"))
  docker_registry = local.bom["artifactSources"]["dockerRegistry"]
  images          = local.bom["services"]
  docker_images = {
    for service_name in keys(local.services) : service_name =>
    "${local.docker_registry}/${service_name}:${local.images[service_name]["version"]}"
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Use the default VPC to keep things simple
data "aws_vpc" "default" {
  default = true
}

# Use any subnet in the VPC
data "aws_subnet_ids" "all" {
  vpc_id = data.aws_vpc.default.id
}

## CloudMap

resource "aws_service_discovery_private_dns_namespace" "spinnaker" {
  description = "Service discovery for the Spinnaker micro services"
  name        = "spinnaker.local"
  tags        = local.tags
  vpc         = data.aws_vpc.default.id
}

resource "aws_service_discovery_service" "spinnaker" {
  for_each    = local.services
  description = "The Spinnaker ${title(each.key)} microservice"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.spinnaker.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 5
  }
  name = each.key
  tags = local.tags
}

resource "aws_service_discovery_service" "redis" {
  description = "The Redis backend used by the Spinnaker microservices"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.spinnaker.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 5
  }
  name         = "redis"
  namespace_id = aws_service_discovery_private_dns_namespace.spinnaker.id
  tags         = local.tags
}

locals {
  service_urls = {
    for name, properties in local.services :
    name => "http://${aws_service_discovery_service.spinnaker[name].name}.${aws_service_discovery_private_dns_namespace.spinnaker.name}:${properties.port}"
  }
  redis_url = "redis://${aws_service_discovery_service.redis.name}.${aws_service_discovery_private_dns_namespace.spinnaker.name}:${local.redis_port}"
}

## Create common resources to be used by all of the ECS services

# Logging resources
resource "aws_cloudwatch_log_group" "spinnaker" {
  name              = "/ecs/spinnaker"
  retention_in_days = 7
  tags              = local.tags
}

# IAM resources

# Create the required service linked role for ECS
# https://docs.aws.amazon.com/AmazonECS/latest/userguide/using-service-linked-roles.html
resource "aws_iam_service_linked_role" "ecs" {
  aws_service_name = "ecs.amazonaws.com"
}

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    sid = "EcsAssumeRole"
    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
    actions = ["sts:AssumeRole"]
  }
}

# Create a common task execution role for every Spinnaker task
resource "aws_iam_role" "task_execution_role" {
  name_prefix        = "spinnaker_task_execution_role-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = local.tags
}

# Create a custom policy for the task execution role 
# The managed policy provided by AWS is too permissive
data "aws_iam_policy_document" "task_execution_role" {
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.spinnaker.arn}",
    ]
  }
  statement {
    sid = "SsmParameterStore"
    actions = [
      "ssm:GetParameter*",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/ecs/spinnaker/*",
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_role" {
  role   = aws_iam_role.task_execution_role.id
  policy = data.aws_iam_policy_document.task_execution_role.json
}

# Networking resources

resource "aws_security_group" "spinnaker" {
  name_prefix = "spinnaker-"
  description = "Common security group for Spinnaker ECS tasks"
  tags        = local.tags
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group_rule" "spinnaker_self_ingress" {
  description       = "All the tasks to talk to each other on any port"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.spinnaker.id
  type              = "ingress"
}

resource "aws_security_group_rule" "spinnaker_https_egress" {
  description = "Allow full egress on HTTPS pulling images and AWS API access"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = [
    "0.0.0.0/0",
  ]
  security_group_id = aws_security_group.spinnaker.id
  type              = "egress"
}

resource "aws_security_group_rule" "spinnaker_vpc_egress" {
  description = "Allow full egress in the VPC CIDR block"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = [
    data.aws_vpc.default.cidr_block,
  ]
  security_group_id = aws_security_group.spinnaker.id
  type              = "egress"
}

### ECS RESOURCES ###

resource "aws_ecs_cluster" "spinnaker" {
  name               = "spinnaker"
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  tags               = local.tags
  depends_on = [
    aws_iam_service_linked_role.ecs
  ]
}

### Redis
locals {
  redis_task_definition = {
    name        = "redis"
    cpu         = 0
    environment = []
    essential   = true
    image       = "redis:6"
    healthcheck = {
      command = [
        "CMD-SHELL",
        "/usr/local/bin/redis-cli PING | grep PONG"
      ]
      interval = 30
      retries  = 3
      timeout  = 5
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.spinnaker.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "redis"
      }
    }
    mountPoints = []
    portMappings = [
      {
        containerPort = local.redis_port
        hostPort      = local.redis_port
        protocol      = "tcp"
      }
    ]
    volumesFrom = []
  }
}

resource "aws_ecs_task_definition" "redis" {
  cpu                      = 256
  family                   = "redis"
  container_definitions    = jsonencode([local.redis_task_definition])
  execution_role_arn       = aws_iam_role.task_execution_role.arn
  memory                   = 1024
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  tags                     = local.tags
}

resource "aws_ecs_service" "redis" {
  cluster                 = aws_ecs_cluster.spinnaker.name
  desired_count           = 1
  enable_ecs_managed_tags = true
  launch_type             = "FARGATE"
  network_configuration {
    # Assign public IPs to keep the VPC networking simple.  
    # The security groups will need to be strict to prevent unauthorized access.
    assign_public_ip = true
    subnets          = data.aws_subnet_ids.all.ids
    security_groups = [
      aws_security_group.spinnaker.id
    ]
  }
  name             = "redis"
  platform_version = "1.4.0"
  service_registries {
    registry_arn = aws_service_discovery_service.redis.arn
  }
  tags            = local.tags
  task_definition = aws_ecs_task_definition.redis.arn
}

data "aws_iam_policy_document" "spinnaker_assume_role" {
  statement {
    principals {
      identifiers = [
        aws_iam_role.clouddriver.arn
      ]
      type = "AWS"
    }
    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "spinnaker" {
  assume_role_policy = data.aws_iam_policy_document.spinnaker_assume_role.json
  name_prefix        = "spinnaker-"
  description        = "The role assumed by Spinnaker to deploy resources."
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "spinnaker" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess",
    "arn:aws:iam::aws:policy/AmazonVPCReadOnlyAccess",
    "arn:aws:iam::aws:policy/AWSCloudFormationReadOnlyAccess",
  ])
  role       = aws_iam_role.spinnaker.id
  policy_arn = each.value
}

### Clouddriver Service
resource "aws_iam_role" "clouddriver" {
  name_prefix        = "clouddriver-"
  description        = "Assumed by Spinnaker's Clouddriver service"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = local.tags
}

data "aws_iam_policy_document" "clouddriver" {
  statement {
    sid       = "AssumeSpinnakerRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.spinnaker.arn]
  }
}

resource "aws_iam_role_policy" "clouddriver" {
  policy = data.aws_iam_policy_document.clouddriver.json
  role   = aws_iam_role.clouddriver.id
}

module "clouddriver_task_definition" {
  source = "./modules/spinnaker-task-definition"

  cpu = 512
  environment = [
    {
      name  = "aws.defaultAssumeRole"
      value = "role/${aws_iam_role.spinnaker.name}"
    },
  ]
  execution_role_arn = aws_iam_role.task_execution_role.arn
  image              = local.docker_images["clouddriver"]
  name               = "clouddriver"
  port               = local.services["clouddriver"].port
  redis_url          = local.redis_url
  memory             = 2048
  task_role_arn      = aws_iam_role.clouddriver.arn
  tags               = local.tags
}

module "fiat_task_definition" {
  source = "./modules/spinnaker-task-definition"

  execution_role_arn = aws_iam_role.task_execution_role.arn
  image              = local.docker_images["fiat"]
  name               = "fiat"
  port               = local.services["fiat"].port
  redis_url          = local.redis_url
  tags               = local.tags
}

module "front50_task_definition" {
  source = "./modules/spinnaker-task-definition"

  environment = [
    {
      name = "cassandra.enabled"
      value = "false"
    },
    {
      name = "spinnaker.cassandra.enabled"
      value = "false"
    },
    {
      name = "spinnaker.redis.enabled"
      value = "true"
    },
        {
      name = "spinnaker.redis.host"
      value = aws_service_discovery_service.redis.name
    }
  ]
  execution_role_arn = aws_iam_role.task_execution_role.arn
  image              = local.docker_images["front50"]
  name               = "front50"
  port               = local.services["front50"].port
  redis_url          = local.redis_url
  tags               = local.tags
}

module "rosco_task_definition" {
  source = "./modules/spinnaker-task-definition"

  execution_role_arn = aws_iam_role.task_execution_role.arn
  image              = local.docker_images["rosco"]
  name               = "rosco"
  port               = local.services["rosco"].port
  redis_url          = local.redis_url
  tags               = local.tags
}

resource "aws_ecs_service" "spinnaker" {
  # Construct a map of service names to task def arns for each task definition 
  # to iterate through because they are the only two values that vary among 
  # each service definition.
  for_each = {
    for definition in [
      module.clouddriver_task_definition.task_definition_attributes,
      module.fiat_task_definition.task_definition_attributes,
      module.front50_task_definition.task_definition_attributes,
      module.rosco_task_definition.task_definition_attributes,
    ] : definition.family => definition.arn  
  }
  cluster                 = aws_ecs_cluster.spinnaker.name
  desired_count           = 1
  enable_ecs_managed_tags = true
  force_new_deployment    = true
  launch_type             = "FARGATE"
  network_configuration {
    # Assign public IPs to keep the VPC networking simple.  
    # The security groups will need to be strict to prevent unauthorized access.
    assign_public_ip = true
    subnets          = data.aws_subnet_ids.all.ids
    security_groups = [
      aws_security_group.spinnaker.id
    ]
  }
  name             = each.key
  platform_version = "1.4.0"
  service_registries {
    registry_arn = aws_service_discovery_service.spinnaker[each.key].arn
  }
  tags            = local.tags
  task_definition = each.value
}
