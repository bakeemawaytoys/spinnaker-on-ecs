output "task_definition_attributes" {
    value = aws_ecs_task_definition.spinnaker
}

output "task_definition_arn" {
    value = aws_ecs_task_definition.spinnaker.arn
}