# Tabla de notificaciones: una partición por usuario, ordenada por fecha.

variable "prefix" {
  type = string
}

resource "aws_dynamodb_table" "notifications" {
  #checkov:skip=CKV_AWS_119:Cifrada con la llave de AWS. Una llave propia (CMK) cuesta 1 USD al mes y no cambia quién puede leerla.
  name         = "${var.prefix}-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "sk"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Permite volver la tabla a cualquier segundo de los últimos 35 días
  point_in_time_recovery {
    enabled = true
  }
}

output "table_name" {
  value = aws_dynamodb_table.notifications.name
}

output "table_arn" {
  value = aws_dynamodb_table.notifications.arn
}
