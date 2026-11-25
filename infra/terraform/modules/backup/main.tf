# RNF-02: copia diaria de Aurora y DynamoDB (AWS Backup). Se guarda 2 años en producción;
# cada ambiente fija su retención en su .tfvars.

variable "prefix" {
  type = string
}

variable "resource_arns" {
  description = "Lo que se respalda: el cluster de Aurora y la tabla de DynamoDB"
  type        = list(string)
}

variable "force_destroy" {
  description = "true en dev: permite borrar el vault aunque tenga copias"
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "Días que se guarda cada copia (RNF-02: 2 años en producción)"
  type        = number
  default     = 730
  validation {
    condition     = var.retention_days >= 1
    error_message = "La retención tiene que ser de al menos 1 día."
  }
}

resource "aws_backup_vault" "this" {
  #checkov:skip=CKV_AWS_166:Cifrado con la llave de AWS Backup; una llave propia cuesta 1 USD al mes.
  name          = "${var.prefix}-backup"
  force_destroy = var.force_destroy
}

resource "aws_backup_plan" "diario" {
  name = "${var.prefix}-diario"

  rule {
    rule_name         = "diario" # antes "diario-2-anios": el nombre ya no sería cierto en dev
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 8 * * ? *)" # 3:00 a. m. en Perú

    lifecycle {
      delete_after = var.retention_days
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.prefix}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "datos" {
  name         = "${var.prefix}-datos"
  plan_id      = aws_backup_plan.diario.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = var.resource_arns
}
