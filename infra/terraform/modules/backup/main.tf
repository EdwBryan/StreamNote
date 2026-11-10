# RNF-02: copia diaria de Aurora y DynamoDB que se guarda 2 años (AWS Backup).

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

resource "aws_backup_vault" "this" {
  name          = "${var.prefix}-backup"
  force_destroy = var.force_destroy
}

resource "aws_backup_plan" "diario" {
  name = "${var.prefix}-diario"

  rule {
    rule_name         = "diario-2-anios"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 8 * * ? *)" # 3:00 a. m. en Perú

    lifecycle {
      delete_after = 730
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
