data "aws_region" "current" {}

locals {

  standard_environment = [
    {
      name  = "redis.connection"
      value = var.redis_url
    },
    # Disable the Spring Boot banner so that it doesn't screw up the log parsing
    # https://docs.spring.io/spring-boot/docs/current/reference/htmlsingle/#boot-features-banner
    {
      name  = "spring.main.banner-mode"
      value = "off"
    },
    {
      name  = "aws.enabled"
      value = "true"
    },

  ]

  container_definition = {
    name        = var.name
    environment = concat(var.environment, local.standard_environment)
    essential   = true
    healthcheck = {
      command = [
        "CMD-SHELL",
        "/usr/bin/wget --spider http://localhost:${var.port}/health"
      ]
      interval    = 30
      retries     = 3
      timeout     = 5
      startPeriod = 30
    }
    image = var.image
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.cloudwatch_log_group_name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = var.name
        # Example prefix: 2020-06-24 14:26:21.739 
        # https://docs.docker.com/config/containers/logging/awslogs/#awslogs-datetime-format
        awslogs-datetime-format = "%Y-%m-%d %H:%M:%S.%L"
      }
    }
    portMappings = [
      {
        containerPort = var.port
      }
    ]
  }
}

resource "aws_ecs_task_definition" "spinnaker" {
  cpu                      = var.cpu
  family                   = var.name
  container_definitions    = jsonencode([local.container_definition])
  execution_role_arn       = var.execution_role_arn
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = var.task_role_arn
  tags                     = var.tags
}
