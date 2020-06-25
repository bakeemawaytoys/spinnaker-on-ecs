variable "name" {
  type        = string
  description = "(optional) describe your variable"
}

variable "port" {
  type        = number
  description = "(optional) describe your variable"
}

variable "image" {
  type        = string
  description = "The value to use for the task definition's 'image' property."
}

variable "cpu" {
  type        = number
  description = "(optional) describe your variable"
}

variable "memory" {
  type        = number
  description = "(optional) describe your variable"
}

variable "cloudwatch_log_group_name" {
  type        = string
  description = "(optional) describe your variable"
}

variable "environment" {
  type = list(
    object(
      {
        name  = string
        value = string
      }
    )
  )
  description = "The value to use for the 'environment' task definition property."
  default     = []
}

variable "execution_role_arn" {
  type        = string
  description = "(optional) describe your variable"
}

variable "task_role_arn" {
  type        = string
  description = "(optional) describe your variable"
  default     = null
}
